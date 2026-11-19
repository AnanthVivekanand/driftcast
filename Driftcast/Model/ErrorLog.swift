import Foundation

/// The error log: one line for each thing that went wrong, with the time, the version, and the
/// system's own reason and error numbers. An alert is gone once it is closed; this is the file
/// to read, or attach to a report, afterwards.
///
/// It lives in ~/Library/Logs/Driftcast/Errors.log, where Console lists it and where an app
/// can write without asking for permission.
enum ErrorLog {
    static var url: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Driftcast/Errors.log")
    }

    /// Past this size the older half is dropped, so the file can't grow without end.
    static let sizeLimit = 512 * 1024

    private static let queue = DispatchQueue(label: "com.leechsoftware.driftcast.errorlog")

    /// `what` names what was being done ("Delete File", "Playback"); `detail` says what happened.
    static func record(_ what: String, _ detail: String, to file: URL = url, now: Date = Date()) {
        let text = line(what, detail, now: now)
        queue.async { append(text, to: file) }
    }

    /// The same, for a thrown error: `subject` is the file or device it was about.
    static func record(_ what: String, _ subject: String? = nil, error: Error, to file: URL = url, now: Date = Date()) {
        record(what, (subject.map { "\($0): " } ?? "") + describe(error), to: file, now: now)
    }

    /// Waits for lines still being written (for the tests, and before showing the file).
    static func flush() { queue.sync {} }

    /// The message a person would see, then the error's domain and number and those of the
    /// errors under it: "…you don't have permission to access it. [NSCocoaErrorDomain 513,
    /// NSOSStatusErrorDomain -5000]". The numbers tell apart failures whose messages read alike.
    static func describe(_ error: Error) -> String {
        var codes: [String] = []
        var next: NSError? = error as NSError
        while let e = next, codes.count < 4 {
            codes.append("\(e.domain) \(e.code)")
            next = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return "\(error.localizedDescription) [\(codes.joined(separator: ", "))]"
    }

    static func line(_ what: String, _ detail: String, now: Date) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        // One error, one line: a message with line breaks would read as several.
        let flat = detail.split(whereSeparator: \.isNewline).joined(separator: " | ")
        return "\(stamp.string(from: now)) [\(version)] \(what): \(flat)\n"
    }

    private static func append(_ text: String, to file: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
        try? handle.close()
        trim(file)
    }

    /// Keeps the newer half of a file that has passed the limit, starting at a whole line.
    private static func trim(_ file: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size > sizeLimit,
              let data = try? Data(contentsOf: file) else { return }
        var kept = data.suffix(sizeLimit / 2)
        if let lineEnd = kept.firstIndex(of: UInt8(ascii: "\n")) { kept = kept.suffix(from: kept.index(after: lineEnd)) }
        try? Data(kept).write(to: file, options: .atomic)
    }
}
