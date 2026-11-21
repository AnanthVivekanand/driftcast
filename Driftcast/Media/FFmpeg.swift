import Foundation

enum FFmpegError: LocalizedError {
    case notFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "The media engine (ffmpeg) bundled with Driftcast is missing or can't run on this Mac. Reinstall Driftcast."
        case .failed(let message):
            return message
        }
    }
}

/// Locates and runs the ffmpeg / ffprobe command-line tools.
///
/// Search order: a folder named in the `ffmpegDirectory` default (Settings offered one until
/// 1.1.3; the tests still set it), a copy bundled in Contents/Resources/ffmpeg,
/// then Homebrew and MacPorts locations.
enum FFmpeg {
    static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]

    static func tool(_ name: String) -> URL? {
        var dirs: [String] = []
        let custom = Prefs.string(Prefs.ffmpegDirectory)
        if !custom.isEmpty { dirs.append(custom) }
        if let resources = Bundle.main.resourceURL { dirs.append(resources.appendingPathComponent("ffmpeg").path) }
        dirs += searchDirectories
        for dir in dirs {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path), runsOnThisMachine(url) { return url }
        }
        return nil
    }

    /// True when the Mach-O file contains a slice for the CPU this process runs on. A bundled
    /// Apple-silicon ffmpeg on an Intel Mac (or the reverse) is skipped so the search can
    /// fall through to a Homebrew copy instead of failing with "Bad CPU type".
    static func runsOnThisMachine(_ url: URL) -> Bool {
        #if arch(arm64)
        let wanted: UInt32 = 0x0100000C
        #else
        let wanted: UInt32 = 0x01000007
        #endif
        guard let handle = try? FileHandle(forReadingFrom: url), let header = try? handle.read(upToCount: 4096) else { return true }
        try? handle.close()
        let bytes = [UInt8](header)
        guard bytes.count >= 8 else { return true }
        func be(_ i: Int) -> UInt32 { UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3]) }
        func le(_ i: Int) -> UInt32 { UInt32(bytes[i + 3]) << 24 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i]) }
        switch be(0) {
        case 0xCAFEBABE:                                   // fat binary: nfat_arch, then 20-byte entries
            let count = Int(be(4))
            for i in 0..<count where 8 + i * 20 + 4 <= bytes.count {
                if be(8 + i * 20) == wanted { return true }
            }
            return false
        case 0xCFFAEDFE, 0xCEFAEDFE:                       // thin little-endian Mach-O
            return le(4) == wanted
        case 0xFEEDFACF, 0xFEEDFACE:                       // thin big-endian Mach-O
            return be(4) == wanted
        default:
            return true                                    // a script or something else: let it try
        }
    }

    static var ffmpeg: URL? { tool("ffmpeg") }
    static var ffprobe: URL? { tool("ffprobe") }
    static var isAvailable: Bool { ffmpeg != nil && ffprobe != nil }

    /// Thrown by `run` when the tool didn't finish within its time limit.
    struct TimedOut: LocalizedError {
        var tool: String
        var seconds: Double
        var errorDescription: String? { "\(tool) didn't finish within \(Int(seconds)) seconds." }
    }

    /// Runs a tool to completion and returns stdout. Throws with the tail of stderr on failure.
    /// Canceling the calling task terminates the process and throws `CancellationError`.
    /// With a `timeout`, a tool still running then is ended and `TimedOut` thrown, even if it
    /// won't die (a process waiting on a disk that stopped answering ignores signals).
    static func run(_ executable: URL, _ arguments: [String], timeout: Double? = nil) async throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let run = RunState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                run.begin(cont)
                DispatchQueue.global(qos: .userInitiated).async {
                    // A cancel that came before the start would otherwise find nothing to stop,
                    // and the tool ran to its end.
                    do {
                        guard try run.start(process) else { run.finish(.failure(CancellationError())); return }
                    } catch {
                        run.finish(.failure(error)); return
                    }
                    if let timeout {
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                            guard run.expire(process) else { return }
                            run.finish(.failure(TimedOut(tool: executable.lastPathComponent, seconds: timeout)))
                            // The polite signal first, then one that can't be ignored.
                            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                            }
                        }
                    }
                    let errBox = DataBox()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    process.waitUntilExit()
                    if run.isCanceled {
                        // Whatever it wrote before it was stopped is only part of the answer.
                        run.finish(.failure(CancellationError()))
                    } else if process.terminationStatus == 0 {
                        run.finish(.success(data))
                    } else {
                        let msg = String(decoding: errBox.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        run.finish(.failure(FFmpegError.failed(msg.isEmpty ? "\(executable.lastPathComponent) exited with status \(process.terminationStatus)" : String(msg.suffix(500)))))
                    }
                }
            }
        } onCancel: {
            run.cancel(process)
        }
    }

    /// Whether the ffmpeg in use has a filter. Driftcast's own has everything it needs, but a
    /// copy chosen in Settings or found in Homebrew may not (Homebrew's lacks zscale).
    static func hasFilter(_ name: String) -> Bool {
        guard let exe = ffmpeg else { return false }
        filtersLock.lock(); defer { filtersLock.unlock() }
        if filtersPath != exe.path {
            filtersPath = exe.path
            let process = Process()
            let out = Pipe()
            process.executableURL = exe
            process.arguments = ["-hide_banner", "-filters"]
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            var listed = Set<String>()
            if (try? process.run()) != nil {
                let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                for line in text.split(separator: "\n") {
                    let words = line.split(separator: " ")
                    if words.count > 2 { listed.insert(String(words[1])) }
                }
            }
            filters = listed
        }
        return filters.contains(name)
    }

    private static let filtersLock = NSLock()
    nonisolated(unsafe) private static var filtersPath = ""
    nonisolated(unsafe) private static var filters = Set<String>()

    static func versionString() async -> String? {
        guard let exe = ffmpeg, let data = try? await run(exe, ["-hide_banner", "-version"]) else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init)
    }
}

private final class DataBox: @unchecked Sendable { var data = Data() }

/// One `FFmpeg.run`: whether it was canceled or ran out of time, and its answer, given once.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var canceled = false
    private var answered = false
    private var continuation: CheckedContinuation<Data, Error>?

    func begin(_ cont: CheckedContinuation<Data, Error>) {
        lock.lock(); continuation = cont; lock.unlock()
    }

    var isCanceled: Bool {
        lock.lock(); defer { lock.unlock() }
        return canceled
    }

    /// Starts the process unless the run was canceled first. Under the lock, so a cancel
    /// either comes before (and nothing starts) or finds the process running.
    func start(_ process: Process) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if canceled { return false }
        try process.run()
        return true
    }

    func cancel(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        canceled = true
        if process.isRunning { process.terminate() }
    }

    /// True when the time limit is what ends the run (it hadn't finished or been canceled).
    func expire(_ process: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !answered, !canceled else { return false }
        if process.isRunning { process.terminate() }
        return true
    }

    func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let cont = answered ? nil : continuation
        answered = true
        continuation = nil
        lock.unlock()
        cont?.resume(with: result)
    }
}

/// Caps how many child processes run at once (probing a big playlist would otherwise spawn dozens).
actor AsyncLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ limit: Int) { available = limit }

    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}
