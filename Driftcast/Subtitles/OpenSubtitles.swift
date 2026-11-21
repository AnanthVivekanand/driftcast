import Foundation

/// Client for the OpenSubtitles.com REST API (v1). The API key identifies the app, not the
/// person using it: put Driftcast's own key in `builtInKey` and nobody has to enter one. A key
/// typed into Settings takes precedence. Keys come from https://www.opensubtitles.com/consumers.
struct OpenSubtitlesClient {
    /// Driftcast's own API key, shipped with the app. Empty until one is registered.
    static let builtInKey = ""
    static let keyPage = URL(string: "https://www.opensubtitles.com/consumers")!

    /// The key searches will use: the one from Settings, else the built-in one.
    static var activeKey: String {
        let own = Prefs.string(Prefs.openSubtitlesKey).trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? builtInKey : own
    }
    static var hasKey: Bool { !activeKey.isEmpty }

    struct Result: Identifiable, Hashable {
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
        /// Only the foreign-language parts (forced subtitles), not the whole film.
        var foreignPartsOnly = false

        /// Made for this file or its release, so it should be in sync.
        var isMatch: Bool { hashMatch || releaseMatch }
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
            case .noKey: return "Searching online needs a free OpenSubtitles API key."
            case .http(let code, let msg): return "OpenSubtitles returned \(code)\(msg.isEmpty ? "" : ": \(msg)")"
            case .badResponse: return "OpenSubtitles sent a response Driftcast couldn't read."
            case .noDownloadsLeft(let date):
                guard let date else { return "No OpenSubtitles downloads are left today." }
                let time = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
                return "No OpenSubtitles downloads are left today. More from \(time)."
            }
        }

        /// OpenSubtitles answers 401 or 403 when the key itself is wrong.
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
                result.releaseMatch = [result.release, result.fileName].contains {
                    !$0.isEmpty && ReleaseMatch.isSameRelease($0, as: videoName)
                }
            }
            return result
        }
        .sorted { (Self.rank($0), $0.downloads) > (Self.rank($1), $1.downloads) }
    }

    /// Exact file first, then the same release, then the rest; forced-only subtitles after all of
    /// them, so the automatic pick, which takes the first, gets a whole film's subtitles when there are any.
    static func rank(_ r: Result) -> Int { r.foreignPartsOnly ? -1 : r.hashMatch ? 2 : r.releaseMatch ? 1 : 0 }

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

    /// Downloads a subtitle as SRT into Application Support and returns the file. One already there
    /// is used as it is: asking again would spend another of the day's few downloads on the same file.
    func download(_ result: Result, for video: URL) async throws -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Driftcast/Subtitles", isDirectory: true)
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
