import Foundation

/// Whether a subtitle was made for the same release as the video, judged by their names.
/// Subtitles are timed to one release; another cut or source (a Blu-ray against a streaming
/// copy with a different intro) can drift out of sync.
enum ReleaseMatch {
    /// True when the subtitle's release name is the video's file name, or comes from the same
    /// release group and source ("…1080p.BluRay.x265-RARBG" and "…720p.BluRay.x264-RARBG"),
    /// and doesn't name a different year or episode.
    static func isSameRelease(_ subtitle: String, as video: String) -> Bool {
        let sub = withoutExtension(subtitle), vid = withoutExtension(video)
        let s = MediaTitle.parse(fileName: sub), v = MediaTitle.parse(fileName: vid)
        if let a = s.year, let b = v.year, a != b { return false }
        if s.isEpisode, v.isEpisode, s.season != v.season || s.episode != v.episode { return false }
        let a = words(sub), b = words(vid)
        if !a.isEmpty, a == b { return true }
        guard let g = group(sub), g == group(vid) else { return false }
        let sa = source(a), sb = source(b)
        return sa == nil || sb == nil || sa == sb
    }

    /// The words of a name, lower-cased: "The.Sopranos.S04E07.1080p.BluRay.x265-RARBG" ->
    /// the, sopranos, s04e07, 1080p, bluray, x265, rarbg.
    static func words(_ name: String) -> [String] {
        name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// The group that made the release, after the last hyphen of the name's last part:
    /// "x265-RARBG" -> "rarbg". A language code after it ("-GRP.en") is skipped; "WEB-DL" and
    /// "DTS-HD" end in a tag, not a group.
    static func group(_ name: String) -> String? {
        var parts = name.split(whereSeparator: { $0 == "." || $0 == " " }).map(String.init)
        while let last = parts.last, isLanguageCode(last) { parts.removeLast() }
        guard let last = parts.last, let dash = last.lastIndex(of: "-") else { return nil }
        let tail = last[last.index(after: dash)...].lowercased()
        guard (2...20).contains(tail.count), tail.allSatisfy({ $0.isLetter || $0.isNumber }),
              !["dl", "hd", "ma", "rip", "ray"].contains(tail) else { return nil }
        return tail
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
        return (2...3).contains(part.count) && part.allSatisfy(\.isLetter) && part == lower
    }

    private static func withoutExtension(_ name: String) -> String {
        name.replacingOccurrences(of: #"\.(srt|sub|ass|ssa|vtt|idx|mkv|mp4|m4v|avi|mov)$"#, with: "",
                                  options: [.regularExpression, .caseInsensitive])
    }
}
