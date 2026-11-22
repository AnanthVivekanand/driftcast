import Foundation

/// Whether a subtitle was made for the same release as the video, judged by their names.
/// Subtitles are timed to one release; another cut or source (a Blu-ray against a streaming
/// copy with a different intro) can drift out of sync.
enum ReleaseMatch {
    /// True when the subtitle's release name is the video's file name, or comes from the same
    /// release group and source ("…1080p.BluRay.x265-RARBG" and "…720p.BluRay.x264-RARBG"),
    /// and doesn't name a different film, year, episode or cut.
    static func isSameRelease(_ subtitle: String, as video: String) -> Bool {
        let sub = withoutExtension(subtitle), vid = withoutExtension(video)
        let s = MediaTitle.parse(fileName: sub), v = MediaTitle.parse(fileName: vid)
        if let a = s.year, let b = v.year, a != b { return false }
        if s.isEpisode, v.isEpisode, s.season != v.season || s.episode != v.episode { return false }
        // A whole season's pack ("Show.S04.720p…") is not this episode's subtitle, nor a film's.
        if s.isEpisode != v.isEpisode { return false }
        let a = words(sub), b = words(vid)
        if !a.isEmpty, a == b { return true }
        // A group puts out many films, and more than one cut of a film.
        let ta = TitleMatch.normalize(s.title), tb = TitleMatch.normalize(v.title)
        guard ta == tb, cut(a) == cut(b) else { return false }
        guard let g = group(sub), g == group(vid) else { return false }
        let sa = source(a), sb = source(b)
        return sa == nil || sb == nil || sa == sb
    }

    /// How near a subtitle that is not for the same release still is, by its name: 1 when it
    /// was taken from the same kind of source as the video (both Blu-ray, both DVD) and names
    /// no other cut, so it is likely in sync, or when no source is given but two or more of
    /// the release's other words are the video's too (not counting a resolution and codec alone); -1 when it names another source, cut,
    /// episode or (for a film) year, so it likely isn't; 0 when the names don't say.
    static func closeness(_ subtitle: String, to video: String) -> Int {
        let sub = withoutExtension(subtitle), vid = withoutExtension(video)
        let s = MediaTitle.parse(fileName: sub), v = MediaTitle.parse(fileName: vid)
        // A show's subtitle often carries the year the show began, not the episode's.
        if !v.isEpisode, let a = s.year, let b = v.year, a != b { return -1 }
        if s.isEpisode, v.isEpisode, s.season != v.season || s.episode != v.episode { return -1 }
        let a = words(sub), b = words(vid)
        if cut(a) != cut(b) { return -1 }
        guard let sa = source(a), let sb = source(b) else {
            // Two shared words, one of them more telling than a resolution or a codec: half the
            // subtitles of a film share "1080p" and "x264" with any copy of it.
            let shared = sharedTagWords(sub, with: vid)
            return shared.count >= 2 && shared.contains(where: { !isCommonTag($0) }) ? 1 : 0
        }
        return sa == sb ? 1 : -1
    }

    /// Words nearly every release of a film carries, which say nothing about which one it is.
    static func isCommonTag(_ word: String) -> Bool {
        if word.range(of: #"^\d{3,4}[pi]$"#, options: .regularExpression) != nil { return true }
        return ["264", "265", "xvid", "divx", "aac", "ac3", "dts", "hdr", "10bit", "8bit", "mp4", "mkv", "avi",
                "hd", "uhd", "4k", "en", "eng", "english", "sub", "subs", "subtitle", "subtitles"].contains(word)
    }

    /// How many of the words that describe the video's release (not its title, episode or
    /// year) the subtitle's name has too: "720p", "bluray", "x264", "reward". The more, the
    /// nearer the two names, which orders results that are otherwise alike.
    static func sharedTags(_ subtitle: String, with video: String) -> Int { sharedTagWords(subtitle, with: video).count }

    static func sharedTagWords(_ subtitle: String, with video: String) -> Set<String> {
        let vid = withoutExtension(video)
        let title = Set(words(MediaTitle.parse(fileName: vid).title))
        return tags(withoutExtension(subtitle), title: title).intersection(tags(vid, title: title))
    }

    private static func tags(_ name: String, title: Set<String>) -> Set<String> {
        var found = Set<String>()
        for word in words(name) where word.count > 1 && !title.contains(word) {
            // "s01e01", "s01", "e01", "1x01" and a year say which video, not which release.
            if word.range(of: #"^(s\d+(e\d+)?|e\d+|\d+x\d+|(19|20)\d\d)$"#, options: .regularExpression) != nil { continue }
            switch word {
            case "x264", "h264", "avc": found.insert("264")
            case "x265", "h265", "hevc": found.insert("265")
            default: found.insert(word)
            }
        }
        return found
    }

    /// The words of a name, lower-cased: "The.Sopranos.S04E07.1080p.BluRay.x265-RARBG" ->
    /// the, sopranos, s04e07, 1080p, bluray, x265, rarbg.
    static func words(_ name: String) -> [String] {
        name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// The group that made the release, after the last hyphen of the name's last part:
    /// "x265-RARBG" -> "rarbg". A language code after it ("-GRP.en", "-GRP.pt-BR") is skipped.
    /// "WEB-DL", "DTS-HD" and "H-264" end in a tag, not a group, and a name with no release
    /// tags at all ("Spider-Man") has no group.
    static func group(_ name: String) -> String? {
        var parts = name.split(whereSeparator: { $0 == "." || $0 == " " }).map(String.init)
        while let last = parts.last, isLanguageCode(last) { parts.removeLast() }
        guard let last = parts.last, let dash = last.lastIndex(of: "-") else { return nil }
        let tail = last[last.index(after: dash)...].lowercased()
        guard (2...20).contains(tail.count), tail.allSatisfy({ $0.isLetter || $0.isNumber }),
              tail.contains(where: \.isLetter),
              !["dl", "hd", "ma", "rip", "ray", "es", "ex", "hr", "lc", "aac", "plus", "tv"].contains(tail),
              parts.contains(where: { MediaTitle.isReleaseTag(Substring($0)) }) else { return nil }
        return tail
    }

    /// The words that name a longer or different cut of a film, which is timed differently
    /// ("Extended", "Unrated", "Director's Cut"). None means the cut shown in cinemas.
    static func cut(_ words: [String]) -> Set<String> {
        var found = Set(words).intersection(["extended", "unrated", "uncut", "redux", "directors", "director"])
        if found.remove("director") != nil { found.insert("directors") }
        return found
    }

    /// Where the release was taken from, which decides its timing.
    static func source(_ words: [String]) -> String? {
        let joined = " " + words.joined(separator: " ") + " "
        if ["bluray", "bdrip", "brrip", "bdremux"].contains(where: words.contains) || joined.contains(" blu ray ") { return "bluray" }
        if ["dvdrip", "dvd"].contains(where: words.contains) { return "dvd" }
        if ["hdtv", "pdtv"].contains(where: words.contains) { return "tv" }
        if ["web", "webrip", "webdl", "amzn", "nf", "dsnp", "hmax", "atvp"].contains(where: words.contains) { return "web" }
        return nil
    }

    private static func isLanguageCode(_ part: String) -> Bool {
        let lower = part.lowercased()
        if ["sdh", "hi", "cc", "forced"].contains(lower) { return true }
        // "pt-BR", "zh-Hans": a language with its region or script.
        if part.range(of: #"^[a-z]{2,3}-[A-Za-z]{2,4}$"#, options: .regularExpression) != nil { return true }
        return (2...3).contains(part.count) && part.allSatisfy(\.isLetter) && part == lower
    }

    private static func withoutExtension(_ name: String) -> String {
        name.replacingOccurrences(of: #"\.(srt|sub|ass|ssa|vtt|idx|mkv|mp4|m4v|avi|mov)$"#, with: "",
                                  options: [.regularExpression, .caseInsensitive])
    }
}
