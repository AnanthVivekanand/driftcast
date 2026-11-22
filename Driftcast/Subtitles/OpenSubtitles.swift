import Foundation

/// Client for the OpenSubtitles.com REST API (v1). The API key identifies the app, not the
/// person using it, so Driftcast sends its own (`builtInKey`) and nobody is asked for one. Keys
/// come from https://www.opensubtitles.com/consumers.
struct OpenSubtitlesClient {
    /// Driftcast's own API key, shipped with the app. It is not in the repository: the build
    /// writes it to Resources/OpenSubtitles.key from the keychain (Scripts/embed-subtitle-key.sh),
    /// as 32 random bytes and then the key XORed with them. Empty in a build made without it.
    static let builtInKey: String = {
        guard let url = Bundle.main.url(forResource: "OpenSubtitles", withExtension: "key"),
              let data = try? Data(contentsOf: url) else { return "" }
        return unmask(data)
    }()

    /// The key in an OpenSubtitles.key file's contents, or "" when there is none.
    static func unmask(_ data: Data) -> String {
        let bytes = [UInt8](data)
        guard bytes.count > 32 else { return "" }
        let mask = bytes[0..<32]
        let key = bytes[32...].enumerated().map { $0.element ^ mask[$0.offset % 32] }
        return String(decoding: key, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The key searches use: the built-in one. A build made without it (a fresh clone of the
    /// repository) falls back to the `openSubtitlesAPIKey` default, which nothing in the app
    /// sets any more (it was a box in Settings up to 1.1.3); `defaults write` can.
    static var activeKey: String {
        builtInKey.isEmpty ? Prefs.string(Prefs.openSubtitlesKey).trimmingCharacters(in: .whitespacesAndNewlines) : builtInKey
    }
    static var hasKey: Bool { !activeKey.isEmpty }

    struct Result: Identifiable, Hashable, Codable {
        var id: Int { fileID }
        var fileID: Int
        var release: String
        var fileName: String
        var language: String
        var downloads: Int
        var hearingImpaired: Bool
        /// OpenSubtitles knows it was made from this exact file.
        var hashMatch: Bool
        var title: String
        /// Its release name says it was made for the same release as the video (`ReleaseMatch`).
        var releaseMatch = false
        /// For one that isn't a match, how near its name puts it (`ReleaseMatch.closeness`):
        /// 1 from the same kind of source as the video, -1 from another source or cut, 0 unknown.
        var closeness = 0
        /// How many of the words describing the video's release its name shares (`ReleaseMatch.sharedTags`).
        var sharedTags = 0
        /// Only the foreign-language parts (forced subtitles), not the whole film.
        var foreignPartsOnly = false

        /// Made for this file or its release, so it should be in sync.
        var isMatch: Bool { hashMatch || releaseMatch }
        /// Not made for this release, but its name is near the video's (the same kind of
        /// source, or several of the same release words), so it is likely in sync.
        var isClose: Bool { !isMatch && closeness > 0 }
        /// What it was made from, as the uploader named it.
        var name: String { release.isEmpty ? fileName : release }
    }

    enum Failure: LocalizedError {
        case noKey
        case http(Int, String)
        case badResponse
        /// The day's downloads are used up; more from the given time, if OpenSubtitles said.
        case noDownloadsLeft(Date?)

        var errorDescription: String? {
            switch self {
            case .noKey: return "Searching OpenSubtitles isn't set up in this copy of Driftcast."
            case .http(let code, let msg): return "OpenSubtitles returned \(code)\(msg.isEmpty ? "" : ": \(msg)")"
            case .badResponse: return "OpenSubtitles sent a response Driftcast couldn't read."
            case .noDownloadsLeft(let date):
                guard let date else { return "No OpenSubtitles downloads are left today." }
                let time = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
                return "No OpenSubtitles downloads are left today. More from \(time)."
            }
        }

        /// OpenSubtitles answers 401 or 403 when it turns the app's key down.
        var isKeyRefused: Bool {
            switch self {
            case .noKey: return true
            case .http(let code, _): return code == 401 || code == 403
            case .badResponse, .noDownloadsLeft: return false
            }
        }
    }

    /// The day's download allowance as the last download reported it.
    struct Quota: Sendable {
        var remaining: Int
        /// When the count starts again, if OpenSubtitles said.
        var resetsAt: Date?
    }

    private static let quotaLock = NSLock()
    nonisolated(unsafe) private static var lastQuota: Quota?

    /// Downloads left today, from the last download in this run; nil when none has been made yet or
    /// the count has started again since.
    static var quota: Quota? {
        quotaLock.lock()
        defer { quotaLock.unlock() }
        if let reset = lastQuota?.resetsAt, reset <= Date() { return nil }
        return lastQuota
    }

    private static func noteQuota(_ json: [String: Any]?) {
        guard let json, let remaining = json["remaining"] as? Int else { return }
        let reset = (json["reset_time_utc"] as? String).flatMap(parseDate)
        quotaLock.lock()
        lastQuota = Quota(remaining: remaining, resetsAt: reset)
        quotaLock.unlock()
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    var apiKey: String
    private let base = URL(string: "https://api.opensubtitles.com/api/v1")!

    static func fromSettings() throws -> OpenSubtitlesClient {
        let key = activeKey
        guard !key.isEmpty else { throw Failure.noKey }
        return OpenSubtitlesClient(apiKey: key)
    }

    private func makeRequest(_ url: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        r.setValue("Driftcast v\(AppVersion.installed)", forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func perform(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        Self.noteQuota(json)
        // 406 from /download: the day's allowance is used up.
        if code == 406, json?["remaining"] != nil {
            throw Failure.noDownloadsLeft((json?["reset_time_utc"] as? String).flatMap(Self.parseDate))
        }
        guard (200..<300).contains(code) else {
            throw Failure.http(code, (json?["message"] as? String) ?? (json?["errors"] as? [String])?.first ?? "")
        }
        guard let json else { throw Failure.badResponse }
        return json
    }

    /// Searches by file hash (exact release match) and by title, narrowed to one episode of a
    /// show when the season and episode are known. The API wants parameters sorted and
    /// lower-cased or it answers with a redirect.
    /// With `videoName` (the file's name without extension), subtitles made for the same release
    /// are marked and listed first, after any made from this exact file.
    func search(query: String, languages: String, movieHash: String?, season: Int? = nil, episode: Int? = nil,
                videoName: String? = nil) async throws -> [Result] {
        var items: [URLQueryItem] = []
        let codes = Self.apiLanguages(languages)
        if !codes.isEmpty { items.append(URLQueryItem(name: "languages", value: codes)) }
        if let movieHash { items.append(URLQueryItem(name: "moviehash", value: movieHash)) }
        if !query.isEmpty { items.append(URLQueryItem(name: "query", value: query.lowercased())) }
        if let season { items.append(URLQueryItem(name: "season_number", value: String(season))) }
        if let episode { items.append(URLQueryItem(name: "episode_number", value: String(episode))) }
        items.sort { $0.name < $1.name }
        var comps = URLComponents(url: base.appendingPathComponent("subtitles"), resolvingAgainstBaseURL: false)!
        comps.queryItems = items
        // The API redirects %20 to +, so go straight there.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "%20", with: "+")
        let json = try await perform(makeRequest(comps.url!))
        let data = json["data"] as? [[String: Any]] ?? []
        return data.compactMap { entry in
            guard let attrs = entry["attributes"] as? [String: Any],
                  let file = (attrs["files"] as? [[String: Any]])?.first,
                  let fileID = file["file_id"] as? Int else { return nil }
            let feature = attrs["feature_details"] as? [String: Any] ?? [:]
            var title = feature["title"] as? String ?? feature["movie_name"] as? String ?? ""
            if let year = feature["year"] as? Int { title += " (\(year))" }
            var result = Result(fileID: fileID,
                                release: attrs["release"] as? String ?? "",
                                fileName: file["file_name"] as? String ?? "",
                                language: attrs["language"] as? String ?? "",
                                downloads: attrs["download_count"] as? Int ?? 0,
                                hearingImpaired: attrs["hearing_impaired"] as? Bool ?? false,
                                hashMatch: attrs["moviehash_match"] as? Bool ?? false,
                                title: title)
            result.foreignPartsOnly = attrs["foreign_parts_only"] as? Bool ?? false
            if let videoName {
                let names = [result.release, result.fileName].filter { !$0.isEmpty }
                result.releaseMatch = names.contains { ReleaseMatch.isSameRelease($0, as: videoName) }
                let near = names.map { ReleaseMatch.closeness($0, to: videoName) }
                result.closeness = near.contains(1) ? 1 : near.contains(-1) ? -1 : 0
                result.sharedTags = names.map { ReleaseMatch.sharedTags($0, with: videoName) }.max() ?? 0
            }
            return result
        }
        .sorted { Self.order($0) > Self.order($1) }
    }

    /// What results are sorted by, highest first: the group (`rank`), then within a group how
    /// many of the video's release words the name shares, and only then how often it was
    /// downloaded. By downloads alone a popular subtitle for another copy sat above a near one
    /// (the user's report, 2026-11-21).
    static func order(_ r: Result) -> (Int, Int, Int) { (rank(r), r.sharedTags, r.downloads) }

    /// Exact file first, then the same release, then ones with a name near the video's, then
    /// those whose names don't say, then ones from another source or cut. Forced-only subtitles
    /// come after all of them, so the automatic pick, which takes the first, gets a whole film's
    /// subtitles when there are any.
    static func rank(_ r: Result) -> Int {
        r.foreignPartsOnly ? -1 : r.hashMatch ? 5 : r.releaseMatch ? 4 : r.closeness + 2
    }

    /// The line under the search results: how many, and how to use one.
    static func summary(of found: [Result]) -> String {
        let matches = found.filter(\.isMatch).count
        let count = matches > 0 ? "\(found.count) found, \(matches) made for this video." : "\(found.count) found."
        return "\(count) Double-click one, or select it and click Use."
    }

    /// The warning above the results when none was made for this video: that there is none
    /// for the file's name, and whether the ones listed first are at least near it. Without
    /// it a list of other copies' subtitles looked like matches (the user's request, 2026-11-21).
    static func notice(of found: [Result]) -> String? {
        guard !found.isEmpty, !found.contains(where: \.isMatch) else { return nil }
        let close = found.filter { $0.isClose && !$0.foreignPartsOnly }.count
        switch close {
        case 0: return "No subtitles found for this file name, and none of these are close to it. They may be out of sync."
        case 1: return "No subtitles found for this exact file name. The first one is close to it."
        default: return "No subtitles found for this exact file name. The first \(close) are close to it."
        }
    }

    /// The `languages` value OpenSubtitles knows: it lists Portuguese and Chinese only by region and
    /// Norwegian only as "no", so "pt" asks for both Portuguese kinds and a Mac's "nb" asks for "no".
    /// Sorted and lower-cased, as the API wants.
    static func apiLanguages(_ languages: String) -> String {
        let expanded = languages.lowercased().split(separator: ",").flatMap { code -> [String] in
            switch code.trimmingCharacters(in: .whitespaces) {
            case "pt": return ["pt-br", "pt-pt"]
            case "zh": return ["zh-cn", "zh-tw"]
            case "nb", "nn": return ["no"]
            case let other: return other.isEmpty ? [] : [other]
            }
        }
        return Array(Set(expanded)).sorted().joined(separator: ",")
    }

    /// The file a result is saved as: "Title.lang.id.srt", with ".forced" before the id for a
    /// forced-only one so it is treated as forced. The language comes from the server and is reduced
    /// to letters, digits and "-", so it can't point the file anywhere else.
    static func fileName(for result: Result, video: URL) -> String {
        let language = String(result.language.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" }.map(Character.init))
        let parts = [video.deletingPathExtension().lastPathComponent, language.isEmpty ? "und" : language]
            + (result.foreignPartsOnly ? ["forced"] : []) + ["\(result.fileID)", "srt"]
        return parts.joined(separator: ".")
    }

    static var downloadsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Driftcast/Subtitles", isDirectory: true)
    }

    /// Which OpenSubtitles result a file in the downloads folder is: the number before its
    /// extension ("Movie.en.4242.srt", see `fileName`). Nil for any other file.
    static func fileID(ofDownloaded file: URL) -> Int? {
        guard file.deletingLastPathComponent().standardizedFileURL.path == downloadsFolder.standardizedFileURL.path else { return nil }
        let parts = file.lastPathComponent.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        return Int(parts[parts.count - 2])
    }

    /// Downloads a subtitle as SRT into Application Support and returns the file. One already there
    /// is used as it is: asking again would spend another of the day's few downloads on the same file.
    func download(_ result: Result, for video: URL) async throws -> URL {
        let dir = Self.downloadsFolder
        let file = dir.appendingPathComponent(Self.fileName(for: result, video: video))
        if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 0 {
            return file
        }
        let body = try JSONSerialization.data(withJSONObject: ["file_id": result.fileID, "sub_format": "srt"])
        let json = try await perform(makeRequest(base.appendingPathComponent("download"), method: "POST", body: body))
        guard let link = (json["link"] as? String).flatMap(URL.init(string:)) else { throw Failure.badResponse }
        let (data, response) = try await URLSession.shared.data(from: link)
        // An error page or an empty answer saved as the subtitle would stay attached to the video for good.
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code), !data.isEmpty else {
            throw Failure.http(code, "the subtitle file couldn't be downloaded")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return file
    }

    /// OpenSubtitles hash: file size plus the 64-bit little-endian word sums of the first and
    /// last 64 KiB, wrapping on overflow.
    static func movieHash(for url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd(), size >= 65536 else { return nil }
        var hash = size
        func sum(at offset: UInt64) -> Bool {
            guard (try? fh.seek(toOffset: offset)) != nil, let data = try? fh.read(upToCount: 65536), data.count == 65536 else { return false }
            data.withUnsafeBytes { raw in
                for i in 0..<8192 { hash &+= UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)) }
            }
            return true
        }
        guard sum(at: 0), sum(at: size - 65536) else { return nil }
        return String(format: "%016llx", hash)
    }
}
