import AppKit
import Foundation

struct MediaItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var url: URL
    /// Subtitle files the user attached or downloaded (beyond ones found next to the video).
    var extraSubtitles: [URL] = []

    /// The file's name without its extension: "The.Sopranos.S04E07.1080p.BluRay.x265-RARBG".
    var baseName: String { url.deletingPathExtension().lastPathComponent }
    /// What the video is: "The Sopranos", season 4, episode 7. The title corrected by hand
    /// when there is one, else what the file name says.
    var parsedTitle: MediaTitle { TitleOverrides.title(for: url) ?? MediaTitle.parse(fileName: baseName) }
    /// The name shown for the video in lists, windows and on the TV: "The Sopranos S4 E7".
    var displayName: String { parsedTitle.displayName }
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    init(url: URL) { self.url = url }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        extraSubtitles = try c.decodeIfPresent([URL].self, forKey: .extraSubtitles) ?? []
    }
}

struct Playlist: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var items: [MediaItem] = []
}

struct WatchProgress: Codable, Hashable {
    var position: Double
    var duration: Double
    var updated: Date

    var fraction: Double { duration > 0 ? min(1, position / duration) : 0 }

    /// Where a video counts as finished: where its end credits start. A file with a credits
    /// chapter says exactly (less a few seconds for a stop pressed as they begin). Otherwise
    /// the last 4% is taken as the credits, at least 30 seconds and at most a tenth: about
    /// five minutes of a two-hour film, two of a 54-minute episode, a little before its credits.
    static func finishPoint(duration: Double, creditsStart: Double? = nil) -> Double {
        if let c = creditsStart, c > duration / 2, c < duration { return max(duration / 2, c - 10) }
        return duration - min(max(30, duration * 0.04), duration * 0.1)
    }
}

/// The file the library is kept in. Reading and writing go through one queue, so writes land
/// in the order they were asked for and an earlier list can't end up on top of a later one.
///
/// Every write replaces the whole file with this copy's list. Driftcast runs as one copy
/// (`SingleCopy`), but an older version opened beside it knows nothing of that, and whatever
/// it wrote is gone at this copy's next save. The file's date shows when something else has
/// written it; the first time goes to the error log, as does a save that fails.
final class LibraryFile: @unchecked Sendable {
    let url: URL
    let queue = DispatchQueue(label: "com.leechsoftware.driftcast.library", qos: .utility)
    /// The file's date when this copy last read or wrote it; nil when there was no file.
    private var seen: Date?
    private var reportedAnother = false
    private var failing = false

    init(url: URL) { self.url = url }

    private var modified: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    func read() -> Data? {
        queue.sync {
            let data = try? Data(contentsOf: url)
            seen = modified
            return data
        }
    }

    /// The file as it now stands is this copy's doing (it was just moved aside, say).
    func noteCurrent() { queue.sync { seen = modified } }

    /// Only on `queue`.
    func write(_ contents: () throws -> Data) {
        do {
            let data = try contents()
            if !reportedAnother, modified != seen {
                reportedAnother = true
                ErrorLog.record("Playlists", "The saved playlists were changed by something other than this copy of Driftcast, most likely a second copy open at the same time. This copy's list has replaced them.")
            }
            try data.write(to: url, options: .atomic)
            seen = modified
            failing = false
        } catch {
            // Said once, not at every save while it lasts: the place in a video is saved
            // every few seconds.
            if !failing { ErrorLog.record("Playlists", "saving them", error: error) }
            failing = true
        }
    }
}

/// Playlists plus last-position tracking, persisted as JSON in Application Support.
@MainActor
final class Library: ObservableObject {
    @Published var playlists: [Playlist] = []
    @Published var selection: Playlist.ID? { didSet { if oldValue != selection { save() } } }
    @Published var progress: [String: WatchProgress] = [:]
    /// Files the user has finished, so rows can show a "watched" mark.
    @Published var watched: Set<String> = []

    static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "wmv", "flv", "webm", "ts", "m2ts", "mts", "mpg", "mpeg",
        "vob", "ogv", "ogm", "3gp", "3g2", "divx", "asf", "rm", "rmvb", "f4v", "mxf", "dv", "y4m", "hevc",
        "h264", "mk3d", "trp", "tp", "wtv", "mp3", "m4a", "flac", "wav", "aac", "ogg", "opus",
    ]

    private struct Stored: Codable {
        var playlists: [Playlist]
        var progress: [String: WatchProgress]
        var watched: [String]?
        var selection: UUID?
    }

    private var saveWork: DispatchWorkItem?
    private let file: LibraryFile

    init() {
        file = LibraryFile(url: Self.storeURL)
        load()
        if playlists.isEmpty { playlists = [Playlist(name: "Playlist")] }
        if selection == nil || !playlists.contains(where: { $0.id == selection }) { selection = playlists.first?.id }
    }

    var selectedPlaylist: Playlist? { playlists.first { $0.id == selection } }

    // MARK: Persistence

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Driftcast", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }

    private func load() {
        guard let data = file.read() else { return }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            // Kept aside rather than overwritten by the empty library this run starts with.
            let aside = Self.storeURL.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: Self.storeURL, to: aside)
            file.noteCurrent()
            return
        }
        playlists = stored.playlists
        progress = stored.progress
        watched = Set(stored.watched ?? [])
        selection = stored.selection
    }

    /// Coalesces bursts of changes into one write.
    func save() {
        saveWork?.cancel()
        let snapshot = Stored(playlists: playlists, progress: progress, watched: Array(watched), selection: selection)
        let file = file
        let work = DispatchWorkItem { file.write { try JSONEncoder().encode(snapshot) } }
        saveWork = work
        file.queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes immediately. Used when quitting, where the delayed write in `save()` would never
    /// run and the last resume position or playlist edit would be lost. It waits its turn
    /// behind a delayed write that has already begun, so that older list can't land on top.
    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        let snapshot = Stored(playlists: playlists, progress: progress, watched: Array(watched), selection: selection)
        let file = file
        file.queue.sync { file.write { try JSONEncoder().encode(snapshot) } }
    }

    // MARK: Playlists

    @discardableResult
    func newPlaylist(named name: String? = nil) -> Playlist.ID {
        let base = name ?? "Playlist"
        var candidate = base
        var n = 2
        while playlists.contains(where: { $0.name == candidate }) { candidate = "\(base) \(n)"; n += 1 }
        let p = Playlist(name: candidate)
        playlists.append(p)
        selection = p.id
        save()
        return p.id
    }

    func rename(_ id: Playlist.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = trimmed
        save()
    }

    func deletePlaylist(_ id: Playlist.ID) {
        guard playlists.count > 1 else { return }
        playlists.removeAll { $0.id == id }
        if selection == id { selection = playlists.first?.id }
        save()
    }

    // MARK: Items

    /// Expands folders recursively and keeps only media files, sorted the way Finder sorts.
    static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                var found: [URL] = []
                for case let f as URL in e where videoExtensions.contains(f.pathExtension.lowercased()) { found.append(f) }
                found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                out += found
            } else if videoExtensions.contains(url.pathExtension.lowercased()) {
                out.append(url)
            }
        }
        return out
    }

    /// Adds videos to a playlist. Two or more files from the same show (see `SeriesName`) go
    /// into a playlist named after the show instead, which is created if needed and selected.
    @discardableResult
    func add(_ urls: [URL], to playlistID: Playlist.ID? = nil) -> [MediaItem] {
        guard let id = playlistID ?? selection, playlists.contains(where: { $0.id == id }) else { return [] }
        let files = Self.expand(urls)
        let (series, rest) = SeriesName.group(files.map { $0.deletingPathExtension().lastPathComponent })
        var added: [MediaItem] = []
        var firstSeriesPlaylist: Playlist.ID?

        for (n, group) in series.enumerated() {
            if group.season != nil { nameBySeason(show: group.show) }
            let index: Int
            if let existing = playlists.firstIndex(where: { $0.name.compare(group.title, options: .caseInsensitive) == .orderedSame }) {
                index = existing
            } else if n == 0, rest.isEmpty,
                      let target = playlists.firstIndex(where: { $0.id == id }),
                      playlists[target].items.isEmpty, Self.isDefaultName(playlists[target].name) {
                // An untouched empty playlist becomes the first season's rather than being left behind.
                playlists[target].name = group.title
                index = target
            } else {
                playlists.append(Playlist(name: group.title))
                index = playlists.count - 1
            }
            let present = Set(playlists[index].items.map(\.url))
            let episodes = group.members.map { files[$0] }
                .filter { !present.contains($0) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map { MediaItem(url: $0) }
            playlists[index].items += episodes
            added += episodes
            if firstSeriesPlaylist == nil { firstSeriesPlaylist = playlists[index].id }
        }

        if !rest.isEmpty, let target = playlists.firstIndex(where: { $0.id == id }) {
            var staying: [URL] = []
            for file in rest.map({ files[$0] }) {
                // An episode on its own joins its season's playlist when there is one. A
                // playlist isn't made for one video: without one it stays where it was dropped.
                guard let name = SeriesName.seasonPlaylist(forFileName: file.deletingPathExtension().lastPathComponent),
                      let home = playlists.firstIndex(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }),
                      home != target else { staying.append(file); continue }
                if !playlists[home].items.contains(where: { $0.url == file }) {
                    let item = MediaItem(url: file)
                    playlists[home].items.append(item)
                    added.append(item)
                }
                if firstSeriesPlaylist == nil { firstSeriesPlaylist = playlists[home].id }
            }
            // A video that is already in the playlist (opened again from Finder, say) is not
            // listed twice.
            let present = Set(playlists[target].items.map(\.url))
            let items = staying.filter { !present.contains($0) }.map { MediaItem(url: $0) }
            playlists[target].items += items
            added += items
        }
        if let firstSeriesPlaylist { selection = firstSeriesPlaylist }
        save()
        return added
    }

    /// Until seasons had playlists of their own, a show's playlist was named after the show
    /// alone. One that holds a single season takes that season's name when more of the show is
    /// added, so the new episodes join it, or sit beside it, under names that match. One that
    /// mixes seasons is left as it is.
    private func nameBySeason(show: String) {
        guard let i = playlists.firstIndex(where: { $0.name.compare(show, options: .caseInsensitive) == .orderedSame }) else { return }
        let seasons = Set(playlists[i].items.map { MediaTitle.parse(fileName: $0.baseName).season })
        guard seasons.count == 1, let only = seasons.first, let season = only else { return }
        let name = "\(playlists[i].name) S\(season)"
        guard !playlists.contains(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) else { return }
        playlists[i].name = name
    }

    private static func isDefaultName(_ name: String) -> Bool {
        name.range(of: #"^Playlist( \d+)?$"#, options: .regularExpression) != nil
    }

    func remove(_ itemIDs: Set<MediaItem.ID>, from playlistID: Playlist.ID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].items.removeAll { itemIDs.contains($0.id) }
        save()
    }

    /// Moves video files to the Trash, the one thing in Driftcast that touches a file on disk,
    /// and only ever from the right-click menu after the person has confirmed. A trashed file
    /// leaves every playlist it was in, along with its position and watched mark. Files that
    /// couldn't be trashed stay listed and are returned with the reason.
    ///
    /// A file listed twice is trashed once. A file that was already deleted or moved in the
    /// Finder has nothing left to trash, so it just leaves the playlists.
    @discardableResult
    func deleteFiles(_ urls: [URL], trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> [(URL, Error)] {
        var failed: [(URL, Error)] = []
        var gone: Set<String> = []
        var tried: Set<String> = []
        for url in urls where tried.insert(url.path).inserted {
            do {
                try trash(url)
                gone.insert(url.path)
            } catch {
                if Self.isAlreadyGone(url, error: error) { gone.insert(url.path) } else { failed.append((url, error)) }
            }
        }
        guard !gone.isEmpty else { return failed }
        for i in playlists.indices {
            playlists[i].items.removeAll { gone.contains($0.url.path) }
        }
        for path in gone {
            progress.removeValue(forKey: path)
            watched.remove(path)
        }
        save()
        return failed
    }

    /// Whether a file that couldn't be trashed is simply not there any more: the system says
    /// there is no such file, and the folder it was in can be reached. On a disk that isn't
    /// connected the folder is missing too, and that file stays listed.
    static func isAlreadyGone(_ url: URL, error: Error) -> Bool {
        let e = error as NSError
        let noSuchFile = e.domain == NSCocoaErrorDomain
            && (e.code == NSFileNoSuchFileError || e.code == NSFileReadNoSuchFileError)
        let fm = FileManager.default
        return noSuchFile && !fm.fileExists(atPath: url.path)
            && fm.fileExists(atPath: url.deletingLastPathComponent().path)
    }

    /// Moves videos to the end of another playlist.
    func moveItems(_ itemIDs: Set<MediaItem.ID>, from source: Playlist.ID, to destination: Playlist.ID) {
        guard source != destination,
              let s = playlists.firstIndex(where: { $0.id == source }),
              let d = playlists.firstIndex(where: { $0.id == destination }) else { return }
        let moving = playlists[s].items.filter { itemIDs.contains($0.id) }
        guard !moving.isEmpty else { return }
        playlists[s].items.removeAll { itemIDs.contains($0.id) }
        playlists[d].items += moving
        save()
    }

    func move(in playlistID: Playlist.ID, from source: IndexSet, to destination: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var items = playlists[i].items
        let moving = source.sorted().map { items[$0] }
        for index in source.sorted(by: >) { items.remove(at: index) }
        let target = destination - source.filter { $0 < destination }.count
        items.insert(contentsOf: moving, at: max(0, min(target, items.count)))
        playlists[i].items = items
        save()
    }

    func attachSubtitle(_ subtitle: URL, toFile file: URL) {
        for p in playlists.indices {
            for j in playlists[p].items.indices where playlists[p].items[j].url == file {
                if !playlists[p].items[j].extraSubtitles.contains(subtitle) { playlists[p].items[j].extraSubtitles.append(subtitle) }
            }
        }
        save()
    }

    /// Adds `urls` as `add` does and answers which video to play: the first one added, or,
    /// when all of them were listed already, the first of them in the playlist on show. With
    /// it comes the playlist it sits in, which plays on after it. Nil when none of `urls` is
    /// a video. Behind Open…, the toolbar's folder button and files opened from the Finder.
    func addToPlay(_ urls: [URL], to playlistID: Playlist.ID? = nil) -> (item: MediaItem, queue: [MediaItem])? {
        // With no playlist selected there is still somewhere to open into.
        let target = playlistID ?? selection ?? playlists.first?.id
        if selection == nil { selection = target }
        let added = add(urls, to: target)
        if let first = added.first,
           let home = playlists.first(where: { $0.items.contains { $0.id == first.id } }) {
            return (first, home.items)
        }
        // Listed already. Adding selects a show's playlist, so the selected one is looked in
        // before the one asked for. Matched on the files a folder holds, as adding does: a
        // folder reached through a link has another path than the files found in it.
        let files = Set(Self.expand(urls))
        for id in [selection, target] {
            guard let playlist = playlists.first(where: { $0.id == id }),
                  let listed = playlist.items.first(where: { files.contains($0.url) }) else { continue }
            return (listed, playlist.items)
        }
        return nil
    }

    /// The panel behind Open… and Add Videos…: videos or folders, several at once.
    func chooseVideos(prompt: String, message: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = prompt
        panel.message = message
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Add Videos…: what is chosen is listed, and nothing starts playing.
    func presentOpenPanel(into playlistID: Playlist.ID? = nil) {
        let urls = chooseVideos(prompt: "Add", message: "Choose videos or folders to add to the playlist. Nothing starts playing.")
        if !urls.isEmpty { add(urls, to: playlistID) }
    }

    // MARK: Watch progress

    func resumePosition(for url: URL) -> Double? { progress[url.path]?.position }

    func updateProgress(for url: URL, position: Double, duration: Double, creditsStart: Double? = nil) {
        guard duration > 0 else { return }
        if position >= WatchProgress.finishPoint(duration: duration, creditsStart: creditsStart) {
            markWatched(url)
        } else if position < 10 {
            return // keep any earlier resume point; "Play from Beginning" clears it explicitly
        } else {
            progress[url.path] = WatchProgress(position: position, duration: duration, updated: Date())
            watched.remove(url.path)
            save()
        }
    }

    func markWatched(_ url: URL) {
        progress.removeValue(forKey: url.path)
        watched.insert(url.path)
        save()
    }

    func clearProgress(_ url: URL) {
        progress.removeValue(forKey: url.path)
        watched.remove(url.path)
        save()
    }
}
