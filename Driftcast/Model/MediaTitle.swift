import Foundation

/// What a file name says about the film or episode in it: "Heat.1995.1080p.BluRay.x264" is
/// Heat from 1995, "Sopranos.S1.E11.dolby" is Sopranos, season 1, episode 11. Used to search
/// film databases and OpenSubtitles, and to show a file by name rather than as a release name.
struct MediaTitle: Equatable, Hashable, Sendable, Codable {
    var title: String
    var year: Int?
    var season: Int?
    var episode: Int?
    /// The country an episode's show is named with, the way release names tell apart two shows
    /// of one name ("The.Office.US.S01E01"): "US", "UK" or "AU". Used to pick the show online.
    var country: String?
    /// An episode's show as the file name writes it, when a year or a country was taken off the
    /// end of it ("Doctor Who 2005", "The Office US"). That is the name shown; `title`, `year`
    /// and `country` are what is looked up.
    var writtenTitle: String?

    var isEpisode: Bool { episode != nil }

    /// The film or show as it is shown: "Doctor Who 2005", where the lookup asks for "Doctor Who".
    var shownTitle: String { writtenTitle ?? title }

    /// The words to search a database with ("Heat 1995", "Sopranos", "Doctor Who 2005").
    var searchQuery: String { writtenTitle ?? year.map { "\(title) \($0)" } ?? title }

    /// The same episode with its show's name as the file writes it, nothing taken out of it.
    /// A second try online, for a show whose name does end in a year: "Space 1999".
    var asWritten: MediaTitle? {
        guard let writtenTitle else { return nil }
        return MediaTitle(title: writtenTitle, season: season, episode: episode)
    }

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
    var displayName: String { titleTag.map { "\(shownTitle) \($0)" } ?? shownTitle }

    /// The two lines on the TV's own pause and seek panel, each short enough not to wrap. An
    /// episode is the show's name over "Season 4, Episode 7". A film is its name alone, without
    /// the year once it has been found online (the poster card showed it); an unknown film
    /// keeps the year, the only hint of which one it is.
    func tvLines(lookedUp: Bool) -> (title: String, subtitle: String?) {
        if isEpisode { return (shownTitle, episodeLabel) }
        return (lookedUp ? title : displayName, nil)
    }

    private static let episodeMarkers: [NSRegularExpression] = [
        #"\bS(\d{1,2})\s*[-x]?\s*E(\d{1,3})\b"#,
        #"\b(\d{1,2})x(\d{2,3})\b"#,
        #"\bSeason\s*(\d{1,2})\b.*?\b(?:Episode|Ep|E)\s*(\d{1,3})\b"#,
        #"\b(?:Episode|Ep)\s*#?(\d{1,4})\b"#,
        // "Show E03", and the "Show - 03" of fan releases, which `SeriesName` already groups.
        // Two or three digits, so "Concert - 2019" and "Rocky - 2" are left alone, and only at
        // the end of the name or before a bracket, a version or a picture size, so "Party - 12
        // 05 2023" (a date) is too.
        #"\bE(\d{2,3})\b"#,
        #"\s[-–]\s*(\d{2,3})(?=$|\s*[\[\(]|v\d|\s+[-–]\s|\s+\d{3,4}[pi]\b)"#,
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
        // A camera's counter can look like a year ("IMG_2019" is not a film from 2019), and
        // nothing else in such a name says what the video is.
        var found = isDeviceRecording(fileName: fileName) ? plainTitle(fileName) : read(fileName)
        // Cleaning can leave nothing to show; then the name is shown as the file has it.
        if !found.title.contains(where: { $0.isLetter || $0.isNumber }) {
            found = MediaTitle(title: fileName.trimmingCharacters(in: .whitespaces))
        }
        return found
    }

    /// Names that cameras, phones, drones and the screen recorder give their files: IMG_1234,
    /// IMG_E1234, DSC_0042, DSCF0042, MVI_0001, DJI_0001, PXL_20240102_103015123,
    /// VID_20240102_103015, GOPR0001, GH010001, "Screen Recording 2024-01-02 at 10.30.15".
    private static let deviceName = try! NSRegularExpression(
        pattern: #"^(?:(?:IMG|VID|MVI|MOV|DSC[FN]?|DJI|PXL|GOPR|G[HX]\d\d)[_-]?[A-Z]?\d{3,}|(?:Simulator )?Screen Recording\b)"#,
        options: [.caseInsensitive])

    /// Whether a file name is one a camera, a phone or the screen recorder made up, rather
    /// than the name of a film or a show.
    static func isDeviceRecording(fileName: String) -> Bool {
        deviceName.firstMatch(in: fileName, range: NSRange(fileName.startIndex..., in: fileName)) != nil
    }

    /// The name made readable, read for nothing more than words.
    private static func plainTitle(_ fileName: String) -> MediaTitle {
        let plain = readable(wordsFromSlug(withoutTrailingTags(fileName)))
        return MediaTitle(title: tidy(cutAtReleaseTag(plain)) ?? tidy(plain) ?? plain)
    }

    private static func read(_ fileName: String) -> MediaTitle {
        let name = wordsFromSlug(withoutTrailingTags(fileName))
        let s = SeriesName.normalize(name)
        let whole = NSRange(s.startIndex..., in: s)

        for marker in episodeMarkers {
            guard let m = marker.firstMatch(in: s, range: whole), m.range.location > 0,
                  let range = Range(m.range, in: s) else { continue }
            // "Star Wars Episode 4 A New Hope 1977" is a film: "Episode 4" with no season, then
            // more of the name, then the year it came out.
            if m.numberOfRanges == 2, let (_, year) = filmYear(in: s), year.lowerBound >= range.upperBound,
               let next = s[range.upperBound..<year.lowerBound].split(separator: " ").first,
               next.contains(where: \.isLetter), !isReleaseTag(next) { continue }
            func number(_ i: Int) -> Int? { Range(m.range(at: i), in: s).flatMap { Int(s[$0]) } }
            let season = m.numberOfRanges == 3 ? number(1) : nil
            let episode = m.numberOfRanges == 3 ? number(2) : number(1)
            let head = String(s[..<range.lowerBound])
            let title = tidy(cutAtReleaseTag(head)) ?? tidy(head) ?? head
            var found = MediaTitle(title: title, year: nil, season: season, episode: episode)
            found.separateQualifiers()
            return found
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

    /// The countries release names put after a show's name, as they write them.
    private static let countries: Set<String> = ["US", "UK", "AU"]

    /// "Doctor Who 2005", "The Office US": the year or the country that release names put after
    /// a show's name to tell it from another show of that name. They are taken off `title` into
    /// `year` and `country`, so that the lookup asks for the "Doctor Who" first shown in 2005.
    /// Asked for a show called "Doctor Who 2005", the services gave whichever "Doctor Who" came
    /// first, the one from 1963 as likely as not. The name stays as written for showing
    /// (`writtenTitle`).
    ///
    /// A name that is nothing but a year keeps it ("1923"). A country counts when it is written
    /// in capitals in a name that isn't ("This Is Us" is a show of its own), or in brackets.
    private mutating func separateQualifiers() {
        var words = title.split(separator: " ").map(String.init)
        let latest = Calendar(identifier: .gregorian).component(.year, from: Date()) + 1
        var foundYear: Int?, foundCountry: String?
        while words.count > 1, let last = words.last {
            let bare = last.trimmingCharacters(in: CharacterSet(charactersIn: "()[]"))
            let bracketed = bare.count < last.count
            if foundYear == nil, bare.count == 4, bare.allSatisfy(\.isNumber), let y = Int(bare), (1920...latest).contains(y) {
                foundYear = y
            } else if foundCountry == nil, Self.countries.contains(bare.uppercased()),
                      bracketed || (bare == bare.uppercased() && title != title.uppercased()) {
                foundCountry = bare.uppercased()
            } else {
                break
            }
            words.removeLast()
        }
        guard foundYear != nil || foundCountry != nil else { return }
        let rest = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -–:,"))
        guard rest.contains(where: { $0.isLetter || $0.isNumber }) else { return }
        writtenTitle = title
        title = rest
        year = foundYear
        country = foundCountry
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
            let rest = after.trimmingCharacters(in: CharacterSet(charactersIn: " )]"))
            let tagged = rest.split(separator: " ").contains(where: isReleaseTag)
            // "12 05 2023" is a day and a month before their year. Not when the numbers can't
            // be ("Die Hard 4 0 2007"), nor when release tags follow, as they follow a film's
            // year ("Fahrenheit 9 11 2004 DVDRip").
            let isDate = after.range(of: #"^[-\s]\d{1,2}[-\s]\d{1,2}\b"#, options: .regularExpression) != nil
                || (endsWithDayAndMonth(before) && !tagged)
            if isDate { continue }
            // "Wonder Woman 1984 2020": a year straight after this one is when the film came
            // out, and this one is part of its name.
            if let next = rest.split(separator: " ").first, next.count == 4, let following = Int(next),
               (1920...latest).contains(following), after.hasPrefix(" ") { continue }
            if before.last == "(" || before.last == "[" { return (year, range) }
            let onlyGroup = rest.hasPrefix("-") && !rest.contains(" ")   // "Heat 1995-GRP"
            if rest.isEmpty || onlyGroup || tagged || isCutName(rest) {
                return (year, range)
            }
        }
        return nil
    }

    /// "Directors Cut", "The Final Cut", "Special Edition": words after a year that name a cut
    /// of the film and nothing else. A cut's noun must be among them, so "Project 2023 Final"
    /// keeps its name.
    private static func isCutName(_ text: String) -> Bool {
        let words = text.lowercased().split(separator: " ")
            .map { $0.filter { $0.isLetter || $0.isNumber } }.filter { !$0.isEmpty }
        let describing: Set<String> = ["the", "directors", "director", "s", "theatrical", "final", "special", "uncut",
                                       "redux", "ultimate", "anniversary"]
        return words.contains(where: cutNouns.contains)
            && words.allSatisfy { cutNouns.contains($0) || everydayTags.contains($0) || describing.contains($0) }
    }

    private static let dayAndMonth = try! NSRegularExpression(pattern: #"\b(\d{1,2})[-\s](\d{1,2})[-\s]$"#)

    /// Whether the text ends in two numbers that can be a day and a month, in either order.
    private static func endsWithDayAndMonth(_ text: String) -> Bool {
        guard let m = dayAndMonth.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let a = Range(m.range(at: 1), in: text).flatMap({ Int(text[$0]) }),
              let b = Range(m.range(at: 2), in: text).flatMap({ Int(text[$0]) }) else { return false }
        return (1...31).contains(a) && (1...31).contains(b) && min(a, b) <= 12
    }

    /// Square-bracketed tags at the end of a name say nothing about the video: a download's
    /// video id ("[dQw4w9WgXcQ]"), a release site ("[YTS.MX]"), a quality ("[1080p]"). A year
    /// ("Heat [1995]") does, and stays for `filmYear` to read.
    private static func withoutTrailingTags(_ name: String) -> String {
        var s = name
        while let r = s.range(of: #"\s*\[[^\[\]]*\]\s*$"#, options: .regularExpression) {
            let inside = SeriesName.normalize(String(s[r]).trimmingCharacters(in: CharacterSet(charactersIn: " []")))
            let marksEpisode = episodeMarkers.contains { $0.firstMatch(in: inside, range: NSRange(inside.startIndex..., in: inside)) != nil }
            let whole = NSRange(inside.startIndex..., in: inside)
            let isYear = yearPattern.firstMatch(in: inside, range: whole)?.range == whole
            guard s[..<r.lowerBound].contains(where: \.isLetter), !marksEpisode, !isYear else { break }
            s.removeSubrange(r)
        }
        return s
    }

    /// "my-summer-vacation-2023" -> "my summer vacation 2023": a name written with hyphens for
    /// spaces. Hyphens between numbers (a date) stay; a single hyphen ("Spider-Man") is left alone.
    private static func wordsFromSlug(_ name: String) -> String {
        guard !name.contains(where: { $0 == " " || $0 == "." || $0 == "_" }),
              name.filter({ $0 == "-" }).count >= 2 else { return name }
        // "Spider-Man-2", "X-Men-2": a hyphenated title and its number, not words joined by hyphens.
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 3, (1...2).contains(parts[2].count), parts[2].allSatisfy(\.isNumber),
           parts[0].first?.isUppercase == true, parts[1].first?.isUppercase == true {
            return "\(parts[0])-\(parts[1]) \(parts[2])"
        }
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

    /// Release tags that are everyday words too, and so turn up in titles.
    private static let everydayTags: Set<String> = [
        "proper", "repack", "internal", "limited", "extended", "unrated", "remastered", "hybrid", "criterion",
        "multi", "dolby", "atmos",
    ]
    /// What such a word is followed by when it names a cut: "Extended Cut", "Limited Edition",
    /// "Criterion Collection".
    private static let cutNouns: Set<String> = ["cut", "edition", "version", "collection", "release"]

    /// The words before the first release tag ("Heat 1080p BluRay" -> "Heat"). A tag that is an
    /// everyday word ends the title only when nothing but tags follows it: "Heat Extended Cut
    /// 1080p" is Heat, and "Our Extended Family Christmas" keeps its whole name.
    static func cutAtReleaseTag(_ text: String) -> String {
        let words = text.split(separator: " ")
        var kept: [Substring] = []
        for (i, word) in words.enumerated() {
            if !kept.isEmpty, isReleaseTag(word), !isEverydayTag(word) || onlyTagsFollow(words[(i + 1)...]) { break }
            kept.append(word)
        }
        return kept.joined(separator: " ")
    }

    private static func tagForms(_ word: Substring) -> (bare: String, beforeGroup: String) {
        let bare = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[](){}-"))
        return (bare, bare.split(separator: "-").first.map(String.init) ?? bare)
    }

    private static func isEverydayTag(_ word: Substring) -> Bool {
        let (bare, beforeGroup) = tagForms(word)
        return everydayTags.contains(bare) || everydayTags.contains(beforeGroup)
    }

    /// True when the words up to the next unmistakable tag, or to the end, are all tag words.
    private static func onlyTagsFollow(_ rest: ArraySlice<Substring>) -> Bool {
        for word in rest {
            if isEverydayTag(word) || cutNouns.contains(tagForms(word).bare) { continue }
            return isReleaseTag(word)
        }
        return true
    }

    /// A word of a release name that isn't the title: "1080p", "BluRay", a tag joined to the
    /// release group by a hyphen ("x265-RARBG"), a frame rate ("60fps"), a picture size ("1920x1080").
    static func isReleaseTag(_ word: Substring) -> Bool {
        let (bare, beforeGroup) = tagForms(word)
        if releaseTags.contains(bare) || releaseTags.contains(beforeGroup) { return true }
        return beforeGroup.range(of: #"^(\d{2,3}fps|\d{3,4}x\d{3,4})$"#, options: .regularExpression) != nil
    }

    private static func tidy(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: CharacterSet(charactersIn: " -–:,([{#"))
        // "[REC]", "(500) Days of Summer": a bracket the name opens with stays when it closes.
        if let open = text.trimmingCharacters(in: CharacterSet(charactersIn: " -–:,#")).first,
           let close = ["(": ")", "[": "]", "{": "}"][open], t.contains(close) {
            t = String(open) + t
        }
        t = t.split(separator: " ").joined(separator: " ")
        guard t.contains(where: \.isLetter) || t.contains(where: \.isNumber) else { return nil }
        return t == t.lowercased() ? capitalizedWords(t) : t
    }

    /// An all-lowercase name with a capital at the start of each word: "3rd Rock From The Sun",
    /// "Se7en", "Spider-Man". Plain `capitalized` starts a word again after a digit ("3Rd",
    /// "Se7En"); the word rules of a fixed language don't, and give the same on every Mac (a
    /// Turkish one would write "Ice" with a dotted capital I).
    static func capitalizedWords(_ text: String) -> String {
        text.capitalized(with: Locale(identifier: "en_US_POSIX"))
    }
}
