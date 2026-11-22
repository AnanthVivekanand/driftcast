import Foundation

/// Looks on OpenSubtitles, by itself, for a video shown in the details panel that has no
/// captions in the subtitle language, so the panel can say a subtitle was found online and
/// offer it (the user's request, 2026-11-21).
///
/// Only searches: they cost nothing. Downloads are limited to a few a day, so one is made only
/// when the person clicks Use.
///
/// What a lookup found is kept on disk (`online-subtitles.json`), so a video already looked up
/// isn't searched again, even after a restart: a subtitle worth offering for 30 days, nothing or
/// nothing worth offering for 3 (new subtitles are uploaded all the time). A failed search isn't
/// kept, so it is tried again.
@MainActor
final class OnlineSubtitleLookup: ObservableObject {
    static let shared = OnlineSubtitleLookup()

    enum State: Equatable {
        case looking
        /// The best result, and how many there were.
        case found(OpenSubtitlesClient.Result, count: Int)
        /// Looked, and OpenSubtitles has nothing. Not called "none": `x ?? .none` is read as
        /// an empty optional, which cleared the state instead of setting it.
        case nothing
        /// The search failed (no network, OpenSubtitles down); the panel says nothing.
        case failed
        /// The found subtitle is being downloaded.
        case downloading(OpenSubtitlesClient.Result)
        /// Downloaded and attached to the video: nothing more to offer or look up.
        case used
    }

    @Published private(set) var states: [String: State] = [:]

    /// One finished lookup as it is kept on disk.
    struct Saved: Codable {
        var best: OpenSubtitlesClient.Result?
        var count: Int
        var checked: Date
    }
    private var saved: [String: Saved] = [:]
    /// By video path, the OpenSubtitles results that were added and then taken off again
    /// (out of sync, most likely): never offered or fetched for that video again.
    private var rejected: [String: Set<Int>] = [:]

    /// The file as written since Remove Subtitle came in. 1.1.4 wrote the lookups alone.
    private struct Store: Codable {
        var lookups: [String: Saved]
        var rejected: [String: Set<Int>]
    }
    /// Videos whose bubble has already opened by itself this run, so it pops up once only.
    private var announced: Set<String> = []

    nonisolated static let foundKeptFor: TimeInterval = 30 * 24 * 3600
    nonisolated static let noneKeptFor: TimeInterval = 3 * 24 * 3600

    nonisolated static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Driftcast", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("online-subtitles.json")
    }

    init() {
        // A cache: a file that can't be read is just started again.
        guard let data = try? Data(contentsOf: Self.file) else { return }
        if let store = try? JSONDecoder().decode(Store.self, from: data) {
            saved = store.lookups.filter { Self.isFresh($0.value) }
            rejected = store.rejected
        } else if let entries = try? JSONDecoder().decode([String: Saved].self, from: data) {
            saved = entries.filter { Self.isFresh($0.value) }
        }
    }

    nonisolated static func isFresh(_ entry: Saved, now: Date = Date()) -> Bool {
        // One that isn't offered (same title only) counts as nothing: a better one may be uploaded.
        let offered = entry.best.map(isOffered) ?? false
        return now.timeIntervalSince(entry.checked) < (offered ? foundKeptFor : noneKeptFor)
    }

    /// One queue, so two saves close together land in the order they were made.
    private nonisolated static let writes = DispatchQueue(label: "com.leechsoftware.driftcast.online-subtitles", qos: .utility)

    private func remember(_ key: String, _ entry: Saved?) {
        saved[key] = entry
        write()
    }

    private func write() {
        let store = Store(lookups: saved, rejected: rejected)
        Self.writes.async {
            guard let data = try? JSONEncoder().encode(store) else { return }
            try? data.write(to: Self.file, options: .atomic)
        }
    }

    /// The results taken off this video before, which are passed over for it.
    func rejectedResults(for url: URL) -> Set<Int> { rejected[url.path] ?? [] }

    /// A subtitle file was taken off the video. When it came from OpenSubtitles it is not
    /// offered for that video again, and the video is looked up afresh, so the next best can be.
    func subtitleRemoved(_ file: URL, from video: URL) {
        if let id = OpenSubtitlesClient.fileID(ofDownloaded: file) {
            rejected[video.path, default: []].insert(id)
        }
        let prefix = video.path + "|"
        for key in Set(states.keys).union(saved.keys) where key.hasPrefix(prefix) {
            states[key] = nil
            saved[key] = nil
        }
        write()
    }

    private static func key(_ url: URL, _ language: String) -> String { url.path + "|" + language.lowercased() }

    func state(for url: URL, language: String) -> State? { states[Self.key(url, language)] }

    /// The found subtitle when it is likely to fit the file: an exact match, the same release, or
    /// a close one. One for the same title only isn't offered anywhere; it may well be out of
    /// sync, and Find Subtitles Online still lists it (the user's call, 2026-11-21).
    func offer(for url: URL, language: String) -> OpenSubtitlesClient.Result? {
        switch states[Self.key(url, language)] {
        case .found(let best, _), .downloading(let best): return Self.isOffered(best) ? best : nil
        default: return nil
        }
    }

    nonisolated static func isOffered(_ result: OpenSubtitlesClient.Result) -> Bool { Match(result) != .titleOnly }

    /// True the first time it is asked for a video, after which the bubble only opens when clicked.
    func firstAnnouncement(for url: URL, language: String) -> Bool {
        announced.insert(Self.key(url, language)).inserted
    }

    /// Searches for the video once; a second call for the same video and language does nothing
    /// (unless the first failed).
    func look(for item: MediaItem, language: String) async {
        let key = Self.key(item.url, language)
        // "I don't care about subtitles": no looking, no offers.
        // A search that failed (no network) is tried again the next time the video is shown.
        guard states[key] == nil || states[key] == .failed, OpenSubtitlesClient.hasKey, !language.isEmpty,
              !Prefs.bool(Prefs.hideSubtitleNotices) else { return }
        if let entry = saved[key], Self.isFresh(entry) {
            states[key] = entry.best.map { State.found($0, count: entry.count) } ?? State.nothing
            return
        }
        states[key] = .looking
        // Its own task, so a search once begun finishes and is kept even when the view that asked
        // goes away meanwhile (the video window closing at the end of a short video). Tied to the
        // view, it was cancelled and nothing was kept.
        let search = Task { try await OpenSubtitlesClient.searchVideo(item, language: language) }
        do {
            let found = try await search.value
            // One that only covers the foreign-language lines isn't the film's subtitles.
            let passedOver = rejectedResults(for: item.url)
            let best = found.first(where: { !$0.foreignPartsOnly && !passedOver.contains($0.fileID) })
            states[key] = best.map { State.found($0, count: found.count) } ?? State.nothing
            remember(key, Saved(best: best, count: found.count, checked: Date()))
        } catch {
            states[key] = .failed
        }
    }

    /// Downloads the found subtitle. The caller attaches it to the video. Nil, with the error
    /// logged and the offer left in place, when the download fails.
    func download(for item: MediaItem, language: String) async -> (URL?, Error?) {
        let key = Self.key(item.url, language)
        guard case .found(let best, let count) = states[key] else { return (nil, nil) }
        states[key] = .downloading(best)
        do {
            let file = try await OpenSubtitlesClient.fromSettings().download(best, for: item.url)
            // Attached to the video now, so there is nothing left to offer.
            states[key] = .used
            remember(key, nil)
            return (file, nil)
        } catch {
            ErrorLog.record("Subtitle download", item.url.lastPathComponent, error: error)
            // The offer stays for another try; the kept lookup doesn't, in case the subtitle
            // has been taken off OpenSubtitles since.
            states[key] = .found(best, count: count)
            remember(key, nil)
            return (nil, error)
        }
    }

    /// How good a match a found subtitle is, in words a person reads at a glance. A bare mark
    /// beside "No closed captions" didn't say what had been found (the user's report, 2026-11-21).
    enum Match {
        /// Made from this very file.
        case exact
        /// Made for the same release (same group and source).
        case sameRelease
        /// Another release, but from the same kind of source or with much the same name.
        case close
        /// Only the same title: it may well be out of sync.
        case titleOnly

        nonisolated init(_ result: OpenSubtitlesClient.Result) {
            self = result.hashMatch ? .exact : result.releaseMatch ? .sameRelease : result.isClose ? .close : .titleOnly
        }

        /// The pill beside "No closed captions".
        nonisolated var found: String {
            switch self {
            case .exact: return "Exact match found"
            case .sameRelease: return "Same release found"
            case .close: return "Close match found"
            case .titleOnly: return "Subtitles found online"
            }
        }

        /// In a menu item's title.
        nonisolated var short: String {
            switch self {
            case .exact: return "Exact Match"
            case .sameRelease: return "Same Release"
            case .close: return "Close Match"
            case .titleOnly: return "Same Title Only"
            }
        }

        /// The tag in the bubble.
        nonisolated var tag: String {
            switch self {
            case .exact: return "EXACT MATCH"
            case .sameRelease: return "SAME RELEASE"
            case .close: return "CLOSE MATCH"
            case .titleOnly: return "SAME TITLE ONLY"
            }
        }
    }

    /// The subtitle menus' item that adds a found subtitle, so it can be taken from where
    /// subtitles are chosen and not only from the bubble (the user's request, 2026-11-22):
    /// "Add English Subtitles Found Online (Close Match)".
    nonisolated static func menuTitle(_ result: OpenSubtitlesClient.Result, language: String) -> String {
        "Add \(Lang.name(language) ?? language) Subtitles Found Online (\(Match(result).short))"
    }

    /// What the panel says about a found subtitle: how near it is to the file.
    nonisolated static func describe(_ result: OpenSubtitlesClient.Result) -> String {
        if result.hashMatch { return "Made from this exact file." }
        if result.releaseMatch { return "Made for this release, so it should be in sync." }
        if result.isClose { return "Close to this file, so it is likely in sync." }
        return "For this title, not this file, so it may be out of sync."
    }
}

extension OpenSubtitlesClient {
    /// Every subtitle OpenSubtitles has for the video in `language`, best first: by the file's
    /// fingerprint first, then by its title (with the season and episode for a show).
    static func searchVideo(_ item: MediaItem, language: String) async throws -> [Result] {
        let client = try fromSettings()
        let title = await MetadataLookup.shared.title(for: item.url)
        let hash = await Task.detached { movieHash(for: item.url) }.value
        var found = try await client.search(query: title.searchQuery, languages: language, movieHash: hash,
                                            season: title.season, episode: title.episode, videoName: item.baseName)
        if found.isEmpty, hash != nil {
            found = try await client.search(query: title.searchQuery, languages: language, movieHash: nil,
                                            season: title.season, episode: title.episode, videoName: item.baseName)
        }
        return found
    }
}
