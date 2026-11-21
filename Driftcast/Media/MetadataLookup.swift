import CryptoKit
import Foundation

/// Looks up posters, plot, director, cast and ratings for the videos in the library.
///
/// Films come from Wikipedia (poster, plot) and Wikidata (director, writers, cast, genres,
/// running time, IMDb link), shows and episodes from TVmaze; none needs an account or key.
/// With an OMDb key (`OMDbClient`), OMDb is asked first, which adds IMDb, Rotten Tomatoes and
/// Metacritic ratings. Everything is cached on disk, the services are asked no faster than
/// they allow, and nothing is looked up when "Look up posters and details online" is off.
actor MetadataLookup {
    static let shared = MetadataLookup()

    private struct Entry: Codable {
        var details: MovieDetails?
        var fetched: Date
        /// A request after the first one failed (a timeout, a busy service), so the details lack
        /// what it would have brought (an episode's name, a film's people). Asked again after
        /// `partialRetry`; kept for good, such a film never got its cast.
        var partial: Bool?
        /// The OMDb key the lookup was made with (`OMDbClient.fingerprint`, "" for none), and
        /// whether OMDb answered. Details found without OMDb's answer are asked for again once
        /// a key is set or changed, or a day later with the same key.
        var omdbKey: String?
        var omdbAnswered: Bool?
    }

    enum Fetched {
        case data(Data)
        case notFound
        case failed
    }

    private enum Outcome {
        case found(MovieDetails, partial: Bool)
        case none
        case failed
    }

    /// What a lookup came to, and whether OMDb answered along the way.
    private struct Lookup {
        var outcome: Outcome
        var omdbAnswered = false
    }

    private var memory: [String: Entry] = [:]
    private var inFlight: [String: Task<Lookup, Never>] = [:]
    private var artworkMemory: [URL: Data] = [:]
    private var artworkOrder: [URL] = []
    private var nextAllowed: [String: Date] = [:]

    static var isEnabled: Bool { Prefs.bool(Prefs.onlineDetails) }

    /// A title that found nothing is asked about again after this long.
    private static let retryAfter: TimeInterval = 3 * 86_400
    /// Details that came back without a part of them (`Entry.partial`) are asked for again
    /// after this long.
    private static let partialRetry: TimeInterval = 3600

    /// Smallest gap between requests to one service.
    private static let spacing: [String: TimeInterval] = [
        "en.wikipedia.org": 0.35,
        "www.wikidata.org": 0.35,
        "api.tvmaze.com": 0.6,
        "www.omdbapi.com": 0.3,
    ]

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        return URLSession(configuration: config)
    }()

    private static func directory(_ name: String, in base: FileManager.SearchPathDirectory) -> URL {
        let dir = FileManager.default.urls(for: base, in: .userDomainMask)[0]
            .appendingPathComponent("Driftcast/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var cacheDirectory: URL { directory("Metadata", in: .cachesDirectory) }
    private static var artworkDirectory: URL { directory("Artwork", in: .cachesDirectory) }

    private static func hash(_ s: String) -> String {
        String(SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    static func key(_ t: MediaTitle) -> String {
        "\(TitleMatch.normalize(t.title))|\(t.year ?? 0)|\(t.season ?? 0)|\(t.episode ?? 0)" + (t.country.map { "|\($0)" } ?? "")
    }

    /// Sound files: songs and recordings, not films.
    static let audioExtensions: Set<String> = ["mp3", "m4a", "flac", "wav", "aac", "ogg", "opus"]

    /// Whether a file is looked up online by itself, as its row appears, it is selected or it
    /// starts to play. Not a sound file ("Yesterday.mp3" was given a film's poster and plot),
    /// nor a video a camera, a phone or the screen recorder named ("IMG_2019.MOV",
    /// "Screen Recording …"): their names say nothing a film database knows, and sending them
    /// sends a person's own recordings out. Search by Title… still finds any of them, and its
    /// title is looked up from then on.
    static func looksUpByItself(_ url: URL) -> Bool {
        if TitleOverrides.title(for: url) != nil { return true }
        if audioExtensions.contains(url.pathExtension.lowercased()) { return false }
        return !MediaTitle.isDeviceRecording(fileName: url.deletingPathExtension().lastPathComponent)
    }

    // MARK: Titles

    /// What the file is about: the title the person corrected by hand, else what the file name says.
    func title(for url: URL) -> MediaTitle {
        TitleOverrides.title(for: url) ?? MediaTitle.parse(fileName: url.deletingPathExtension().lastPathComponent)
    }

    /// Remembers a corrected title for a file (nil goes back to the file name).
    func setTitle(_ title: MediaTitle?, for url: URL) {
        TitleOverrides.set(title, for: url)
    }

    // MARK: Details

    /// Details already on disk or in memory, without going online. None for a file that isn't
    /// looked up by itself (`looksUpByItself`), so a film found for "Birthday Party.mov" before
    /// that rule doesn't stay on its row.
    func cached(for url: URL) -> MovieDetails? {
        guard Self.looksUpByItself(url) else { return nil }
        return entry(for: Self.key(title(for: url)))?.details
    }

    /// Details for a file. `refresh` asks the services again even when an answer is cached
    /// (a Refresh the person chose), and for a file that isn't looked up by itself too.
    func details(for url: URL, refresh: Bool = false) async -> MovieDetails? {
        guard refresh || Self.looksUpByItself(url) else { return nil }
        return await details(for: title(for: url), refresh: refresh)
    }

    /// Details for a title, from the cache or the services. `refresh` asks again even when an
    /// answer is cached.
    func details(for title: MediaTitle, refresh: Bool = false) async -> MovieDetails? {
        let key = Self.key(title)
        let cached = entry(for: key)
        if !refresh, let cached, !isStale(cached) { return cached.details }
        guard Self.isEnabled else { return cached?.details }
        if let running = inFlight[key] {
            if case .found(let d, _) = await running.value.outcome { return d }
            return cached?.details
        }
        let task = Task { await self.lookup(title) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        func made(_ details: MovieDetails?, partial: Bool) -> Entry {
            Entry(details: details, fetched: Date(), partial: partial ? true : nil,
                  omdbKey: OMDbClient.fingerprint(OMDbClient.activeKey), omdbAnswered: result.omdbAnswered)
        }
        switch result.outcome {
        case .found(let d, let partial):
            store(made(d, partial: partial), for: key)
            return d
        case .none:
            // Asked again by itself (a key was set, a part was missing): what was found before
            // stays, and with nothing more to be had it isn't asked for again. Asked again by
            // the person, the answer stands.
            if !refresh, let earlier = cached?.details {
                store(made(earlier, partial: false), for: key)
                return earlier
            }
            store(made(nil, partial: false), for: key)
            return nil
        case .failed:
            return cached?.details
        }
    }

    /// Whether a cached answer is to be asked for again: nothing was found a while ago, a part
    /// was missing an hour ago, or OMDb's answer is wanted (`wantsOMDb`).
    private func isStale(_ e: Entry) -> Bool {
        let age = Date().timeIntervalSince(e.fetched)
        if e.details == nil, age >= Self.retryAfter { return true }
        if e.partial == true, age >= Self.partialRetry { return true }
        return Self.wantsOMDb(e, age: age)
    }

    /// An OMDb key is set, and the answer was had without OMDb's: with no key or another one
    /// (entered in Settings since), or a day or more ago with this one while OMDb wasn't
    /// answering (the key turned down, the day's requests used up). Without this, a key
    /// entered later changed nothing for the videos already looked up.
    private static func wantsOMDb(_ e: Entry, age: TimeInterval) -> Bool {
        let key = OMDbClient.activeKey
        guard !key.isEmpty, e.omdbAnswered != true else { return false }
        return e.omdbKey != OMDbClient.fingerprint(key) || age >= 86_400
    }

    private func entry(for key: String) -> Entry? {
        if let e = memory[key] { return e }
        let file = Self.cacheDirectory.appendingPathComponent(Self.hash(key) + ".json")
        guard let data = try? Data(contentsOf: file), let e = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        memory[key] = e
        return e
    }

    private func store(_ entry: Entry, for key: String) {
        memory[key] = entry
        let file = Self.cacheDirectory.appendingPathComponent(Self.hash(key) + ".json")
        if let data = try? JSONEncoder().encode(entry) { try? data.write(to: file, options: .atomic) }
    }

    private func lookup(_ t: MediaTitle) async -> Lookup {
        var failed = false
        var omdbAnswered = false
        if !OMDbClient.activeKey.isEmpty {
            switch await omdb(t) {
            case .found(let d, let partial): return Lookup(outcome: .found(d, partial: partial), omdbAnswered: true)
            case .failed: failed = true
            case .none: omdbAnswered = true
            }
        }
        return Lookup(outcome: await lookupWithoutKey(t, failed: failed), omdbAnswered: omdbAnswered)
    }

    /// Wikipedia, Wikidata and TVmaze, which need no key. `failed`: OMDb was asked and didn't answer.
    private func lookupWithoutKey(_ t: MediaTitle, failed: Bool) async -> Outcome {
        var failed = failed
        if t.isEpisode {
            switch await tvmaze(t) {
            case .found(let d, let partial): return .found(d, partial: partial)
            case .failed: return .failed
            case .none: return failed ? .failed : .none
            }
        }
        var fromWikipedia: (details: MovieDetails, partial: Bool)?
        switch await wikipedia(t) {
        case .found(let d, let partial):
            // A show found on Wikipedia is better served by TVmaze (rating, episodes), with
            // Wikipedia's people kept if TVmaze has none.
            if d.showTitle == nil { return .found(d, partial: partial) }
            fromWikipedia = (d, partial)
        case .failed: failed = true
        case .none: break
        }
        // A title without episode markers can still be a show ("Planet Earth").
        switch await tvmaze(t) {
        case .found(var d, let partial):
            if let w = fromWikipedia?.details {
                if d.cast.isEmpty { d.cast = w.cast }
                if d.directors.isEmpty { d.directors = w.directors }
                if d.writers.isEmpty { d.writers = w.writers }
            }
            return .found(d, partial: partial || fromWikipedia?.partial == true)
        case .failed:
            // What Wikipedia found stands for now, and TVmaze is asked again later.
            return fromWikipedia.map { .found($0.details, partial: true) } ?? .failed
        case .none:
            return fromWikipedia.map { .found($0.details, partial: $0.partial) } ?? (failed ? .failed : .none)
        }
    }

    // MARK: Services

    private func omdb(_ t: MediaTitle) async -> Outcome {
        let outcome = await omdb(t, exactOnly: false)
        // A show whose name does end in a year ("Space 1999") is asked for as written too.
        if case .none = outcome, let written = t.asWritten { return await omdb(written, exactOnly: true) }
        return outcome
    }

    private func omdb(_ t: MediaTitle, exactOnly: Bool) async -> Outcome {
        let key = OMDbClient.activeKey
        if t.isEpisode {
            // The year the file gives the show ("Doctor Who 2005") picks it among shows of one name.
            guard let showURL = OMDbClient.url(title: t.title, year: t.year, type: "series", key: key) else { return .none }
            let showData: Data
            switch await omdbFetch(showURL) {
            case .data(let data): showData = data
            case .notFound: return .none
            case .failed: return .failed
            }
            guard var show = OMDbClient.parse(showData, wanted: t, exactOnly: exactOnly) else { return .none }
            var partial = false
            if let episodeURL = OMDbClient.episodeURL(title: show.title, season: t.season ?? 1, episode: t.episode ?? 1, key: key) {
                switch await omdbFetch(episodeURL) {
                case .data(let episodeData): show = OMDbClient.parseEpisode(episodeData, into: show)
                case .notFound: break
                case .failed: partial = true
                }
            }
            show.season = show.season ?? t.season
            show.episode = show.episode ?? t.episode
            return .found(show, partial: partial)
        }
        guard let url = OMDbClient.url(title: t.title, year: t.year, type: "movie", key: key) else { return .none }
        switch await omdbFetch(url) {
        case .data(let data):
            if let d = OMDbClient.parse(data, wanted: t, exactOnly: exactOnly) { return .found(d, partial: false) }
            return .none
        case .notFound: return .none
        case .failed: return .failed
        }
    }

    /// An OMDb request. OMDb says in its answer what went wrong ("Invalid API key!", "Request
    /// limit reached!"); that is kept for Settings to show (`OMDbClient.problem`), and cleared
    /// by the next answer. "Not found" is an answer. A request that never got through says
    /// nothing about the key and changes nothing.
    private func omdbFetch(_ url: URL) async -> Fetched {
        guard let (status, data) = await fetchResponse(url) else { return .failed }
        let said = OMDbClient.error(in: data)
        if (200...299).contains(status), said.map(OMDbClient.isNotFound) ?? true {
            OMDbClient.noteProblem(nil)
            return .data(data)
        }
        OMDbClient.noteProblem(OMDbClient.problem(status: status, said: said))
        return .failed
    }

    /// Wikipedia's article for the film (poster, plot), then its Wikidata entry (people,
    /// genres, running time, IMDb link). Four small requests, all cached afterwards. When one
    /// of the last two fails, what the first two found is a partial answer.
    private func wikipedia(_ t: MediaTitle) async -> Outcome {
        guard let searchURL = Wikipedia.searchURL(t) else { return .none }
        let page: String
        switch await fetch(searchURL) {
        case .failed: return .failed
        case .notFound: return .none
        case .data(let data):
            guard let found = Wikipedia.pickPage(data, wanted: t) else { return .none }
            page = found
        }
        guard let summaryURL = Wikipedia.summaryURL(pageTitle: page) else { return .none }
        var details: MovieDetails
        var qid: String?
        switch await fetch(summaryURL) {
        case .failed: return .failed
        case .notFound: return .none
        case .data(let data):
            guard let parsed = Wikipedia.parseSummary(data, wanted: t) else { return .none }
            details = parsed.details
            qid = parsed.qid
        }
        var partial = false
        if let qid, let entityURL = Wikidata.entityURL(qid) {
            switch await fetch(entityURL) {
            case .data(let entityData):
                let claims = Wikidata.parseEntity(entityData, qid: qid)
                var labels: [String: String] = [:]
                let ids = claims.labelIDs
                if !ids.isEmpty, let labelsURL = Wikidata.labelsURL(ids) {
                    switch await fetch(labelsURL) {
                    case .data(let labelData): labels = Wikidata.parseLabels(labelData)
                    case .notFound: break
                    case .failed: partial = true
                    }
                }
                details = Wikidata.apply(claims, labels: labels, to: details)
            case .notFound: break
            case .failed: partial = true
            }
        }
        return .found(details, partial: partial)
    }

    private enum ShowFound {
        case show(MovieDetails, id: Int)
        case none
        case failed
    }

    /// The show on TVmaze, then the episode. A show whose name ends in a year ("Space 1999")
    /// that isn't found as "Space" first shown in 1999 is looked for by its whole name.
    private func tvmaze(_ t: MediaTitle) async -> Outcome {
        var found = await tvmazeShow(t, exactOnly: false)
        if case .none = found, let written = t.asWritten { found = await tvmazeShow(written, exactOnly: true) }
        switch found {
        case .failed: return .failed
        case .none: return .none
        case .show(let show, let id):
            guard let episode = t.episode, let episodeURL = TVmaze.episodeURL(showID: id, season: t.season ?? 1, episode: episode) else {
                return .found(show, partial: false)
            }
            let partial: Bool
            switch await fetch(episodeURL) {
            case .data(let episodeData): return .found(TVmaze.parseEpisode(episodeData, into: show), partial: false)
            case .notFound: partial = false      // TVmaze has no such episode
            case .failed: partial = true
            }
            var withNumbers = show
            withNumbers.season = t.season
            withNumbers.episode = episode
            return .found(withNumbers, partial: partial)
        }
    }

    private func tvmazeShow(_ t: MediaTitle, exactOnly: Bool) async -> ShowFound {
        guard let url = TVmaze.searchURL(t.title) else { return .none }
        switch await fetch(url) {
        case .failed: return .failed
        case .notFound: return .none
        case .data(let data):
            guard let (show, id) = TVmaze.pickShow(data, wanted: t, exactOnly: exactOnly) else { return .none }
            return .show(show, id: id)
        }
    }

    /// One request, paced per service. 404 means "nothing there", any other trouble "failed".
    private func fetch(_ url: URL, accept: String = "application/json") async -> Fetched {
        guard let (status, data) = await fetchResponse(url, accept: accept) else { return .failed }
        if status == 404 { return .notFound }
        guard (200...299).contains(status) else { return .failed }
        return .data(data)
    }

    /// One request, paced per service: the status and the body, or nil when no answer came.
    private func fetchResponse(_ url: URL, accept: String = "application/json") async -> (Int, Data)? {
        let host = url.host ?? ""
        let gap = Self.spacing[host] ?? 0.5
        let now = Date()
        let slot = max(now, (nextAllowed[host] ?? .distantPast))
        nextAllowed[host] = slot.addingTimeInterval(gap)
        let wait = slot.timeIntervalSince(now)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }

        var request = URLRequest(url: url)
        request.setValue("Driftcast/\(AppVersion.installed) (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await Self.session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    }

    // MARK: Artwork

    /// The image at `url`, from the cache or downloaded (unless `allowNetwork` is false).
    func artwork(_ url: URL, allowNetwork: Bool = true) async -> Data? {
        if let d = artworkMemory[url] { return d }
        let file = Self.artworkDirectory.appendingPathComponent(Self.hash(url.absoluteString) + ".img")
        if let d = try? Data(contentsOf: file) {
            remember(d, for: url)
            return d
        }
        guard allowNetwork, Self.isEnabled, case .data(let d) = await fetch(url, accept: "image/*"), !d.isEmpty else { return nil }
        try? d.write(to: file, options: .atomic)
        remember(d, for: url)
        return d
    }

    private func remember(_ data: Data, for url: URL) {
        artworkMemory[url] = data
        artworkOrder.append(url)
        if artworkOrder.count > 60 { artworkMemory[artworkOrder.removeFirst()] = nil }
    }

    // MARK: With a deadline

    /// `details(for:)` that gives up waiting after `seconds`, for a video that is about to play.
    /// The lookup itself carries on and lands in the cache for the playlist row and next time.
    nonisolated func details(for url: URL, within seconds: Double) async -> MovieDetails? {
        await Deadline.first(within: seconds) { await self.details(for: url) }
    }

    /// `artwork(_:)` that gives up waiting after `seconds`; the download carries on regardless.
    nonisolated func artwork(_ url: URL, within seconds: Double) async -> Data? {
        await Deadline.first(within: seconds) { await self.artwork(url) }
    }
}

/// Runs work that must not be canceled (its result is cached for later) but that a caller
/// will only wait so long for.
enum Deadline {
    static func first<T: Sendable>(within seconds: Double, _ operation: @escaping @Sendable () async -> T?) async -> T? {
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            Task {
                let value = await operation()
                if once.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    /// Lets exactly one of two racing tasks deliver the answer.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

/// Decides whether a search result is the title the file name describes.
enum TitleMatch {
    /// Lower case, no accents or punctuation, no leading article.
    static func normalize(_ s: String) -> String {
        var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        t = t.replacingOccurrences(of: "&", with: " and ")
        t = String(t.map { $0.isLetter || $0.isNumber ? $0 : " " })
        var words = t.split(separator: " ").map(String.init)
        if let first = words.first, ["the", "a", "an"].contains(first), words.count > 1 { words.removeFirst() }
        return words.joined(separator: " ")
    }

    /// 0 for no match; higher is better. A year that is known on both sides must agree
    /// (give or take one, for festival releases).
    ///
    /// Names are compared by whole words: "In the Heat of the Night" holds "Heat", but "Cheat
    /// Sheet" doesn't, nor "Mother Father Son" "Her".
    static func score(candidate: String, year: Int?, wanted: MediaTitle) -> Int {
        let a = normalize(candidate), b = normalize(wanted.title)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let aw = a.split(separator: " "), bw = b.split(separator: " ")
        var score: Int
        if a == b {
            score = 3
        } else if aw.starts(with: bw) || bw.starts(with: aw) || contains(aw, bw) {
            score = 1
        } else {
            return 0
        }
        if let y = year, let w = wanted.year {
            if abs(y - w) <= 1 { score += 2 } else { return 0 }
        }
        return score
    }

    /// Whether `words` holds `run`, word for word and in a row.
    private static func contains(_ words: [Substring], _ run: [Substring]) -> Bool {
        guard !run.isEmpty, run.count <= words.count else { return false }
        return (0...(words.count - run.count)).contains { words[$0..<($0 + run.count)].elementsEqual(run) }
    }
}

/// Wikipedia: the article about a film gives its poster and lead paragraph, and names the
/// Wikidata entry that holds the facts. No key is needed; the text is CC BY-SA, so the details
/// panel links back to the article.
enum Wikipedia {
    static func searchURL(_ t: MediaTitle) -> URL? {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")
        let words = t.year.map { "\(t.title) \($0) film" } ?? "\(t.title) film"
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: words), URLQueryItem(name: "srlimit", value: "8"),
            URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "utf8", value: "1"),
        ]
        return components?.url
    }

    static func summaryURL(pageTitle: String) -> URL? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        guard let encoded = pageTitle.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)")
    }

    /// "Heat (1995 film)" -> ("Heat", 1995, true).
    static func split(_ pageTitle: String) -> (base: String, year: Int?, suffix: String) {
        guard let open = pageTitle.lastIndex(of: "("), pageTitle.hasSuffix(")") else { return (pageTitle, nil, "") }
        let base = String(pageTitle[..<open]).trimmingCharacters(in: .whitespaces)
        let suffix = String(pageTitle[pageTitle.index(after: open)...].dropLast()).lowercased()
        let year = suffix.range(of: #"\b(19|20)\d\d\b"#, options: .regularExpression).flatMap { Int(suffix[$0]) }
        return (base, year, suffix)
    }

    private static let notFilms = ["disambiguation", "soundtrack", "novel", "song", "album", "video game", "character", "band", "comics", "play", "musical", "book", "magazine", "company"]

    /// The search result that is the wanted title, as a page title, or nil.
    static func pickPage(_ data: Data, wanted: MediaTitle) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = (root["query"] as? [String: Any])?["search"] as? [[String: Any]] else { return nil }
        var best: (String, Int)?
        for r in results {
            guard let title = r["title"] as? String else { continue }
            let parts = split(title)
            if notFilms.contains(where: { parts.suffix.contains($0) }) { continue }
            // Article titles are canonical, so only the same title counts: "Heat 2" or "In the
            // Heat of the Night" must not stand in for "Heat".
            var score = TitleMatch.score(candidate: parts.base, year: parts.year, wanted: wanted)
            guard score >= 3 else { continue }
            if parts.suffix.contains("film") || parts.suffix.contains("series") || parts.suffix.contains("miniseries") { score += 1 }
            if score > (best?.1 ?? 0) { best = (title, score) }
        }
        return best?.0
    }

    private static let filmWords = ["film", "movie", "television", "tv series", "miniseries", "documentary", "anime", "series", "special"]

    /// The article's summary as details, when it is about a film or show that fits the title.
    static func parseSummary(_ data: Data, wanted: MediaTitle) -> (details: MovieDetails, qid: String?)? {
        guard let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (r["type"] as? String) == "standard", let pageTitle = r["title"] as? String else { return nil }
        let description = (r["description"] as? String ?? "").lowercased()
        let extract = r["extract"] as? String ?? ""
        guard filmWords.contains(where: { description.contains($0) }) || extract.lowercased().prefix(200).contains(" film") else { return nil }
        let parts = split(pageTitle)
        func year(in text: String) -> Int? {
            text.range(of: #"\b(19[2-9]\d|20\d\d)\b"#, options: .regularExpression).flatMap { Int(text[$0]) }
        }
        let foundYear = parts.year ?? year(in: description) ?? year(in: String(extract.prefix(300)))
        guard TitleMatch.score(candidate: parts.base, year: foundYear, wanted: wanted) > 0 else { return nil }
        var d = MovieDetails(title: parts.base, source: "Wikipedia")
        d.year = foundYear
        d.synopsis = extract.isEmpty ? nil : extract
        let original = r["originalimage"] as? [String: Any]
        let thumbnail = r["thumbnail"] as? [String: Any]
        let image = ((original?["width"] as? Int ?? 0) <= 1200 ? original : nil) ?? thumbnail
        d.posterURL = (image?["source"] as? String).flatMap(URL.init)
        d.link = ((r["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"].flatMap { $0 as? String }.flatMap(URL.init)
        if description.contains("series") || description.contains("television") { d.showTitle = parts.base }
        // "1995 crime drama film by Michael Mann": the director, until Wikidata says more.
        if let by = description.range(of: " by ") {
            let name = String(description[by.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !name.contains(" and "), d.showTitle == nil {
                d.directors = [name.capitalized]
            }
        }
        return (d, r["wikibase_item"] as? String)
    }
}

/// Wikidata: the structured facts behind a Wikipedia article.
enum Wikidata {
    struct Claims {
        var directors: [String] = []
        var writers: [String] = []
        var cast: [String] = []
        var genres: [String] = []
        var certificate: String?
        var durationMinutes: Int?
        var year: Int?
        var imdbID: String?
        var isSeries = false
        var ratings: [MovieDetails.Rating] = []

        /// Every entity whose English label is needed.
        var labelIDs: [String] {
            var ids = directors + writers + cast + genres
            if let certificate { ids.append(certificate) }
            return Array(NSOrderedSet(array: ids)) as? [String] ?? ids
        }
    }

    static func entityURL(_ qid: String) -> URL? {
        URL(string: "https://www.wikidata.org/wiki/Special:EntityData/\(qid).json")
    }

    static func labelsURL(_ ids: [String]) -> URL? {
        var components = URLComponents(string: "https://www.wikidata.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "wbgetentities"), URLQueryItem(name: "ids", value: ids.prefix(50).joined(separator: "|")),
            // Names that are the same in every language now live under "mul", not "en".
            URLQueryItem(name: "props", value: "labels"), URLQueryItem(name: "languages", value: "en|mul"),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components?.url
    }

    static func parseEntity(_ data: Data, qid: String) -> Claims {
        var c = Claims()
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entity = (root["entities"] as? [String: Any])?[qid] as? [String: Any],
              let claims = entity["claims"] as? [String: Any] else { return c }
        func statements(_ property: String) -> [[String: Any]] { claims[property] as? [[String: Any]] ?? [] }
        func value(_ statement: [String: Any]) -> Any? {
            ((statement["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"]
        }
        func items(_ property: String) -> [String] {
            statements(property).compactMap { (value($0) as? [String: Any])?["id"] as? String }
        }
        // Cast in billing order where Wikidata records it (series ordinal), else as listed.
        let castStatements = statements("P161")
        func ordinal(_ statement: [String: Any]) -> Int {
            let q = ((statement["qualifiers"] as? [String: Any])?["P1545"] as? [[String: Any]])?.first
            return Int(((q?["datavalue"] as? [String: Any])?["value"] as? String) ?? "") ?? Int.max
        }
        c.cast = castStatements.sorted { ordinal($0) < ordinal($1) }.compactMap { (value($0) as? [String: Any])?["id"] as? String }.prefix(8).map { $0 }
        c.directors = items("P57")
        c.writers = Array(items("P58").prefix(4))
        c.genres = Array(items("P136").prefix(4))
        c.certificate = items("P1657").first
        c.isSeries = items("P31").contains { ["Q5398426", "Q1259759", "Q15416", "Q117467246"].contains($0) }
        c.durationMinutes = statements("P2047").compactMap { statement -> Int? in
            guard let v = value(statement) as? [String: Any], let amount = v["amount"] as? String else { return nil }
            let unit = v["unit"] as? String ?? ""
            guard let n = Double(amount) else { return nil }
            // Int(exactly:): a value too large for an Int (a vandalized entry) is nil, where
            // Int() stopped the app, at every launch while that film's row was on screen.
            return unit.hasSuffix("Q7727") ? Int(exactly: n.rounded()) : (unit.hasSuffix("Q11574") ? Int(exactly: (n / 60).rounded()) : nil)
        }.first
        c.year = statements("P577").compactMap { statement -> Int? in
            guard let v = value(statement) as? [String: Any], let time = v["time"] as? String else { return nil }
            return Int(time.dropFirst().prefix(4))
        }.min()
        c.imdbID = statements("P345").compactMap { value($0) as? String }.first
        // Review scores (P444) and who gave them (P447). Rotten Tomatoes records both its
        // percentage and an average mark; the percentage is the one people know.
        let reviewers = ["Q37312": "IMDb", "Q105584": "Rotten Tomatoes", "Q150248": "Metacritic"]
        var scores: [String: String] = [:]
        for statement in statements("P444") {
            guard (statement["rank"] as? String) != "deprecated", let score = value(statement) as? String,
                  let qualifier = ((statement["qualifiers"] as? [String: Any])?["P447"] as? [[String: Any]])?.first,
                  let id = ((qualifier["datavalue"] as? [String: Any])?["value"] as? [String: Any])?["id"] as? String,
                  let name = reviewers[id] else { continue }
            if let existing = scores[name] {
                let better = (score.hasSuffix("%") && !existing.hasSuffix("%")) || (statement["rank"] as? String) == "preferred"
                if better { scores[name] = score }
            } else {
                scores[name] = score
            }
        }
        c.ratings = ["IMDb", "Rotten Tomatoes", "Metacritic"].compactMap { name in scores[name].map { MovieDetails.Rating(source: name, value: $0) } }
        return c
    }

    static func parseLabels(_ data: Data) -> [String: String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entities = root["entities"] as? [String: Any] else { return [:] }
        var labels: [String: String] = [:]
        for (id, entity) in entities {
            guard let byLanguage = (entity as? [String: Any])?["labels"] as? [String: Any] else { continue }
            let preferred = (byLanguage["en"] ?? byLanguage["mul"] ?? byLanguage.values.first) as? [String: Any]
            if let label = preferred?["value"] as? String { labels[id] = label }
        }
        return labels
    }

    static func apply(_ c: Claims, labels: [String: String], to details: MovieDetails) -> MovieDetails {
        var d = details
        func names(_ ids: [String]) -> [String] { ids.compactMap { labels[$0] } }
        // The director read from the article's description stands when Wikidata has no name.
        let directors = names(c.directors)
        if !directors.isEmpty { d.directors = directors }
        d.writers = names(c.writers)
        d.cast = names(c.cast)
        if !c.genres.isEmpty { d.genres = names(c.genres).map { $0.replacingOccurrences(of: " film", with: "").capitalized } }
        if let certificate = c.certificate, let label = labels[certificate] { d.certificate = label }
        if let minutes = c.durationMinutes, minutes > 0 { d.runtimeMinutes = minutes }
        if d.year == nil { d.year = c.year }
        if let imdb = c.imdbID { d.link = URL(string: "https://www.imdb.com/title/\(imdb)/") }
        if c.isSeries, d.showTitle == nil { d.showTitle = d.title }
        if d.ratings.isEmpty { d.ratings = c.ratings }
        return d
    }
}

/// TVmaze: shows and episodes with poster, rating, network, genres and synopses. No key is
/// needed; TVmaze asks only for a link back, which the details view shows.
enum TVmaze {
    /// The search that answers with every show that fits, best first. Its single-answer form
    /// gave one show for a name: there are three called "Doctor Who", and only the year a file
    /// names tells which.
    static func searchURL(_ name: String) -> URL? {
        var components = URLComponents(string: "https://api.tvmaze.com/search/shows")
        components?.queryItems = [URLQueryItem(name: "q", value: name)]
        return components?.url
    }

    static func episodeURL(showID: Int, season: Int, episode: Int) -> URL? {
        URL(string: "https://api.tvmaze.com/shows/\(showID)/episodebynumber?season=\(season)&number=\(episode)")
    }

    /// One show, as TVmaze describes it, when it is the one wanted.
    static func parseShow(_ data: Data, wanted: MediaTitle) -> (MovieDetails, Int)? {
        guard let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return pick([r], wanted: wanted, exactOnly: false)
    }

    /// The show wanted among a search's answers (`searchURL`), best first. With a year or a
    /// country to go by, the name that fits best and, among shows of one name, the one first
    /// shown in that year (a year more or less is allowed) or made in that country; the
    /// service's order settles a tie. Without, the first answer when it fits. With
    /// `exactOnly`, only the very name counts.
    static func pickShow(_ data: Data, wanted: MediaTitle, exactOnly: Bool = false) -> (MovieDetails, Int)? {
        guard let results = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return pick(results.compactMap { $0["show"] as? [String: Any] }, wanted: wanted, exactOnly: exactOnly)
    }

    /// TVmaze's code for the countries `MediaTitle.country` reads from file names.
    private static let countryCodes = ["US": "US", "UK": "GB", "AU": "AU"]

    private static func pick(_ shows: [[String: Any]], wanted: MediaTitle, exactOnly: Bool) -> (MovieDetails, Int)? {
        // With no year or country to choose by, the first answer or none, as before.
        let choosing = exactOnly || wanted.year != nil || wanted.country != nil
        var best: (show: [String: Any], score: Int)?
        for show in choosing ? shows : Array(shows.prefix(1)) {
            guard let name = show["name"] as? String else { continue }
            // An episode's name has a year only when the file gave its show one (the year it
            // was first shown); otherwise the premiere year is held against nothing.
            var score = TitleMatch.score(candidate: name, year: premiered(show), wanted: wanted)
            if exactOnly, score < 3 { continue }
            if let wantedCountry = wanted.country.flatMap({ countryCodes[$0] }), let country = country(of: show) {
                guard country == wantedCountry else { continue }
                score += 1
            }
            if score > (best?.score ?? 0) { best = (show, score) }
        }
        return best.flatMap { details(of: $0.show) }
    }

    private static func premiered(_ show: [String: Any]) -> Int? {
        (show["premiered"] as? String).flatMap { Int($0.prefix(4)) }
    }

    /// Where the show was made, as its channel's country says: "US", "GB".
    private static func country(of show: [String: Any]) -> String? {
        let channel = (show["network"] as? [String: Any]) ?? (show["webChannel"] as? [String: Any])
        return (channel?["country"] as? [String: Any])?["code"] as? String
    }

    private static func details(of r: [String: Any]) -> (MovieDetails, Int)? {
        guard let id = r["id"] as? Int, let name = r["name"] as? String else { return nil }
        let year = premiered(r)
        var d = MovieDetails(title: name, source: "TVmaze")
        d.showTitle = name
        d.year = year
        d.genres = r["genres"] as? [String] ?? []
        if let average = (r["rating"] as? [String: Any])?["average"] as? Double {
            d.ratings = [MovieDetails.Rating(source: "TVmaze", value: String(format: "%.1f/10", average))]
        }
        d.network = ((r["network"] as? [String: Any]) ?? (r["webChannel"] as? [String: Any]))?["name"] as? String
        d.synopsis = (r["summary"] as? String).map(stripHTML)
        d.posterURL = imageURL(r["image"])
        d.link = (r["url"] as? String).flatMap(URL.init)
        d.runtimeMinutes = (r["averageRuntime"] as? Int) ?? (r["runtime"] as? Int)
        return (d, id)
    }

    static func parseEpisode(_ data: Data, into show: MovieDetails) -> MovieDetails {
        var d = show
        guard let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return d }
        d.season = r["season"] as? Int
        d.episode = r["number"] as? Int
        d.episodeTitle = r["name"] as? String
        d.airDate = r["airdate"] as? String
        d.episodeSynopsis = (r["summary"] as? String).map(stripHTML)
        d.episodeImageURL = imageURL(r["image"])
        if let runtime = r["runtime"] as? Int { d.runtimeMinutes = runtime }
        return d
    }

    private static func imageURL(_ value: Any?) -> URL? {
        guard let image = value as? [String: Any] else { return nil }
        return ((image["original"] as? String) ?? (image["medium"] as? String)).flatMap(URL.init)
    }

    /// TVmaze summaries are HTML paragraphs.
    static func stripHTML(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"</p>\s*<p>"#, with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&hellip;": "…", "&mdash;": "—", "&ndash;": "–"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// OMDb (omdbapi.com): IMDb, Rotten Tomatoes and Metacritic ratings, writers and cast. Needs a
/// free key; the app can ship one in `builtInKey`, and a person can enter their own in Settings.
enum OMDbClient {
    /// Driftcast's own key, shipped with the app. Empty until one is registered.
    static let builtInKey = ""
    static let keyPage = URL(string: "https://www.omdbapi.com/apikey.aspx")!

    static var activeKey: String {
        let own = Prefs.string(Prefs.omdbKey).trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? builtInKey : own
    }

    /// A short fingerprint of a key, to tell keys apart without keeping them twice. "" for none.
    static func fingerprint(_ key: String) -> String {
        key.isEmpty ? "" : String(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    // MARK: What went wrong

    /// The UserDefaults key under which the last thing OMDb said went wrong is kept. It
    /// changes whenever that does, so a view can watch it with @AppStorage and then read `problem`.
    static let problemKey = "omdbProblem"
    private static let problemForKey = "omdbProblemKey"
    private static let problemDateKey = "omdbProblemDate"

    /// What went wrong the last time OMDb was asked with the key now in Settings: "OMDb
    /// didn't accept the key.", "The key's requests for today are used up." Nil when OMDb last
    /// answered, or hasn't been asked with this key. For Settings, under the key.
    static var problem: String? {
        let key = activeKey
        guard !key.isEmpty, let text = Prefs.defaults.string(forKey: problemKey), !text.isEmpty,
              Prefs.defaults.string(forKey: problemForKey) == fingerprint(key) else { return nil }
        return text
    }

    /// When `problem` was last seen.
    static var problemDate: Date? {
        problem == nil ? nil : Prefs.defaults.object(forKey: problemDateKey) as? Date
    }

    static func noteProblem(_ text: String?) {
        let defaults = Prefs.defaults
        guard let text else {
            if defaults.object(forKey: problemKey) != nil {
                defaults.removeObject(forKey: problemKey)
                defaults.removeObject(forKey: problemForKey)
                defaults.removeObject(forKey: problemDateKey)
            }
            return
        }
        defaults.set(fingerprint(activeKey), forKey: problemForKey)
        defaults.set(Date(), forKey: problemDateKey)
        defaults.set(text, forKey: problemKey)
    }

    /// The "Error" of an answer with "Response": "False".
    static func error(in data: Data) -> String? {
        guard let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (r["Response"] as? String) == "False" else { return nil }
        return (r["Error"] as? String) ?? "No reason given."
    }

    /// "Movie not found!", "Series or episode not found!": an answer, not a failure.
    static func isNotFound(_ error: String) -> Bool {
        error.range(of: "not found", options: .caseInsensitive) != nil
    }

    /// What a failed answer means, said plainly.
    static func problem(status: Int, said: String?) -> String {
        guard let said else { return "OMDb answered with error \(status)." }
        if said.range(of: "invalid api key", options: .caseInsensitive) != nil { return "OMDb didn't accept the key." }
        if said.range(of: "limit", options: .caseInsensitive) != nil { return "The key's requests for today are used up." }
        return "OMDb said: \(said)"
    }

    static func url(title: String, year: Int?, type: String?, key: String) -> URL? {
        var items = [URLQueryItem(name: "apikey", value: key), URLQueryItem(name: "t", value: title), URLQueryItem(name: "plot", value: "full")]
        if let year { items.append(URLQueryItem(name: "y", value: "\(year)")) }
        if let type { items.append(URLQueryItem(name: "type", value: type)) }
        var components = URLComponents(string: "https://www.omdbapi.com/")
        components?.queryItems = items
        return components?.url
    }

    static func episodeURL(title: String, season: Int, episode: Int, key: String) -> URL? {
        var components = URLComponents(string: "https://www.omdbapi.com/")
        components?.queryItems = [
            URLQueryItem(name: "apikey", value: key), URLQueryItem(name: "t", value: title),
            URLQueryItem(name: "Season", value: "\(season)"), URLQueryItem(name: "Episode", value: "\(episode)"),
            URLQueryItem(name: "plot", value: "full"),
        ]
        return components?.url
    }

    /// OMDb writes "N/A" for anything it doesn't know.
    private static func clean(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty, s != "N/A" else { return nil }
        return s
    }

    private static func list(_ value: Any?) -> [String] {
        clean(value).map(People.split) ?? []
    }

    /// How OMDb names the countries `MediaTitle.country` reads from file names.
    private static let countryNames = ["US": ["United States", "USA"], "UK": ["United Kingdom", "UK"], "AU": ["Australia"]]

    /// The answer as details, when it is the title wanted. A show's year counts only when the
    /// file gave one ("Doctor Who 2005"), and so does its country ("The Office UK"). With
    /// `exactOnly`, only the very name.
    static func parse(_ data: Data, wanted: MediaTitle, exactOnly: Bool = false) -> MovieDetails? {
        guard let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (r["Response"] as? String) == "True", let title = clean(r["Title"]) else { return nil }
        let year = clean(r["Year"]).flatMap { Int($0.prefix(4)) }
        let score = TitleMatch.score(candidate: title, year: year, wanted: wanted)
        guard score >= (exactOnly ? 3 : 1) else { return nil }
        if let names = wanted.country.flatMap({ countryNames[$0] }), let made = clean(r["Country"]),
           !names.contains(where: { made.contains($0) }) { return nil }
        var d = MovieDetails(title: title, source: "OMDb")
        d.year = year
        d.certificate = clean(r["Rated"]).flatMap { ["Not Rated", "Unrated"].contains($0) ? nil : $0 }
        d.runtimeMinutes = clean(r["Runtime"]).flatMap { Int($0.replacingOccurrences(of: " min", with: "")) }
        d.genres = list(r["Genre"])
        d.directors = list(r["Director"])
        d.writers = list(r["Writer"]).map { $0.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression) }
        d.cast = list(r["Actors"])
        d.synopsis = clean(r["Plot"])
        d.posterURL = clean(r["Poster"]).flatMap(URL.init)
        d.ratings = (r["Ratings"] as? [[String: Any]])?.compactMap { entry in
            guard let source = entry["Source"] as? String, let value = entry["Value"] as? String else { return nil }
            return MovieDetails.Rating(source: source == "Internet Movie Database" ? "IMDb" : source, value: value)
        } ?? []
        if let id = clean(r["imdbID"]) { d.link = URL(string: "https://www.imdb.com/title/\(id)/") }
        if (r["Type"] as? String) == "series" { d.showTitle = title }
        return d
    }

    static func parseEpisode(_ data: Data, into show: MovieDetails) -> MovieDetails {
        var d = show
        guard let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (r["Response"] as? String) == "True" else { return d }
        d.episodeTitle = clean(r["Title"])
        d.episodeSynopsis = clean(r["Plot"])
        d.airDate = clean(r["Released"])
        d.season = clean(r["Season"]).flatMap { Int($0) }
        d.episode = clean(r["Episode"]).flatMap { Int($0) }
        if let rating = clean(r["imdbRating"]) { d.ratings.append(MovieDetails.Rating(source: "IMDb (episode)", value: "\(rating)/10")) }
        if d.posterURL == nil { d.posterURL = clean(r["Poster"]).flatMap(URL.init) }
        return d
    }
}

enum People {
    /// "Michael Mann, Jon Voight" -> ["Michael Mann", "Jon Voight"].
    static func split(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
