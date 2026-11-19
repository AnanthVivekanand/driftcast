import Foundation

/// Titles corrected by hand (Details > Search by Title…), by the file's path. One store for
/// the online lookup and for every place a video's name is shown, so a corrected film reads
/// the same in the details panel, the list, the window, the TV's panel and the watched list.
///
/// Read from any thread: names are needed while a list row is drawn, where there is no waiting.
enum TitleOverrides {
    private static let lock = NSLock()
    private static var loaded = false
    private static var titles: [String: MediaTitle] = [:]

    static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Driftcast", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("title-overrides.json")
    }

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
        if let data = try? JSONEncoder().encode(titles) { try? data.write(to: file, options: .atomic) }
    }

    private static func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode([String: MediaTitle].self, from: data) {
            titles = stored
        }
    }
}
