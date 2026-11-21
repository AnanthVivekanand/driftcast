import Foundation

/// Where new versions of Driftcast are published.
enum UpdateConfig {
    /// The GitHub repository whose releases are the app's updates, as "owner/name".
    /// With no repository the app never checks and shows no update controls.
    static let repository = "leechsoftware/driftcast"

    /// How often a running copy looks again, after the check at launch.
    static let checkInterval: TimeInterval = 8 * 3_600

    /// The repository if it is a plausible "owner/name", otherwise nil.
    static var repositoryPath: String? { validated(repository) }
    static var isConfigured: Bool { repositoryPath != nil }

    static func validated(_ repository: String) -> String? {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts.count == 2, parts.allSatisfy({ part in
            !part.isEmpty && part.unicodeScalars.allSatisfy(allowed.contains)
        }) else { return nil }
        return repository
    }
}

/// A published version: what the update dialog offers.
struct AppRelease: Equatable, Sendable {
    var version: String
    /// The release's page on GitHub.
    var page: URL
    /// The app's zip or disk image attached to the release, when there is one.
    var download: URL?
    /// What the release says is new, as written on GitHub (Markdown). Shown as plain text
    /// through `ReleaseNotes`, never as a web page.
    var notes: String? = nil
}

enum AppVersion {
    static var installed: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// "v1.2.0" -> [1, 2, 0]. Anything after the leading digits and dots ("-beta") is ignored.
    static func components(_ text: String) -> [Int] {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        if let first = s.first, first == "v" || first == "V" { s = s.dropFirst() }
        let numeric = s.prefix { $0.isNumber || $0 == "." }
        return numeric.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// The tag's version as shown to people: "v1.2" -> "1.2".
    static func display(_ tag: String) -> String {
        let t = tag.trimmingCharacters(in: .whitespaces)
        if let first = t.first, first == "v" || first == "V", t.dropFirst().first?.isNumber == true {
            return String(t.dropFirst())
        }
        return t
    }

    /// Compares number by number, so 1.10 is newer than 1.9 and 1.2 equals 1.2.0.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let a = components(candidate), b = components(installed)
        guard !a.isEmpty else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// The newest release of a GitHub repository, from GitHub's public API. No account or key is
/// needed; the limit is 60 requests an hour per network address, and the app asks once at
/// launch and then every eight hours.
enum GitHubReleases {
    enum Outcome: Equatable {
        case release(AppRelease)
        /// The repository has published no release yet.
        case none
        /// No connection, a rate limit, or an answer that couldn't be read.
        case failed
    }

    static func latestURL(repository: String) -> URL? {
        guard let path = UpdateConfig.validated(repository) else { return nil }
        return URL(string: "https://api.github.com/repos/\(path)/releases/latest")
    }

    static func latest(repository: String) async -> Outcome {
        guard let url = latestURL(repository: repository) else { return .failed }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Driftcast/\(AppVersion.installed)", forHTTPHeaderField: "User-Agent")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 20
        do {
            let (data, response) = try await URLSession(configuration: config).data(for: request)
            return parse(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return .failed
        }
    }

    /// The reading half of `latest`, separate so it can be tested against canned answers.
    static func parse(data: Data, status: Int) -> Outcome {
        if status == 404 { return .none }
        guard (200...299).contains(status),
              let decoded = try? JSONDecoder().decode(Release.self, from: data),
              decoded.draft != true, decoded.prerelease != true,
              let tag = decoded.tag_name, !AppVersion.components(tag).isEmpty,
              let page = secureURL(decoded.html_url) else { return .failed }
        let assets = decoded.assets ?? []
        let file = assets.first { $0.name?.lowercased().hasSuffix(".zip") == true }
            ?? assets.first { $0.name?.lowercased().hasSuffix(".dmg") == true }
        let notes = decoded.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .release(AppRelease(version: AppVersion.display(tag), page: page,
                                   download: secureURL(file?.browser_download_url),
                                   notes: notes?.isEmpty == false ? notes : nil))
    }

    /// Only https links to GitHub are opened on the user's behalf.
    private static func secureURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme == "https",
              let host = url.host?.lowercased(), host == "github.com" || host.hasSuffix(".github.com") else { return nil }
        return url
    }

    private struct Release: Decodable {
        var tag_name: String?
        var html_url: String?
        var draft: Bool?
        var prerelease: Bool?
        var body: String?
        var assets: [Asset]?

        struct Asset: Decodable {
            var name: String?
            var browser_download_url: String?
        }
    }
}

/// A release's notes made into plain lines for the update dialog. GitHub's notes are Markdown,
/// and Driftcast's are headings and bullets ("### Fixed", "- **Rename a video:** ..."). They
/// are only ever shown as text: links keep their words and lose their address, pictures and
/// HTML are dropped, so nothing in them is opened, loaded or run.
enum ReleaseNotes {
    struct Line: Equatable, Hashable {
        enum Kind: Equatable, Hashable { case heading, bullet, text }
        var kind: Kind
        var text: String
    }

    /// Enough for any one version's notes; a longer text is cut, and the release page has it all.
    static let maximumLines = 60

    static func lines(_ markdown: String) -> [Line] {
        // Bounded before any pattern runs over it, so an enormous text costs nothing.
        var text = String(markdown.prefix(20_000)).replacingOccurrences(of: "\r\n", with: "\n")
        text = replace(#"<!--.*?(-->|$)"#, in: text, with: "", options: [.dotMatchesLineSeparators])
        var lines: [Line] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            // Rules ("---") and code fences carry nothing to read.
            if line.allSatisfy({ "-*_=".contains($0) }) || line.hasPrefix("```") || line.hasPrefix("~~~") { continue }
            var kind = Line.Kind.text
            while line.hasPrefix(">") { line = line.dropFirst().trimmingCharacters(in: .whitespaces) }
            if let heading = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                kind = .heading
                line = String(line[heading.upperBound...]).replacingOccurrences(of: #"\s+#+$"#, with: "", options: .regularExpression)
            } else if let bullet = line.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
                kind = .bullet
                line = String(line[bullet.upperBound...])
            }
            line = inline(line)
            guard !line.isEmpty else { continue }
            lines.append(Line(kind: kind, text: String(line.prefix(600))))
            if lines.count == maximumLines { break }
        }
        return lines
    }

    /// Emphasis, code marks, links, pictures and tags reduced to the words a person reads.
    private static func inline(_ text: String) -> String {
        var s = text
        s = replace(#"!\[[^\]]*\]\([^)]*\)"#, in: s, with: "")                 // pictures
        s = replace(#"\[([^\]]+)\]\([^)]*\)"#, in: s, with: "$1")              // [words](address)
        s = replace(#"<(https?://[^>\s]+)>"#, in: s, with: "$1")               // <address>
        s = replace(#"<[A-Za-z/!][^>]*>"#, in: s, with: "")                    // HTML tags
        for mark in ["**", "__", "~~", "`"] { s = s.replacingOccurrences(of: mark, with: "") }
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: character)
        }
        s = replace(#"\s{2,}"#, in: s, with: " ")
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func replace(_ pattern: String, in text: String, with template: String,
                                options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
