import Foundation

/// What the person has said about a video's name, by the file's path. Two things, kept apart:
///
/// - A title corrected by hand (Details > Search by Title…) says what the video is. It is used
///   for the online lookup and is the name shown.
/// - A name typed in the list (right-click > Rename) says only what to call it: "The
///   Sopranos (last)". It is shown as typed, in place of either, and looked up by nothing.
///
/// One store for every place a video's name is shown, so it reads the same in the details
/// panel, the list, the window, the TV's panel and the watched list.
///
/// Read from any thread: names are needed while a list row is drawn, where there is no waiting.
enum TitleOverrides {
    private static let lock = NSLock()
    private static var loaded = false
    private static var titles: [String: MediaTitle] = [:]
    private static var names: [String: String] = [:]
    /// The file was there at launch but couldn't be read, or what it held couldn't be. What
    /// is in memory is then not all there is, so the next save sets the file aside first
    /// instead of writing the one new entry over everything (see `write`).
    private static var titlesUnread = false
    private static var namesUnread = false

    private static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Driftcast", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var file: URL { folder.appendingPathComponent("title-overrides.json") }
    /// Beside the corrected titles rather than inside them: a version that knows nothing of
    /// typed names reads and rewrites that file, and would drop them.
    static var namesFile: URL { folder.appendingPathComponent("title-names.json") }

    static func title(for url: URL) -> MediaTitle? {
        lock.lock(); defer { lock.unlock() }
        load()
        return titles[url.path]
    }

    /// Remembers a corrected title for a file; nil goes back to the file name.
    static func set(_ title: MediaTitle?, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        load()
        titles[url.path] = title
        write(titles, to: file, unread: &titlesUnread, what: "Search by Title")
    }

    /// The name typed for a file in the list, when there is one.
    static func name(for url: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        load()
        return names[url.path]
    }

    /// Remembers a typed name for a file; nil goes back to the name made from the file.
    static func setName(_ name: String?, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        load()
        names[url.path] = name
        write(names, to: namesFile, unread: &namesUnread, what: "Rename")
    }

    /// Locate… (`Library.relocate`): what was said about a file goes with it to its new path,
    /// unless something was said about the new path already.
    static func move(from old: URL, to new: URL) {
        lock.lock(); defer { lock.unlock() }
        load()
        if let title = titles.removeValue(forKey: old.path) {
            if titles[new.path] == nil { titles[new.path] = title }
            write(titles, to: file, unread: &titlesUnread, what: "Locate")
        }
        if let name = names.removeValue(forKey: old.path) {
            if names[new.path] == nil { names[new.path] = name }
            write(names, to: namesFile, unread: &namesUnread, what: "Locate")
        }
    }

    /// What was typed, as a name to keep: without the spaces around it and on one line. Nil
    /// when nothing was typed, or when it is the name the video is shown by anyway (`shown`),
    /// so that opening the text box and pressing Return doesn't pin today's name to the file.
    static func cleaned(_ typed: String, insteadOf shown: String) -> String? {
        let name = typed.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name == shown ? nil : name
    }

    /// Reads both files again, as at launch. For the tests.
    static func reload() {
        lock.lock(); defer { lock.unlock() }
        loaded = false
        load()
    }

    private static func load() {
        guard !loaded else { return }
        loaded = true
        (titles, titlesUnread) = read(file) ?? ([:], false)
        (names, namesUnread) = read(namesFile) ?? ([:], false)
    }

    /// What a file holds; nil when there is no file. A file that couldn't be read, or whose
    /// contents couldn't, gives an empty list marked unread, and goes to the error log.
    private static func read<T: Decodable & ExpressibleByDictionaryLiteral>(_ url: URL) -> (T, Bool)? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return (try JSONDecoder().decode(T.self, from: Data(contentsOf: url)), false)
        } catch {
            ErrorLog.record("Names", "reading \(url.lastPathComponent)", error: error)
            return ([:], true)
        }
    }

    /// Saves a list. One that couldn't be read at launch is first moved aside, under a name of
    /// its own (`LibraryFile.setAside`); if that can't be done, nothing is written, rather
    /// than one entry over all the others. Failures go to the error log under `what`.
    private static func write<T: Encodable>(_ value: T, to url: URL, unread: inout Bool, what: String) {
        if unread, FileManager.default.fileExists(atPath: url.path) {
            do {
                let aside = try LibraryFile.setAside(url)
                ErrorLog.record(what, "\(url.lastPathComponent) couldn't be read and was kept as \(aside.lastPathComponent).")
            } catch {
                ErrorLog.record(what, "setting aside \(url.lastPathComponent), which couldn't be read", error: error)
                return
            }
        }
        unread = false
        do {
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            ErrorLog.record(what, "saving \(url.lastPathComponent)", error: error)
        }
    }
}
