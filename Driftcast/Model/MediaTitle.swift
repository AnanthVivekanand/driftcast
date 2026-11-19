import Foundation

/// What a file name says about the film or episode in it: "Heat.1995.1080p.BluRay.x264" is
/// Heat from 1995, "Sopranos.S1.E11.dolby" is Sopranos, season 1, episode 11. Used to search
/// film databases and OpenSubtitles, and to show a file by name rather than as a release name.
struct MediaTitle: Equatable, Hashable, Sendable, Codable {
    var title: String
    var year: Int?
    var season: Int?
    var episode: Int?

    var isEpisode: Bool { episode != nil }

    /// The words to search a database with ("Heat 1995", "Sopranos").
    var searchQuery: String { year.map { "\(title) \($0)" } ?? title }

    /// "Season 1, Episode 11" / "Episode 11".
    var episodeLabel: String? {
        guard let episode else { return nil }
        if let season { return "Season \(season), Episode \(episode)" }
        return "Episode \(episode)"
    }

    /// "S4 E7" / "E12": the episode's number for a title line.
    var episodeTag: String? {
        guard let episode else { return nil }
        return season.map { "S\($0) E\(episode)" } ?? "E\(episode)"
    }

    /// What follows the name on a title line, kept whole when the name is shortened: the
    /// episode's number, else the film's year in brackets.
    var titleTag: String? { episodeTag ?? year.map { "(\($0))" } }

    /// The file as people read it: "The Sopranos S4 E7", "Heat (1995)". The release name's
    /// dots, quality, encoding, group and extension are left out.
    var displayName: String { titleTag.map { "\(title) \($0)" } ?? title }

    /// The two lines on the TV's own pause and seek panel, each short enough not to wrap. An
    /// episode is the show's name over "Season 4, Episode 7". A film is its name alone, without
    /// the year once it has been found online (the poster card showed it); an unknown film
    /// keeps the year, the only hint of which one it is.
    func tvLines(lookedUp: Bool) -> (title: String, subtitle: String?) {
        if isEpisode { return (title, episodeLabel) }
        return (lookedUp ? title : displayName, nil)
    }

    private static let episodeMarkers: [NSRegularExpression] = [
        #"\bS(\d{1,2})\s*[-x]?\s*E(\d{1,3})\b"#,
        #"\b(\d{1,2})x(\d{2,3})\b"#,
        #"\bSeason\s*(\d{1,2})\b.*?\b(?:Episode|Ep|E)\s*(\d{1,3})\b"#,
        #"\b(?:Episode|Ep)\s*#?(\d{1,4})\b"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static let yearPattern = try! NSRegularExpression(pattern: #"\b(19[2-9]\d|20\d\d)\b"#)

    /// Words that end a film's title in release names. Compared as whole words.
    static let releaseTags: Set<String> = [
        "2160p", "1080p", "1080i", "720p", "576p", "480p", "4k", "uhd", "bluray", "blu-ray", "bdrip", "brrip",
        "bdremux", "remux", "web-dl", "webdl", "webrip", "hdtv", "hdrip", "dvdrip", "dvdscr", "x264", "x265",
        "h264", "h265", "h.264", "h.265", "hevc", "avc", "av1", "xvid", "divx", "hdr", "hdr10", "hdr10+", "dolby",
        "atmos", "aac", "aac2", "ac3", "dd5", "ddp", "ddp5", "dts", "dts-hd", "truehd", "eac3", "flac", "multi",
        "proper", "repack", "internal", "limited", "extended", "unrated", "remastered", "amzn", "nf", "hmax",
        "dsnp", "atvp", "10bit", "8bit", "hybrid", "criterion", "sdr", "dv",
    ]

    static func parse(fileName: String) -> MediaTitle {
        let name = wordsFromSlug(withoutTrailingTags(fileName))
        let s = SeriesName.normalize(name)
        let whole = NSRange(s.startIndex..., in: s)

        for marker in episodeMarkers {
            guard let m = marker.firstMatch(in: s, range: whole), m.range.location > 0,
                  let range = Range(m.range, in: s) else { continue }
            func number(_ i: Int) -> Int? { Range(m.range(at: i), in: s).flatMap { Int(s[$0]) } }
            let season = m.numberOfRanges == 3 ? number(1) : nil
            let episode = m.numberOfRanges == 3 ? number(2) : number(1)
            let head = String(s[..<range.lowerBound])
            let title = tidy(cutAtReleaseTag(head)) ?? tidy(head) ?? head
            return MediaTitle(title: title, year: nil, season: season, episode: episode)
        }

        // A film: the title ends at its year.
        if let (year, range) = filmYear(in: s) {
            let head = String(s[..<range.lowerBound])
            if let title = tidy(cutAtReleaseTag(head)) ?? tidy(head) {
                return MediaTitle(title: title, year: year)
            }
        }
        // Anything else (a film with no year, a home video, a screen recording, a download):
        // the name made readable, up to the first release tag.
        let plain = readable(name)
        return MediaTitle(title: tidy(cutAtReleaseTag(plain)) ?? tidy(plain) ?? plain)
    }

    /// The year a film came out, as release names write it: "(1995)", or a bare 1995 that ends
    /// the name or comes before release tags ("Heat 1995 1080p"). A year at the very start
    /// ("2001 A Space Odyssey 1968"), one in a date ("2023-05-12", "Birthday 2023 at Grandma's")
    /// or one still to come ("Blade Runner 2049") is part of the name.
    private static func filmYear(in s: String) -> (Int, Range<String.Index>)? {
        let latest = Calendar(identifier: .gregorian).component(.year, from: Date()) + 1
        for m in yearPattern.matches(in: s, range: NSRange(s.startIndex..., in: s)) where m.range.location > 0 {
            guard let range = Range(m.range, in: s), let year = Int(s[range]), year <= latest else { continue }
            let before = String(s[..<range.lowerBound]), after = String(s[range.upperBound...])
            let isDate = after.range(of: #"^[-\s]\d{1,2}[-\s]\d{1,2}\b"#, options: .regularExpression) != nil
                || before.range(of: #"\b\d{1,2}[-\s]\d{1,2}[-\s]$"#, options: .regularExpression) != nil
            if isDate { continue }
            if before.last == "(" || before.last == "[" { return (year, range) }
            let rest = after.trimmingCharacters(in: CharacterSet(charactersIn: " )]"))
            let onlyGroup = rest.hasPrefix("-") && !rest.contains(" ")   // "Heat 1995-GRP"
            if rest.isEmpty || onlyGroup || rest.split(separator: " ").contains(where: isReleaseTag) {
                return (year, range)
            }
        }
        return nil
    }

    /// Square-bracketed tags at the end of a name say nothing about the video: a download's
    /// video id ("[dQw4w9WgXcQ]"), a release site ("[YTS.MX]"), a quality ("[1080p]").
    private static func withoutTrailingTags(_ name: String) -> String {
        var s = name
        while let r = s.range(of: #"\s*\[[^\[\]]*\]\s*$"#, options: .regularExpression) {
            let inside = SeriesName.normalize(String(s[r]).trimmingCharacters(in: CharacterSet(charactersIn: " []")))
            let marksEpisode = episodeMarkers.contains { $0.firstMatch(in: inside, range: NSRange(inside.startIndex..., in: inside)) != nil }
            guard s[..<r.lowerBound].contains(where: \.isLetter), !marksEpisode else { break }
            s.removeSubrange(r)
        }
        return s
    }

    /// "my-summer-vacation-2023" -> "my summer vacation 2023": a name written with hyphens for
    /// spaces. Hyphens between numbers (a date) stay; a single hyphen ("Spider-Man") is left alone.
    private static func wordsFromSlug(_ name: String) -> String {
        guard !name.contains(where: { $0 == " " || $0 == "." || $0 == "_" }),
              name.filter({ $0 == "-" }).count >= 2 else { return name }
        return name.replacingOccurrences(of: #"(?<=[A-Za-z])-|-(?=[A-Za-z])"#, with: " ", options: .regularExpression)
    }

    /// The dots of a time or date ("at 10.30.15", "12.05.2023", "2024.01.02").
    private static let numberDots = try! NSRegularExpression(pattern: #"\b(?:\d{4}\.\d{1,2}\.\d{1,2}|\d{1,2}(?:\.\d{1,2})?\.\d{2,4})\b"#)

    /// A name that isn't a release name, made readable like one: underscores and dots become
    /// spaces, except the dots of a time or date.
    private static func readable(_ name: String) -> String {
        let keep: Character = "\u{2024}"   // stands in for a kept dot while the others go
        var s = name
        for m in numberDots.matches(in: name, range: NSRange(name.startIndex..., in: name)).reversed() {
            guard let r = Range(m.range, in: s) else { continue }
            s.replaceSubrange(r, with: s[r].replacingOccurrences(of: ".", with: String(keep)))
        }
        return SeriesName.normalize(s).replacingOccurrences(of: String(keep), with: ".")
    }

    /// The words before the first release tag ("Heat 1080p BluRay" -> "Heat").
    static func cutAtReleaseTag(_ text: String) -> String {
        var kept: [Substring] = []
        for word in text.split(separator: " ") {
            if isReleaseTag(word), !kept.isEmpty { break }
            kept.append(word)
        }
        return kept.joined(separator: " ")
    }

    /// A word of a release name that isn't the title: "1080p", "BluRay", a tag joined to the
    /// release group by a hyphen ("x265-RARBG"), a frame rate ("60fps"), a picture size ("1920x1080").
    static func isReleaseTag(_ word: Substring) -> Bool {
        let bare = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[](){}-"))
        let beforeGroup = bare.split(separator: "-").first.map(String.init) ?? bare
        if releaseTags.contains(bare) || releaseTags.contains(beforeGroup) { return true }
        return beforeGroup.range(of: #"^(\d{2,3}fps|\d{3,4}x\d{3,4})$"#, options: .regularExpression) != nil
    }

    private static func tidy(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: CharacterSet(charactersIn: " -–:,([{#"))
        t = t.split(separator: " ").joined(separator: " ")
        guard t.contains(where: \.isLetter) || t.contains(where: \.isNumber) else { return nil }
        return t == t.lowercased() ? t.capitalized : t
    }
}
