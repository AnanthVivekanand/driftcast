import Foundation
import Security

/// Installs a newer copy of Driftcast over the running one: download, unpack, prove the new copy
/// really is Driftcast from Leech Software, then quit and let a small script swap the two and
/// open the new one. Until the swap every step works in a folder beside the app, so a failure at
/// any point leaves the installed copy exactly as it was.
enum UpdateInstaller {
    enum Failure: LocalizedError {
        case download(String)
        case badArchive
        case wrongApp
        case notSigned
        case notNewer
        case needsNewerMac(String)
        case cantReplace

        var errorDescription: String? {
            switch self {
            case .download(let why): return "The update couldn't be downloaded (\(why))."
            case .badArchive: return "The downloaded update couldn't be opened."
            case .wrongApp: return "The downloaded file isn't Driftcast."
            case .notSigned: return "The downloaded update isn't signed by Leech Software, so it wasn't installed."
            case .notNewer: return "The downloaded update isn't newer than this copy."
            case .needsNewerMac(let version): return "This update needs macOS \(version) or later."
            case .cantReplace: return "Driftcast can't replace itself where it is now. Move it to your Applications folder and try again, or download the update yourself."
            }
        }
    }

    /// A Developer ID signature from this team on this app, and nothing else. Apple's chain of
    /// trust is what makes this meaningful: a file swapped in on the way here can't satisfy it.
    static let requirement = """
    identifier "com.leechsoftware.driftcast" and anchor apple generic \
    and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
    and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
    and certificate leaf[subject.OU] = "CBAE6JXBHC"
    """

    /// A new copy that has passed every check and is ready to be swapped in.
    struct Prepared: Sendable {
        var installed: URL
        var replacement: URL
        var staging: URL
    }

    /// Only a zip can be installed in place; anything else goes to the browser.
    static func canInstall(_ release: AppRelease) -> Bool {
        release.download?.pathExtension.lowercased() == "zip"
    }

    /// Throws unless the app at `app` can be replaced: it can't when macOS is running it from a
    /// temporary read-only copy (opened straight from Downloads), from a disk image, or from a
    /// folder this user can't write to.
    static func checkReplaceable(_ app: URL) throws {
        let fm = FileManager.default
        let parent = app.deletingLastPathComponent()
        let readOnly = (try? parent.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? true
        guard app.pathExtension == "app", !app.path.contains("/AppTranslocation/"), !readOnly,
              fm.isWritableFile(atPath: parent.path), fm.isWritableFile(atPath: app.path) else { throw Failure.cantReplace }
    }

    /// Every staging folder is named this followed by a UUID.
    static let stagingPrefix = ".driftcast-update-"

    static func isStagingFolder(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix(stagingPrefix) && UUID(uuidString: String(name.dropFirst(stagingPrefix.count))) != nil
    }

    /// Downloads and checks a new copy. Nothing outside the staging folder is touched, and the
    /// staging folder is removed again unless a checked copy is handed back.
    static func prepare(download source: URL, replacing app: URL, newerThan installed: String,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> Prepared {
        try checkReplaceable(app)
        // Beside the app so that the swap is a rename on one volume, not a slow, breakable copy.
        let staging = app.deletingLastPathComponent().appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let zip = staging.appendingPathComponent("update.zip")
            try await download(source, to: zip, progress: progress)
            let replacement = try await unpack(zip, into: staging)
            try? FileManager.default.removeItem(at: zip)
            try await Task.detached(priority: .userInitiated) { try verify(replacement, newerThan: installed) }.value
            // The signature check can't be interrupted, so Cancel pressed during it is only
            // seen here; without this the unpacked copy stayed beside the app for good.
            try Task.checkCancellation()
            return Prepared(installed: app, replacement: replacement, staging: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Throws away a prepared copy that won't be swapped in after all.
    static func discard(_ prepared: Prepared) {
        try? FileManager.default.removeItem(at: prepared.staging)
    }

    /// Removes staging folders an earlier run left beside the app: Driftcast quit, or another
    /// copy took over, during a download, and nothing else would ever remove them. Only those
    /// untouched for `age` seconds go: a swap under way renames the old copy into its staging
    /// folder seconds after the folder last changed, so a folder in use is always younger.
    /// One holding a previous.app is never removed either. The swap script leaves that only
    /// when neither copy could be put back in place, and it may be the only copy left.
    @discardableResult
    static func sweepStaging(beside app: URL, olderThan age: TimeInterval = 600, now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: app.appendingPathComponent("Contents").path) else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let items = (try? fm.contentsOfDirectory(at: app.deletingLastPathComponent(), includingPropertiesForKeys: keys)) ?? []
        var removed: [URL] = []
        for item in items where isStagingFolder(item) {
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let changed = values.contentModificationDate, now.timeIntervalSince(changed) > age,
                  !fm.fileExists(atPath: item.appendingPathComponent("previous.app").path) else { continue }
            if (try? fm.removeItem(at: item)) != nil { removed.append(item) }
        }
        return removed
    }

    static func download(_ source: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: source)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Unpacks the zip and returns the one app inside it.
    static func unpack(_ zip: URL, into folder: URL) async throws -> URL {
        let unpacked = folder.appendingPathComponent("unpacked", isDirectory: true)
        do {
            _ = try await FFmpeg.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, unpacked.path])
        } catch {
            // Cancel stops ditto, which then fails like a damaged zip; it was shown and logged
            // as "couldn't be opened".
            if Task.isCancelled { throw CancellationError() }
            throw Failure.badArchive
        }
        try Task.checkCancellation()
        let items = (try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)) ?? []
        let apps = items.filter { $0.pathExtension == "app" }
        guard apps.count == 1 else { throw Failure.badArchive }
        return apps[0]
    }

    /// The checks that make it safe to run what was downloaded.
    static func verify(_ app: URL, newerThan installed: String) throws {
        guard let bundle = Bundle(url: app), let info = bundle.infoDictionary,
              bundle.bundleIdentifier == "com.leechsoftware.driftcast" else { throw Failure.wrongApp }

        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement) == errSecSuccess else { throw Failure.notSigned }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { throw Failure.notSigned }

        guard AppVersion.isNewer(info["CFBundleShortVersionString"] as? String ?? "0", than: installed) else { throw Failure.notNewer }
        if let minimum = info["LSMinimumSystemVersion"] as? String {
            let parts = AppVersion.components(minimum)
            let needed = OperatingSystemVersion(majorVersion: parts.first ?? 0, minorVersion: parts.count > 1 ? parts[1] : 0, patchVersion: parts.count > 2 ? parts[2] : 0)
            guard ProcessInfo.processInfo.isOperatingSystemAtLeast(needed) else { throw Failure.needsNewerMac(minimum) }
        }
    }

    /// Waits for the process to end, swaps the copies by renaming, and opens whichever is then
    /// installed. If the new copy can't be moved in, the old one goes straight back.
    ///
    /// The staging folder is removed only when an app is back in its place. If the new copy
    /// can't go in and the old one can't go back either, the staging folder holds the only
    /// copies left: it stays, and the old copy is opened from there so that Driftcast still
    /// runs and can say what happened. The paths arrive as arguments, never inside the script's
    /// text, so spaces and quotes in them can't change what it does.
    static let swapScript = #"""
    pid="$1"; app="$2"; new="$3"; staging="$4"; opener="$5"
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
        waited=$((waited + 1))
        if [ "$waited" -gt 300 ]; then echo "Driftcast didn't quit in time; nothing was changed." >&2; rm -rf "$staging"; exit 1; fi
        sleep 0.1
    done
    old="$staging/previous.app"
    if mv "$app" "$old"; then
        mv "$new" "$app" || mv "$old" "$app"
    fi
    if [ -d "$app/Contents" ]; then
        rm -rf "$staging"
        "$opener" "$app"
    else
        echo "Neither copy could be put in place; the old one is at $old." >&2
        "$opener" "$old"
    fi
    """#

    /// Starts the script that finishes the job once this process has quit. It carries on by
    /// itself after Driftcast has gone. `opener` is what opens the app afterwards. What the
    /// script and the commands in it say about a failure goes to `report`, for the next launch
    /// to put in the error log.
    static func swapAfterExit(_ prepared: Prepared, of pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                              opener: String = "/usr/bin/open", report: URL? = nil) throws {
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/sh")
        script.arguments = ["-c", swapScript, "driftcast-update", String(pid),
                            prepared.installed.path, prepared.replacement.path, prepared.staging.path, opener]
        script.standardInput = FileHandle.nullDevice
        script.standardOutput = FileHandle.nullDevice
        script.standardError = FileHandle.nullDevice
        if let report {
            try? FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.createFile(atPath: report.path, contents: nil),
               let handle = try? FileHandle(forWritingTo: report) {
                script.standardError = handle
            }
        }
        try script.run()
    }

    /// Where the swap script writes what went wrong: beside the error log.
    static var swapReport: URL {
        ErrorLog.url.deletingLastPathComponent().appendingPathComponent("Last update.txt")
    }

    /// The version in an app's Info.plist, read from the file rather than through `Bundle`,
    /// which may remember an earlier copy at the same path.
    static func version(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    // MARK: After the swap

    /// An update handed to the swap script. It is remembered until the next launch, which is
    /// the first moment anything can tell whether the swap worked: the script runs after
    /// Driftcast has quit, and a swap that failed reopened the old copy with no word said.
    struct PendingSwap: Codable, Equatable {
        /// The version that was to be put in.
        var version: String
        /// Where the copy being replaced was.
        var app: String
        var page: URL
        var download: URL?

        var release: AppRelease { AppRelease(version: version, page: page, download: download) }
    }

    enum AfterSwap: Equatable {
        /// The copy that is running is the new version.
        case installed
        /// The copy that was to be replaced is still the old version: the swap didn't happen.
        case notInstalled
        /// This copy was moved aside into its staging folder and couldn't be put back.
        case movedAside
        /// Another copy of Driftcast, somewhere else: the record is left for the right one.
        case otherCopy
    }

    static func afterSwap(_ pending: PendingSwap, running version: String, at bundle: URL) -> AfterSwap {
        let expected = URL(fileURLWithPath: pending.app).standardizedFileURL
        let here = bundle.standardizedFileURL
        if here.path == expected.path {
            return AppVersion.isNewer(pending.version, than: version) ? .notInstalled : .installed
        }
        let folder = here.deletingLastPathComponent()
        if isStagingFolder(folder), folder.deletingLastPathComponent().path == expected.deletingLastPathComponent().path {
            return .movedAside
        }
        return .otherCopy
    }

    static let pendingSwapKey = "updatePendingSwap"

    static func remember(_ pending: PendingSwap, in defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(pending), forKey: pendingSwapKey)
        // Driftcast quits straight after this; the record must be on disk before it goes.
        defaults.synchronize()
    }

    static func pendingSwap(in defaults: UserDefaults = .standard) -> PendingSwap? {
        defaults.data(forKey: pendingSwapKey).flatMap { try? JSONDecoder().decode(PendingSwap.self, from: $0) }
    }

    static func forgetPendingSwap(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: pendingSwapKey)
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var failure: Error?
    private var _continuation: CheckedContinuation<Void, Error>?

    var continuation: CheckedContinuation<Void, Error>? {
        get { lock.lock(); defer { lock.unlock() }; return _continuation }
        set { lock.lock(); _continuation = newValue; lock.unlock() }
    }

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file vanishes when this returns, so it has to be moved here.
        lock.lock(); defer { lock.unlock() }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = UpdateInstaller.Failure.download("the server answered \(http.statusCode)")
            return
        }
        do { try FileManager.default.moveItem(at: location, to: destination) } catch { failure = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let waiting = _continuation
        _continuation = nil
        let outcome = error ?? failure
        lock.unlock()
        if let outcome {
            if (outcome as? URLError)?.code == .cancelled { waiting?.resume(throwing: CancellationError()); return }
            waiting?.resume(throwing: outcome is UpdateInstaller.Failure ? outcome : UpdateInstaller.Failure.download(outcome.localizedDescription))
        } else {
            waiting?.resume()
        }
    }
}
