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
    /// The name the person typed for the video in the list (right-click > Rename, or a
    /// press held on the title), when they gave it one. It is shown as typed and changes
    /// nothing about what the video is taken to be: details are still looked up by `parsedTitle`.
    var givenName: String? { TitleOverrides.name(for: url) }
    /// The name shown for the video in lists, windows and on the TV: "The Sopranos S4 E7", or
    /// the name the person gave it.
    var displayName: String { givenName ?? parsedTitle.displayName }
    /// The two lines on the TV's own pause and seek panel (`MediaTitle.tvLines`). A name the
    /// person gave is the one line: it may say all there is to say ("The Sopranos (last)").
    func tvLines(lookedUp: Bool) -> (title: String, subtitle: String?) {
        if let givenName { return (givenName, nil) }
        return parsedTitle.tvLines(lookedUp: lookedUp)
    }
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

    /// Where the end credits are taken to start. A file with a credits chapter says exactly.
    /// Otherwise the last 4% is taken as the credits, at least 30 seconds and at most a tenth:
    /// about five minutes of a two-hour film, two of a 54-minute episode, a little before its
    /// credits.
    static func creditsPoint(duration: Double, creditsStart: Double? = nil) -> Double {
        if let c = creditsStart, c > duration / 2, c < duration { return c }
        return duration - min(max(30, duration * 0.04), duration * 0.1)
    }

    /// Where a video counts as finished: where its end credits start, less a few seconds
    /// before a credits chapter for a stop pressed as they begin.
    static func finishPoint(duration: Double, creditsStart: Double? = nil) -> Double {
        if let c = creditsStart, c > duration / 2, c < duration { return max(duration / 2, c - 10) }
        return creditsPoint(duration: duration)
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
    private var failedAside = false

    init(url: URL) { self.url = url }

    private var modified: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// What reading the file found.
    enum Contents {
        case none
        case data(Data)
        /// The file is there but couldn't be read: it belongs to another user, has lost its
        /// permissions, or the disk gave an error.
        case unreadable(Error)
    }

    func read() -> Data? {
        if case .data(let data) = contents() { return data }
        return nil
    }

    /// The file's bytes, telling a file that isn't there from one that couldn't be read. Taken
    /// alike, the second was replaced by an empty list at the first save.
    func contents() -> Contents {
        queue.sync {
            seen = modified
            guard FileManager.default.fileExists(atPath: url.path) else { return .none }
            do { return .data(try Data(contentsOf: url)) } catch { return .unreadable(error) }
        }
    }

    /// Moves the file out of the way (`setAside(_:)`) in its turn with the writes. Where it went,
    /// or nil when it couldn't be moved, which is logged once: it is tried at every save.
    func setAside() -> URL? {
        queue.sync {
            do {
                let aside = try Self.setAside(url)
                seen = modified
                return aside
            } catch {
                if !failedAside { ErrorLog.record("Playlists", "setting aside the file that couldn't be read", error: error) }
                failedAside = true
                return nil
            }
        }
    }

    /// Moves a file that couldn't be used to a name of its own beside it ("library.unreadable.json",
    /// then "library.unreadable 2.json"), so that nothing written later replaces it, nor an
    /// earlier one set aside. A rename in the same folder, which works on a file that can't
    /// be read. Answers where it went.
    static func setAside(_ url: URL) throws -> URL {
        let fm = FileManager.default
        let base = url.deletingPathExtension().lastPathComponent + ".unreadable"
        var aside: URL
        var n = 1
        repeat {
            aside = url.deletingLastPathComponent().appendingPathComponent(n == 1 ? base : "\(base) \(n)")
                .appendingPathExtension(url.pathExtension)
            n += 1
        } while fm.fileExists(atPath: aside.path)
        try fm.moveItem(at: url, to: aside)
        return aside
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

/// The orders Sort in the right-click menu can put a playlist in.
enum PlaylistOrder: CaseIterable {
    /// By the name each video is shown by, numbers in counting order ("E2" before "E10").
    case name
    /// By when each file arrived in its folder (the Finder's Date Added), the newest first.
    case dateAdded
    /// What is still to watch first, finished videos after it; otherwise as they were.
    case unwatchedFirst

    var label: String {
        switch self {
        case .name: return "By Name"
        case .dateAdded: return "By Date Added"
        case .unwatchedFirst: return "Unwatched First"
        }
    }
}

/// Playlists plus last-position tracking, persisted as JSON in Application Support.
@MainActor
final class Library: ObservableObject {
    @Published var playlists: [Playlist] = []
    @Published var selection: Playlist.ID? { didSet { if oldValue != selection, !isLoading { save(deliberately: false) } } }
    @Published var progress: [String: WatchProgress] = [:]
    /// Files the user has finished, so rows can show a "watched" mark.
    @Published var watched: Set<String> = []

    /// The video to select and scroll to after videos were added (dropped, chosen, opened):
    /// the first of them. `count` makes every add a change, the same video twice included.
    struct Reveal: Equatable {
        let item: MediaItem.ID
        let count: Int
    }
    @Published private(set) var reveal: Reveal?

    /// Selects a video in the list and brings it into view (Next and Previous Video do this
    /// for the one they start), when the playlist on show has it.
    func revealItem(_ id: MediaItem.ID) {
        reveal = Reveal(item: id, count: (reveal?.count ?? 0) + 1)
    }

    /// What the person should be told, once, about the saved playlists: that they couldn't be
    /// read at launch, and where the file is now. The window shows it and sets it back to nil.
    @Published var loadProblem: String?

    /// The window's undo manager, which the window hands over, so that Edit > Undo can take
    /// back changes to the playlists (Remove, Move, Sort, Delete Playlist, Rename and the rest).
    weak var undoManager: UndoManager?

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
    /// While the saved library is being read in: what was just read needs no writing back.
    private var isLoading = false
    /// The saved playlists are there but couldn't be read. Nothing is written over them: the
    /// list starts empty, a launch that changes nothing leaves the file as it was (a passing
    /// disk error reads fine next time), and the first change the person makes moves the file
    /// aside before the new list is saved. Without this the empty list replaced it half a
    /// second after launch.
    private var unreadFile = false

    /// `storeURL` is for the tests, which keep a library of their own; the app's is in
    /// Application Support.
    init(storeURL: URL? = nil) {
        file = LibraryFile(url: storeURL ?? Self.storeURL)
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
        let data: Data
        switch file.contents() {
        case .none:
            return
        case .unreadable(let error):
            ErrorLog.record("Playlists", "reading them", error: error)
            unreadFile = true
            loadProblem = "Driftcast couldn't open your saved playlists. \(error.localizedDescription) They are left as they are. If you change the list, the old file is first set aside in Driftcast's folder in Application Support."
            return
        case .data(let bytes):
            data = bytes
        }
        let stored: Stored
        do {
            stored = try JSONDecoder().decode(Stored.self, from: data)
        } catch {
            // Kept aside rather than overwritten by the empty library this run starts with.
            ErrorLog.record("Playlists", "reading them", error: error)
            if let aside = file.setAside() {
                ErrorLog.record("Playlists", "The file that couldn't be read was kept as \(aside.lastPathComponent).")
                loadProblem = "Driftcast couldn't read your saved playlists, so the list starts empty. The old file was kept as \u{201C}\(aside.lastPathComponent)\u{201D} in Driftcast's folder in Application Support."
            } else {
                unreadFile = true
                loadProblem = "Driftcast couldn't read your saved playlists. They are left as they are."
            }
            return
        }
        playlists = stored.playlists
        progress = stored.progress
        watched = Set(stored.watched ?? [])
        // Without this the selection's change scheduled a save of the list just read, half a
        // second after every launch: a write for nothing, and one that could land on top of
        // a newer list written in between.
        isLoading = true
        selection = stored.selection
        isLoading = false
    }

    /// Coalesces bursts of changes into one write.
    func save() { save(deliberately: true) }

    /// `deliberately` is false for what happens by itself (the selection set at launch), which
    /// doesn't move a file that couldn't be read out of the way.
    private func save(deliberately: Bool) {
        if unreadFile {
            guard deliberately, let aside = file.setAside() else { return }
            ErrorLog.record("Playlists", "The saved playlists that couldn't be read were kept as \(aside.lastPathComponent) before the new list was saved.")
            unreadFile = false
        }
        saveWork?.cancel()
        let stored = Stored(playlists: playlists, progress: progress, watched: Array(watched), selection: selection)
        let file = file
        let work = DispatchWorkItem { file.write { try JSONEncoder().encode(stored) } }
        saveWork = work
        file.queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes immediately. Used when quitting, where the delayed write in `save()` would never
    /// run and the last resume position or playlist edit would be lost. It waits its turn
    /// behind a delayed write that has already begun, so that older list can't land on top.
    func saveNow() {
        guard !unreadFile else { return }
        saveWork?.cancel()
        saveWork = nil
        let stored = Stored(playlists: playlists, progress: progress, watched: Array(watched), selection: selection)
        let file = file
        file.queue.sync { file.write { try JSONEncoder().encode(stored) } }
    }

    // MARK: Playlists

    @discardableResult
    func newPlaylist(named name: String? = nil) -> Playlist.ID {
        let base = name ?? "Playlist"
        var candidate = base
        var n = 2
        while playlists.contains(where: { $0.name == candidate }) { candidate = "\(base) \(n)"; n += 1 }
        let p = Playlist(name: candidate)
        let before = snapshot
        playlists.append(p)
        selection = p.id
        noteUndo("New Playlist", before)
        save()
        return p.id
    }

    func rename(_ id: Playlist.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        let before = snapshot
        playlists[i].name = trimmed
        noteUndo("Rename Playlist", before)
        save()
    }

    func deletePlaylist(_ id: Playlist.ID) {
        guard playlists.count > 1 else { return }
        let before = snapshot
        playlists.removeAll { $0.id == id }
        if selection == id { selection = playlists.first?.id }
        noteUndo("Delete Playlist", before)
        save()
    }

    /// Puts the playlists in another order in the sidebar, as `move(in:from:to:)` does videos.
    func movePlaylist(from source: IndexSet, to destination: Int) {
        let before = snapshot
        playlists = Self.moving(playlists, from: source, to: destination)
        noteUndo("Move Playlist", before)
        save()
    }

    /// `items` with those at `source` taken out and put back before what was at `destination`,
    /// as a list's drag reports it.
    private static func moving<T>(_ items: [T], from source: IndexSet, to destination: Int) -> [T] {
        var items = items
        let valid = source.filter { items.indices.contains($0) }
        let moving = valid.sorted().map { items[$0] }
        for index in valid.sorted(by: >) { items.remove(at: index) }
        let target = destination - valid.filter { $0 < destination }.count
        items.insert(contentsOf: moving, at: max(0, min(target, items.count)))
        return items
    }

    // MARK: Items

    /// Expands folders recursively and keeps only media files, sorted the way Finder sorts.
    ///
    /// Each file comes once. Selecting all in a Finder list with a folder opened by its
    /// triangle drags the folder and its files both, and a folder reached through a link names
    /// the same files by other paths; listed twice, each had two rows, and a single episode
    /// made a season playlist of itself. The first path a file comes by is the one kept.
    /// Where episodes added later go in their season's list. While the list is still in the
    /// order of its file names (nobody has dragged its rows about), each goes to its place in
    /// that order, so episodes 1 to 10 added after 11 to 13 come first. A list that has been
    /// rearranged by hand is left as it is, and they go at the end.
    static func merged(_ new: [MediaItem], into old: [MediaItem]) -> [MediaItem] {
        func comesFirst(_ a: MediaItem, _ b: MediaItem) -> Bool {
            a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
        guard !old.isEmpty, zip(old, old.dropFirst()).allSatisfy({ !comesFirst($1, $0) }) else { return old + new }
        var all = old
        for item in new {
            all.insert(item, at: all.firstIndex { comesFirst(item, $0) } ?? all.count)
        }
        return all
    }

    // MARK: A playlist of their own

    /// What a playlist made for these videos is called: the season of a show ("The Sopranos
    /// S4", for The.Sopranos.S04E12), the show when they span seasons, the film's own title, or
    /// what their names share. Nil when they have nothing in common.
    static func playlistName(for files: [URL]) -> String? {
        let names = files.map { $0.deletingPathExtension().lastPathComponent }
        guard !names.isEmpty else { return nil }
        func shared(_ values: [String?]) -> String? {
            guard let first = values.first ?? nil else { return nil }
            return values.allSatisfy { $0?.compare(first, options: .caseInsensitive) == .orderedSame } ? first : nil
        }
        if let season = shared(names.map(SeriesName.seasonPlaylist(forFileName:))) { return season }
        if let show = shared(names.map(SeriesName.title(fromFileName:))) { return show }
        let films = names.map { name -> String? in
            let title = MediaTitle.parse(fileName: name)
            return title.isEpisode || title.shownTitle.isEmpty ? nil : title.shownTitle
        }
        if let film = shared(films) { return film }
        return SeriesName.commonTitle(names)
    }

    private func playlistIndex(named name: String) -> Int? {
        playlists.firstIndex { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    /// Videos dropped on the empty part of the sidebar: a playlist of their own, named after
    /// them, shown. A playlist that already has that name takes them instead, so a season
    /// isn't listed twice; episodes of several seasons get a playlist each, as anywhere else.
    @discardableResult
    func addToNewPlaylist(_ urls: [URL]) -> [MediaItem] {
        let files = Self.expand(urls)
        guard !files.isEmpty else { return [] }
        let name = Self.playlistName(for: files)
        let spansSeasons = name != nil && Set(files.map { SeriesName.seasonPlaylist(forFileName: $0.deletingPathExtension().lastPathComponent) }).count > 1
        if let name, !spansSeasons, let existing = playlistIndex(named: name) {
            let id = playlists[existing].id
            let added = add(files, to: id)
            selection = id
            return added
        }
        // Seasons are split by `add`, which names an untouched playlist after the first one.
        let id = newPlaylist(named: spansSeasons ? nil : name)
        let added = add(files, to: id)
        if let i = playlists.firstIndex(where: { $0.id == id }), playlists[i].items.isEmpty, playlists.count > 1 {
            // Every episode joined a season already listed: the new playlist is not needed.
            playlists.remove(at: i)
            if selection == id { selection = playlists.first { p in added.contains { a in p.items.contains { $0.id == a.id } } }?.id ?? playlists.first?.id }
            save()
        }
        return added
    }

    /// Rows dragged from the list onto the empty part of the sidebar: moved to a playlist of
    /// their own, named after them (or one of that name that is already there), which is shown.
    func moveToNewPlaylist(_ itemIDs: Set<MediaItem.ID>, from source: Playlist.ID, at place: Int? = nil) {
        guard let s = playlists.firstIndex(where: { $0.id == source }) else { return }
        let moving = playlists[s].items.filter { itemIDs.contains($0.id) }
        guard !moving.isEmpty else { return }
        let name = Self.playlistName(for: moving.map(\.url))
        let target: Playlist.ID
        if let name, let existing = playlistIndex(named: name), playlists[existing].id != source {
            target = playlists[existing].id
        } else {
            let before = Set(playlists.map(\.id))
            target = newPlaylist(named: name)
            settle(newSince: before, at: place)
        }
        moveItems(itemIDs, from: source, to: target)
        selection = target
        if let first = moving.first { revealItem(first.id) }
    }

    /// Puts the playlists a drop just made where the drop's line was drawn in the sidebar:
    /// before what was at `place` when the drop came. Left at the foot with no place given.
    func settle(newSince before: Set<Playlist.ID>, at place: Int?) {
        guard let place, place >= 0 else { return }
        let made = playlists.filter { !before.contains($0.id) }
        guard !made.isEmpty, place < playlists.count - made.count else { return }
        playlists.removeAll { !before.contains($0.id) }
        playlists.insert(contentsOf: made, at: place)
        save()
    }

    static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        var seen: Set<String> = []
        func keep(_ url: URL) {
            if seen.insert(url.resolvingSymlinksInPath().standardizedFileURL.path).inserted { out.append(url) }
        }
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
                found.forEach(keep)
            } else if videoExtensions.contains(url.pathExtension.lowercased()) {
                keep(url)
            }
        }
        return out
    }

    /// Adds videos to a playlist. Two or more files from the same show (see `SeriesName`) go
    /// into a playlist named after the show instead, which is created if needed and selected.
    ///
    /// `index` is where in the playlist they go (dropped between two rows); without one, at
    /// the end. With no playlist named and none selected (a click on the sidebar's empty space
    /// clears it), they go into the first playlist, which is then shown, as `addToPlay` does:
    /// Add Videos… used to drop the files chosen without a word.
    @discardableResult
    func add(_ urls: [URL], to playlistID: Playlist.ID? = nil, at index: Int? = nil) -> [MediaItem] {
        guard let id = playlistID ?? selection ?? playlists.first?.id, playlists.contains(where: { $0.id == id }) else { return [] }
        if selection == nil { selection = id }
        let files = Self.expand(urls)
        let (series, rest) = SeriesName.group(files.map { $0.deletingPathExtension().lastPathComponent })
        let before = snapshot
        var added: [MediaItem] = []
        var firstSeriesPlaylist: Playlist.ID?
        var insertAt = index
        // Into the playlist dropped on, where it was dropped. Episodes into their own season's
        // playlist, in episode order (see `merged`); anything else at the end.
        func put(_ items: [MediaItem], into p: Int) {
            if playlists[p].id == id, let at = insertAt {
                let i = max(0, min(at, playlists[p].items.count))
                playlists[p].items.insert(contentsOf: items, at: i)
                insertAt = i + items.count
            } else if !items.isEmpty, items.allSatisfy({ item in
                SeriesName.seasonPlaylist(forFileName: item.baseName)?.compare(playlists[p].name, options: .caseInsensitive) == .orderedSame
            }) {
                playlists[p].items = Self.merged(items, into: playlists[p].items)
            } else {
                playlists[p].items += items
            }
        }

        for (n, group) in series.enumerated() {
            if group.season != nil { nameBySeason(show: group.show) }
            let season: Int
            if let existing = playlists.firstIndex(where: { $0.name.compare(group.title, options: .caseInsensitive) == .orderedSame }) {
                season = existing
            } else if n == 0, rest.isEmpty,
                      let target = playlists.firstIndex(where: { $0.id == id }),
                      playlists[target].items.isEmpty, Self.isDefaultName(playlists[target].name) {
                // An untouched empty playlist becomes the first season's rather than being left behind.
                playlists[target].name = group.title
                season = target
            } else {
                playlists.append(Playlist(name: group.title))
                season = playlists.count - 1
            }
            let present = Set(playlists[season].items.map(\.url))
            let episodes = group.members.map { files[$0] }
                .filter { !present.contains($0) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map { MediaItem(url: $0) }
            if playlists[season].id == id, insertAt != nil {
                put(episodes, into: season)
            } else {
                playlists[season].items = Self.merged(episodes, into: playlists[season].items)
            }
            added += episodes
            if firstSeriesPlaylist == nil { firstSeriesPlaylist = playlists[season].id }
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
                    playlists[home].items = Self.merged([item], into: playlists[home].items)
                    added.append(item)
                }
                if firstSeriesPlaylist == nil { firstSeriesPlaylist = playlists[home].id }
            }
            // A video that is already in the playlist (opened again from Finder, say) is not
            // listed twice.
            let present = Set(playlists[target].items.map(\.url))
            let items = staying.filter { !present.contains($0) }.map { MediaItem(url: $0) }
            put(items, into: target)
            added += items
        }
        if let firstSeriesPlaylist { selection = firstSeriesPlaylist }
        // What the list then selects and scrolls to: the first video added. When all of them
        // were listed already, the first of them in the playlist on show.
        let wanted = Set(files)
        let listed = [selection, id].lazy.compactMap { shown in
            self.playlists.first { $0.id == shown }?.items.first { wanted.contains($0.url) }
        }.first
        if let first = added.first ?? listed { reveal = Reveal(item: first.id, count: (reveal?.count ?? 0) + 1) }
        noteUndo("Add Videos", before)
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
        let before = snapshot
        playlists[i].items.removeAll { itemIDs.contains($0.id) }
        noteUndo("Remove from Playlist", before)
        save()
    }

    /// Remove Missing Videos: the rows of a playlist whose file is gone from a disk that is
    /// connected (deleted, or moved or renamed in the Finder). A file on a disk that isn't
    /// connected is only away, and stays listed. A removed video's place and watched mark are
    /// kept, for when it comes back. Answers the rows removed.
    @discardableResult
    func removeMissing(from playlistID: Playlist.ID) -> [MediaItem] {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return [] }
        let gone = playlists[i].items.filter { Self.isGone($0.url) }
        guard !gone.isEmpty else { return [] }
        let before = snapshot
        let ids = Set(gone.map(\.id))
        playlists[i].items.removeAll { ids.contains($0.id) }
        noteUndo("Remove Missing Videos", before)
        save()
        return gone
    }

    /// Whether a file is gone rather than away: it isn't there, and the disk it was on is.
    nonisolated static func isGone(_ url: URL) -> Bool {
        !FileManager.default.fileExists(atPath: url.path) && isOnConnectedDisk(url)
    }

    /// Whether the disk a path is on is connected. A disk other than the startup disk appears
    /// as a folder in /Volumes while it is; when it isn't, that folder is missing, or left
    /// behind empty and no longer a disk of its own.
    nonisolated static func isOnConnectedDisk(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents          // "/", "Volumes", "Films", …
        guard parts.count > 2, parts[1] == "Volumes" else { return true }
        let disk = URL(fileURLWithPath: "/Volumes", isDirectory: true).appendingPathComponent(parts[2], isDirectory: true)
            .resolvingSymlinksInPath()                              // the startup disk's own name links to /
        return (try? disk.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
    }

    /// Locate…: a listed video whose file was moved or renamed is pointed at where it is now.
    /// Every row of that file follows, in every playlist, and so do its place, its watched mark
    /// and the names given to it, which are all kept by the file's path. A playlist that also
    /// listed the new file keeps only the located row. Nothing on disk is touched.
    ///
    /// When the new path has a place or a watched mark of its own (it was played there), that
    /// one is kept. Edit > Undo can't take this back, so the steps before it are forgotten:
    /// undoing one of them would put the old path back.
    func relocate(_ item: MediaItem, to newURL: URL) {
        let old = item.url
        guard old.standardizedFileURL != newURL.standardizedFileURL else { return }
        for p in playlists.indices where playlists[p].items.contains(where: { $0.url == old }) {
            playlists[p].items.removeAll { $0.url == newURL }
            var listed = false
            playlists[p].items = playlists[p].items.compactMap { row in
                guard row.url == old else { return row }
                if listed { return nil }   // the file was listed twice: once is enough
                listed = true
                var moved = row
                moved.url = newURL
                return moved
            }
        }
        let place = progress.removeValue(forKey: old.path)
        let finished = watched.remove(old.path) != nil
        if progress[newURL.path] == nil, !watched.contains(newURL.path) {
            if finished { watched.insert(newURL.path) } else if let place { progress[newURL.path] = place }
        }
        TitleOverrides.move(from: old, to: newURL)
        undoManager?.removeAllActions(withTarget: self)
        objectWillChange.send()   // a name given to the file is read as rows draw
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
        // The files are in the Trash, which Edit > Undo here can't bring back; the steps
        // before are forgotten too, since undoing one would list the trashed files again.
        undoManager?.removeAllActions(withTarget: self)
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

    /// Moves videos to the end of another playlist. One the other playlist already lists
    /// leaves this one and isn't listed there twice.
    func moveItems(_ itemIDs: Set<MediaItem.ID>, from source: Playlist.ID, to destination: Playlist.ID) {
        guard source != destination,
              let s = playlists.firstIndex(where: { $0.id == source }),
              let d = playlists.firstIndex(where: { $0.id == destination }) else { return }
        let moving = playlists[s].items.filter { itemIDs.contains($0.id) }
        guard !moving.isEmpty else { return }
        let before = snapshot
        playlists[s].items.removeAll { itemIDs.contains($0.id) }
        var present = Set(playlists[d].items.map(\.url.standardizedFileURL.path))
        playlists[d].items += moving.filter { present.insert($0.url.standardizedFileURL.path).inserted }
        noteUndo("Move to Playlist", before)
        save()
    }

    func move(in playlistID: Playlist.ID, from source: IndexSet, to destination: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let before = snapshot
        playlists[i].items = Self.moving(playlists[i].items, from: source, to: destination)
        noteUndo("Move", before)
        save()
    }

    /// Names a video as the person typed it (right-click > Rename, or a press held on the
    /// title). The name goes with the file, so it is the same in every playlist, in the
    /// window, on the TV and in the watched list. Nothing typed, or the name the video has
    /// anyway, goes back to the name made from the file.
    func setName(_ typed: String, for url: URL) {
        let name = TitleOverrides.cleaned(typed, insteadOf: MediaItem(url: url).parsedTitle.displayName)
        let old = TitleOverrides.name(for: url)
        guard name != old else { return }
        TitleOverrides.setName(name, for: url)
        objectWillChange.send()   // rows read the name as they draw; nothing published holds it
        noteNameUndo(old, for: url)
    }

    /// Edit > Undo after a rename: the name the video had before, and Redo the one after.
    private func noteNameUndo(_ name: String?, for url: URL) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { library in
            let now = TitleOverrides.name(for: url)
            TitleOverrides.setName(name, for: url)
            library.objectWillChange.send()
            library.noteNameUndo(now, for: url)
        }
        undoManager.setActionName("Rename")
    }

    // MARK: Undo

    /// The playlists as they were before a change, for Edit > Undo to put back.
    private struct Snapshot {
        var playlists: [Playlist]
        var selection: Playlist.ID?
    }

    private var snapshot: Snapshot { Snapshot(playlists: playlists, selection: selection) }

    /// Registers the undo of a change to the playlists, when it changed them. Every change to
    /// the playlists is registered or, when it can't be undone (Delete File, Locate…), forgets
    /// the steps before it, so that putting back an earlier list never undoes a later change
    /// along with it. Changes made in one click (a new playlist and the videos moved into it)
    /// are one step, as the undo manager groups them by event.
    private func noteUndo(_ action: String, _ before: Snapshot) {
        guard let undoManager, playlists != before.playlists else { return }
        undoManager.registerUndo(withTarget: self) { library in library.restore(before, action: action) }
        undoManager.setActionName(action)
    }

    private func restore(_ earlier: Snapshot, action: String) {
        let now = snapshot
        // Subtitles attached since then (found or downloaded as a video played) stay attached.
        var attached: [MediaItem.ID: [URL]] = [:]
        for item in playlists.lazy.flatMap(\.items) where !item.extraSubtitles.isEmpty { attached[item.id] = item.extraSubtitles }
        playlists = earlier.playlists.map { playlist in
            var playlist = playlist
            for i in playlist.items.indices {
                for subtitle in attached[playlist.items[i].id] ?? [] where !playlist.items[i].extraSubtitles.contains(subtitle) {
                    playlist.items[i].extraSubtitles.append(subtitle)
                }
            }
            return playlist
        }
        if let shown = earlier.selection, playlists.contains(where: { $0.id == shown }) {
            selection = shown
        } else if !playlists.contains(where: { $0.id == selection }) {
            selection = playlists.first?.id
        }
        noteUndo(action, now)   // what Redo puts back
        save()
    }

    /// When a file arrived in its folder, as the Finder's Date Added has it; for a disk that
    /// doesn't keep that, when the file was made.
    nonisolated static func dateAdded(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
        return values?.addedToDirectoryDate ?? values?.creationDate
    }

    /// Puts a playlist in order, once (right-click > Sort). The order is still the person's
    /// to change by dragging, and nothing keeps it sorted as videos are added. Videos that
    /// compare the same stay in the order they were in.
    func sort(_ playlistID: Playlist.ID, by order: PlaylistOrder, dateAdded: (URL) -> Date? = Library.dateAdded) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let items = playlists[i].items
        let before: (MediaItem, MediaItem) -> Bool?   // nil when the two compare the same
        switch order {
        case .name:
            before = { a, b in
                let c = a.displayName.localizedStandardCompare(b.displayName)
                return c == .orderedSame ? nil : c == .orderedAscending
            }
        case .dateAdded:
            let dates = Dictionary(items.map { ($0.id, dateAdded($0.url)) }, uniquingKeysWith: { first, _ in first })
            before = { a, b in
                // A file that can't be found has no date and goes last.
                switch (dates[a.id] ?? nil, dates[b.id] ?? nil) {
                case let (x?, y?): return x == y ? nil : x > y
                case (nil, nil): return nil
                case (let x, _): return x != nil
                }
            }
        case .unwatchedFirst:
            let watched = watched
            before = { a, b in
                let x = watched.contains(a.url.path), y = watched.contains(b.url.path)
                return x == y ? nil : !x
            }
        }
        let sorted = items.enumerated().sorted { a, b in before(a.element, b.element) ?? (a.offset < b.offset) }.map(\.element)
        guard sorted != items else { return }
        let earlier = snapshot
        playlists[i].items = sorted
        noteUndo("Sort", earlier)
        save()
    }

    /// Takes an attached subtitle file off a video, in every row that lists it. The file
    /// itself stays where it is.
    func detachSubtitle(_ subtitle: URL, fromFile file: URL) {
        for p in playlists.indices {
            for j in playlists[p].items.indices where playlists[p].items[j].url == file {
                playlists[p].items[j].extraSubtitles.removeAll { $0 == subtitle }
            }
        }
        save()
    }

    /// The subtitle files attached to a video by hand or from OpenSubtitles: the ones that
    /// can be taken off again. Tracks inside the video and files beside it are not among them.
    func attachedSubtitles(ofFile file: URL) -> [URL] {
        playlists.lazy.flatMap(\.items).first { $0.url == file }?.extraSubtitles ?? []
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
