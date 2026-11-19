import AppKit
import UniformTypeIdentifiers

/// The list of videos played: the file, its cleaned name, and when. Two files side by side in the
/// Movies folder, one to read, named "Videos I have watched on Driftcast", and under it the
/// same list as JSON for anything that wants to work with it.
///
/// The Movies folder because an app can write there without asking; the Documents, Desktop
/// and Downloads folders each put up a permission question first.
enum WatchedList {
    struct Entry: Equatable {
        var title: String
        var filename: String
        var played: Date
    }

    static let name = "Videos I have watched on Driftcast"
    static var folder: URL { FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0] }
    static func textURL(in folder: URL = folder) -> URL { folder.appendingPathComponent(name + ".txt") }
    static func jsonURL(in folder: URL = folder) -> URL { folder.appendingPathComponent(name + ".json") }

    /// Starting the same video again this soon is the same viewing, not another one: stopping
    /// to change the TV, or picking it up after a failed start.
    static let sameViewing: TimeInterval = 30 * 60

    private static let queue = DispatchQueue(label: "com.leechsoftware.driftcast.watchedlist")

    /// Notes a video that has started playing. Off the main thread; a failure goes to the error log.
    static func record(title: String, filename: String, played: Date = Date(), in folder: URL = folder) {
        queue.async {
            do { try add(Entry(title: title, filename: filename, played: played), in: folder) }
            catch { ErrorLog.record("Watched list", error: error) }
        }
    }

    /// Waits for entries still being written.
    static func flush() { queue.sync {} }

    /// The list so far, oldest first. Empty when nothing has been played or the file can't be read.
    static func entries(in folder: URL = folder) -> [Entry] {
        flush()
        return (try? Data(contentsOf: jsonURL(in: folder))).flatMap(decode)?.entries ?? []
    }

    /// Adds an entry and rewrites both files. False when it was the same viewing as the last one.
    @discardableResult
    static func add(_ entry: Entry, in folder: URL) throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = jsonURL(in: folder)
        var entries: [Entry] = []
        if let data = try? Data(contentsOf: json) {
            let read = decode(data)
            entries = read?.entries ?? []
            if read?.complete != true {
                // Edited into something that can't all be read: a copy is kept beside it, since
                // the rewrite below holds only the entries that could be.
                let aside = folder.appendingPathComponent(name + " (unreadable).json")
                try? fm.removeItem(at: aside)
                try fm.copyItem(at: json, to: aside)
            }
        }
        if let last = entries.last, last.filename == entry.filename,
           abs(entry.played.timeIntervalSince(last.played)) < sameViewing { return false }
        entries.append(entry)
        try Data(encode(entries).utf8).write(to: json, options: .atomic)
        let text = textURL(in: folder)
        try Data(self.text(entries).utf8).write(to: text, options: .atomic)
        // Without its ".txt" the readable file shows as just its name, and sorts above the JSON.
        try? fm.setAttributes([.extensionHidden: true], ofItemAtPath: text.path)
        return true
    }

    // MARK: The three forms

    /// JSON written by hand so the keys keep their order: filename, title, played.
    static func encode(_ entries: [Entry]) -> String {
        guard !entries.isEmpty else { return "[]\n" }
        let rows = entries.map {
            "  {\n    \"filename\": \(quoted($0.filename)),\n    \"title\": \(quoted($0.title)),\n    \"played\": \(quoted(stamp.string(from: $0.played)))\n  }"
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
            return Entry(title: title, filename: filename, played: played)
        }
        return (entries, entries.count == rows.count)
    }

    /// The file to read: newest first, three lines a video (the file, its cleaned name, when).
    static func text(_ entries: [Entry]) -> String {
        let when = DateFormatter()
        when.dateStyle = .medium
        when.timeStyle = .short
        var out = "\(name)\nNewest first. The same list is in the JSON file next to this one.\n"
        for e in entries.reversed() {
            out += "\n\(e.filename)\n    \(e.title)\n    Played \(when.string(from: e.played))\n"
        }
        return out
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
        let list = entries()
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

    /// Shows the readable list in the Finder, or says there is none yet.
    static func reveal() {
        flush()
        let text = textURL()
        if FileManager.default.fileExists(atPath: text.path) {
            NSWorkspace.shared.activateFileViewerSelecting([text])
        } else {
            let alert = NSAlert()
            alert.messageText = "No videos have been played yet"
            alert.informativeText = "The list is made in your Movies folder when the first video plays."
            alert.runModal()
        }
    }
}
