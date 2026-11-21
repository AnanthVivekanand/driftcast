import AppKit
import UniformTypeIdentifiers

/// The list of videos played: the file, its cleaned name, and when. It is kept inside
/// Driftcast's own data folder, where nobody looking through the person's folders comes across
/// it, and File > Export Watched Videos… is how it comes out, as a spreadsheet.
///
/// Version 1.1.1 kept it as two files in the Movies folder, in plain view. Those are taken in
/// and removed from there (`takeIn`).
enum WatchedList {
    struct Entry: Equatable {
        var title: String
        var filename: String
        var played: Date
        /// Where the file was, to tell apart two files of one name ("01.mkv" of two shows).
        /// Kept in the list, not in the spreadsheet; lists written before 1.1.3 have none.
        var path: String? = nil
    }

    /// What the exported spreadsheet is called, and what 1.1.1's files in Movies were called.
    static let name = "Videos I have watched on Driftcast"
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Driftcast", isDirectory: true)
    }
    static func jsonURL(in folder: URL = folder) -> URL { folder.appendingPathComponent("watched-videos.json") }
    /// Where a list that can't all be read is copied before it is written over.
    static func unreadableURL(in folder: URL = folder) -> URL { folder.appendingPathComponent("watched-videos (unreadable).json") }
    static var moviesFolder: URL { FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0] }

    /// Starting the same video again this soon is the same viewing, not another one: stopping
    /// to change the TV, or picking it up after a failed start.
    static let sameViewing: TimeInterval = 30 * 60

    private static let queue = DispatchQueue(label: "com.leechsoftware.driftcast.watchedlist")

    /// Notes a video that has started playing. Off the main thread; a failure goes to the error log.
    static func record(title: String, filename: String, path: String? = nil, played: Date = Date()) {
        queue.async {
            settle()
            do { try add(Entry(title: title, filename: filename, played: played, path: path), in: folder) }
            catch { ErrorLog.record("Watched list", error: error) }
        }
    }

    /// Waits for entries still being written.
    static func flush() { queue.sync {} }

    /// At launch: 1.1.1's list leaves the Movies folder without waiting for a video to play.
    static func takeInOldList() { queue.async { settle() } }

    private static func settle() {
        do { try takeIn(from: moviesFolder, to: folder) }
        catch { ErrorLog.record("Watched list", "moving it out of the Movies folder", error: error) }
    }

    /// The list so far, oldest first. Empty when nothing has been played or the file can't be read.
    static func entries(in folder: URL = folder) -> [Entry] {
        (try? readEntries(in: folder)) ?? []
    }

    /// The list so far, oldest first, or why the file there couldn't be read. Empty when
    /// nothing has been played.
    static func readEntries(in folder: URL = folder) throws -> [Entry] {
        flush()
        let json = jsonURL(in: folder)
        guard FileManager.default.fileExists(atPath: json.path) else { return [] }
        return decode(try Data(contentsOf: json))?.entries ?? []
    }

    /// Adds an entry and rewrites the list. False when it was the same viewing as the last one.
    @discardableResult
    static func add(_ entry: Entry, in folder: URL) throws -> Bool {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var entries = try load(in: folder)
        if let last = entries.last, isSameFile(last, entry),
           abs(entry.played.timeIntervalSince(last.played)) < sameViewing { return false }
        entries.append(entry)
        try Data(encode(entries).utf8).write(to: jsonURL(in: folder), options: .atomic)
        return true
    }

    /// Same name, and the same folder when both entries say where the file was.
    private static func isSameFile(_ a: Entry, _ b: Entry) -> Bool {
        guard a.filename == b.filename else { return false }
        guard let p = a.path, let q = b.path else { return true }
        return p == q
    }

    /// The entries of the list in `folder`. When the file there can't all be read, a copy of
    /// it is kept beside it first, since what is written next holds only the entries that could be.
    /// A file that is there but can't be opened at all throws: written over, the whole list
    /// was lost; this way the one viewing goes unrecorded and the error log says why.
    private static func load(in folder: URL) throws -> [Entry] {
        let json = jsonURL(in: folder)
        guard FileManager.default.fileExists(atPath: json.path) else { return [] }
        let data = try Data(contentsOf: json)
        let read = decode(data)
        if read?.complete != true {
            let aside = unreadableURL(in: folder)
            try? FileManager.default.removeItem(at: aside)
            try FileManager.default.copyItem(at: json, to: aside)
        }
        return read?.entries ?? []
    }

    /// Takes in the list that version 1.1.1 kept in `old` (the Movies folder) and removes it
    /// from there, so nothing about what was watched is left in view. Its entries join any
    /// already in `folder`, in the order played. What was read in full is deleted; a file that
    /// couldn't all be read is moved into `folder` whole, out of view and not lost.
    static func takeIn(from old: URL, to folder: URL) throws {
        let fm = FileManager.default
        let oldJSON = old.appendingPathComponent(name + ".json")
        let oldText = old.appendingPathComponent(name + ".txt")
        let oldAside = old.appendingPathComponent(name + " (unreadable).json")
        guard [oldJSON, oldText, oldAside].contains(where: { fm.fileExists(atPath: $0.path) }) else { return }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        var absorbed = false
        if let read = (try? Data(contentsOf: oldJSON)).flatMap(decode) {
            var all = read.entries
            all += try load(in: folder).filter { !all.contains($0) }
            all.sort { $0.played < $1.played }
            try Data(encode(all).utf8).write(to: jsonURL(in: folder), options: .atomic)
            absorbed = read.complete
        }
        let kept = [(oldJSON, "watched-videos (from Movies).json"), (oldText, "watched-videos (from Movies).txt"),
                    (oldAside, "watched-videos (from Movies, unreadable).json")]
        for (file, keptAs) in kept where fm.fileExists(atPath: file.path) {
            if absorbed, file != oldAside {
                try fm.removeItem(at: file)
            } else {
                let to = folder.appendingPathComponent(keptAs)
                try? fm.removeItem(at: to)
                try fm.moveItem(at: file, to: to)
            }
        }
    }

    // MARK: The two forms

    /// JSON written by hand so the keys keep their order: filename, title, played, and the
    /// file's path when it is known.
    static func encode(_ entries: [Entry]) -> String {
        guard !entries.isEmpty else { return "[]\n" }
        let rows = entries.map {
            "  {\n    \"filename\": \(quoted($0.filename)),\n    \"title\": \(quoted($0.title)),\n    \"played\": \(quoted(stamp.string(from: $0.played)))"
                + ($0.path.map { ",\n    \"path\": \(quoted($0))" } ?? "") + "\n  }"
        }
        return "[\n" + rows.joined(separator: ",\n") + "\n]\n"
    }

    /// Nil when the data isn't a list at all. An entry missing a part, or with a date written
    /// another way, is left out, and `complete` is then false.
    static func decode(_ data: Data) -> (entries: [Entry], complete: Bool)? {
        if String(decoding: data, as: UTF8.self).allSatisfy(\.isWhitespace) { return ([], true) }
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        let entries = rows.compactMap { row -> Entry? in
            guard let row = row as? [String: Any],
                  let title = row["title"] as? String, let filename = row["filename"] as? String,
                  let played = (row["played"] as? String).flatMap(stamp.date(from:)) else { return nil }
            return Entry(title: title, filename: filename, played: played, path: row["path"] as? String)
        }
        return (entries, entries.count == rows.count)
    }

    /// For a spreadsheet: newest first, with a date and time it reads as one. It starts with a
    /// byte order mark, which Excel needs to show accented titles correctly.
    static func csv(_ entries: [Entry]) -> String {
        let when = DateFormatter()
        when.locale = Locale(identifier: "en_US_POSIX")
        when.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let rows = [["File", "Title", "Played"]] + entries.reversed().map { [$0.filename, $0.title, when.string(from: $0.played)] }
        return "\u{FEFF}" + rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    private static func csvField(_ text: String) -> String {
        // A spreadsheet runs a cell that starts like this as a formula, and file names come
        // from anywhere. The apostrophe makes it plain text.
        let s = text.first.map({ "=+-@\t\r".contains($0) }) == true ? "'" + text : text
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func quoted(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    /// "2026-11-19T00:21:07-05:00": the local time, with its distance from UTC.
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    // MARK: From the menus

    /// File > Export Watched Videos…: the list as a CSV file, saved where the person chooses.
    static func exportCSV() {
        queue.sync { settle() }
        let list: [Entry]
        do {
            list = try readEntries()
        } catch {
            // Not "No videos have been played yet": there is a list, and it couldn't be opened.
            ErrorLog.record("Export Watched Videos", "reading the list", error: error)
            NSAlert(error: error).runModal()
            return
        }
        guard !list.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No videos have been played yet"
            alert.informativeText = "Each video you play is added to the list, and then it can be exported."
            alert.runModal()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = name + ".csv"
        panel.message = "A spreadsheet of the videos you have played: file, title, and when."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(csv(list).utf8).write(to: url, options: .atomic)
        } catch {
            ErrorLog.record("Export Watched Videos", url.lastPathComponent, error: error)
            NSAlert(error: error).runModal()
        }
    }
}
