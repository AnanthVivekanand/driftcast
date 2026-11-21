import Foundation

struct SubtitleCue: Sendable, Hashable {
    var start: Double
    var end: Double
    var text: String
}

/// A subtitle the user can pick: a stream inside the file, or a separate file.
enum SubtitleChoice: Hashable, Identifiable, Sendable {
    case embedded(MediaInfo.Subtitle)
    case external(URL)

    static let externalTextExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "smi", "sami"]
    static let externalPictureExtensions: Set<String> = ["idx", "sup"]

    var id: String {
        switch self {
        case .embedded(let s): return "embedded-\(s.index)"
        case .external(let url): return "external-\(url.path)"
        }
    }

    var isPicture: Bool {
        switch self {
        case .embedded(let s): return s.isPicture
        case .external(let url): return Self.externalPictureExtensions.contains(url.pathExtension.lowercased())
        }
    }

    var isForced: Bool {
        switch self {
        case .embedded(let s): return s.isForced
        case .external(let url): return url.lastPathComponent.lowercased().contains("forced")
        }
    }

    var language: String? {
        switch self {
        case .embedded(let s): return s.language
        case .external(let url): return Self.languageInName(url)
        }
    }

    /// Words a subtitle file name may end with besides its language: kinds of subtitle.
    private static let flagWords: Set<String> = ["forced", "foreign", "sdh", "hi", "cc", "default", "full", "normal",
                                                 "sub", "subs", "subtitle", "subtitles", "signs", "songs", "commentary"]

    /// Folders releases keep their subtitles in, beside the video.
    private static let subtitleFolderNames: Set<String> = ["subs", "subtitles", "sub", "subtitle"]

    /// The language a subtitle file's name ends with: "Movie.en.forced.srt" is "en", "Movie.pt-BR.srt"
    /// "pt-BR", "Movie.English.srt" "en".
    ///
    /// Only the parts at the end are read, past flags ("forced", "sdh") and numbers (a download's id, a
    /// track number), stopping at the first other word; the first part is the title and is never read.
    /// Every part used to be tried, title words included, so "Sin.City.2005.srt" was Sinhala and
    /// "El.Camino.2019.srt" Greek, which also picked the wrong code page to read the file with. In a
    /// Subs folder the whole name can be the language, as in releases' "2_English.srt".
    static func languageInName(_ url: URL) -> String? {
        var parts = url.deletingPathExtension().lastPathComponent.split(separator: ".").map(String.init)
        if !isInSubtitleFolder(url) {
            parts = Array(parts.dropFirst())
        }
        // "hi" is Hindi or hearing impaired; it is Hindi only when nothing else names a language.
        var flagLanguage: String?
        for part in parts.reversed() {
            var word = part
            if let underscore = word.firstIndex(of: "_"), underscore > word.startIndex,
               word[..<underscore].allSatisfy(\.isNumber) {
                word = String(word[word.index(after: underscore)...])
            }
            let lower = word.lowercased()
            if !lower.isEmpty, lower.allSatisfy(\.isNumber), !isYear(lower) {
                continue
            }
            if flagWords.contains(lower) {
                if flagLanguage == nil { flagLanguage = Lang.fileNameLanguage(word) }
                continue
            }
            if let language = Lang.fileNameLanguage(word) {
                return language
            }
            // "English (SDH)", "English SDH": a language's name and then something else.
            let leading = String(word.prefix { $0.isLetter })
            if leading.count >= 4, leading != word, let language = Lang.fileNameLanguage(leading) {
                return language
            }
            break
        }
        return flagLanguage
    }

    private static func isYear(_ digits: String) -> Bool {
        digits.count == 4 && (digits.hasPrefix("19") || digits.hasPrefix("20"))
    }

    private static func isInSubtitleFolder(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent()
        return [parent, parent.deletingLastPathComponent()].contains {
            subtitleFolderNames.contains($0.lastPathComponent.lowercased())
        }
    }

    /// Whether a subtitle file named `name` belongs to the video named `base` (both without extension):
    /// the same name, or the name followed by a separator and then a language, a flag or the video's
    /// own extension ("Movie.mkv.srt"). A bare prefix used to be enough, so "Alien.mkv" took
    /// "Aliens.en.srt", "Show.S01E1.mkv" took "Show.S01E10.en.srt", and with captions set to come on,
    /// another video's subtitle came on.
    static func isSidecarName(_ name: String, of base: String) -> Bool {
        let name = name.lowercased(), base = base.lowercased()
        guard name.hasPrefix(base) else { return false }
        let rest = name.dropFirst(base.count)
        guard let separator = rest.first else { return true }
        let separators: Set<Character> = [".", "-", "_", " "]
        guard separators.contains(separator) else { return false }
        guard let first = rest.split(whereSeparator: { separators.contains($0) }).first.map(String.init) else { return true }
        return Lang.fileNameLanguage(first) != nil || flagWords.contains(first) || videoExtensions.contains(first)
    }

    var label: String {
        switch self {
        case .embedded(let s):
            var parts: [String] = [Lang.name(s.language) ?? "Unknown language"]
            parts.append(Codecs.subtitleName(s.codec))
            if s.isForced { parts.append("Forced") }
            if let t = s.title, !t.isEmpty, !parts.contains(t) { parts.append(t) }
            return parts.joined(separator: " · ")
        case .external(let url):
            var parts: [String] = [Lang.name(language) ?? url.deletingPathExtension().lastPathComponent]
            parts.append(url.pathExtension.uppercased())
            if isForced { parts.append("Forced") }
            parts.append("External")
            return parts.joined(separator: " · ")
        }
    }

    /// "English, Spanish, English (forced)" for the details panel's one-line summary: each
    /// language once, forced tracks marked; "None" when the video has no subtitles at all.
    static func languageSummary(_ choices: [SubtitleChoice]) -> String {
        var names: [String] = []
        for choice in choices {
            var name = Lang.name(choice.language) ?? "Unknown language"
            if choice.isForced { name += " (forced)" }
            if !names.contains(name) { names.append(name) }
        }
        return names.isEmpty ? "None" : names.joined(separator: ", ")
    }

    /// Whether there is a full (not forced) subtitle in `language`: what "Turn on subtitles"
    /// needs and what the crossed-out captions mark reports the lack of.
    static func hasFull(_ choices: [SubtitleChoice], in language: String) -> Bool {
        !language.isEmpty && choices.contains { Lang.matches($0.language, language) && !$0.isForced }
    }

    /// Whether there is any subtitle in `language`, forced ones included: the crossed-out
    /// captions mark shows only when this is false, since a forced track in your language
    /// is still your language.
    static func hasAny(_ choices: [SubtitleChoice], in language: String) -> Bool {
        !language.isEmpty && choices.contains { Lang.matches($0.language, language) }
    }

    /// Embedded streams plus matching files next to the video plus ones the user attached.
    static func available(for item: MediaItem, info: MediaInfo) -> [SubtitleChoice] {
        var choices = info.subtitles.map { SubtitleChoice.embedded($0) }
        var seen = Set<URL>()
        for url in externalFiles(near: item.url) + item.extraSubtitles where !seen.contains(url) {
            seen.insert(url)
            if FileManager.default.fileExists(atPath: url.path) { choices.append(.external(url)) }
        }
        return choices
    }

    /// Subtitle files that belong to the video: beside it with its name (`isSidecarName`), and in a
    /// Subs or Subtitles folder beside it, the way releases ship them: in a folder named after the
    /// video ("Subs/Show.S01E01/2_English.srt"), named after the video, or, when the video is the only
    /// one in its folder, every subtitle file there ("Subs/2_English.srt").
    static func externalFiles(near video: URL) -> [URL] {
        let fileManager = FileManager.default
        let dir = video.deletingLastPathComponent()
        let base = video.deletingPathExtension().lastPathComponent.lowercased()
        let all = externalTextExtensions.union(externalPictureExtensions)
        func list(_ folder: URL) -> [URL] {
            // Hidden files are skipped: a drive formatted for Windows keeps a "._" file beside each one.
            (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: [.skipsHiddenFiles])) ?? []
        }
        func isSubtitle(_ file: URL) -> Bool { all.contains(file.pathExtension.lowercased()) }
        func isFolder(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        func name(_ file: URL) -> String { file.deletingPathExtension().lastPathComponent }
        func sorted(_ files: [URL]) -> [URL] {
            files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }

        let files = list(dir)
        var found = sorted(files.filter { isSubtitle($0) && isSidecarName(name($0), of: base) })
        let onlyVideo = files.filter { videoExtensions.contains($0.pathExtension.lowercased()) }.count <= 1
        for folder in files where subtitleFolderNames.contains(folder.lastPathComponent.lowercased()) && isFolder(folder) {
            var inFolder: [URL] = []
            for file in list(folder) {
                if isSubtitle(file) {
                    if onlyVideo || isSidecarName(name(file), of: base) { inFolder.append(file) }
                } else if file.lastPathComponent.lowercased() == base, isFolder(file) {
                    inFolder += list(file).filter(isSubtitle)
                }
            }
            found += sorted(inFolder)
        }
        return found
    }

    /// What counts as another video when deciding whether a Subs folder's files are this video's.
    /// Audio files don't: a film's folder can hold its soundtrack.
    private static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "wmv", "ts", "m2ts", "mts",
                                                       "webm", "mpg", "mpeg", "flv", "ogv", "3gp", "vob", "divx", "rmvb"]
}

/// Reads subtitle files written in any encoding. Downloaded subtitles from before UTF-8 took over
/// are in whatever code page their language used, and nothing in the file says which.
enum SubtitleText {
    /// Legacy encodings for a two-letter language, most likely first.
    private static func codePages(_ language: String?) -> [CFStringEncoding] {
        func page(_ e: CFStringEncodings) -> CFStringEncoding { CFStringEncoding(e.rawValue) }
        switch language {
        case "ru", "uk", "be", "bg", "sr", "mk": return [page(.windowsCyrillic), page(.KOI8_R), page(.macCyrillic)]
        case "pl", "cs", "sk", "hu", "hr", "sl", "ro", "bs", "sq": return [page(.windowsLatin2), page(.isoLatin2)]
        case "el": return [page(.windowsGreek), page(.isoLatinGreek)]
        case "tr": return [page(.windowsLatin5), page(.isoLatin5)]
        case "he": return [page(.windowsHebrew), page(.isoLatinHebrew)]
        case "ar", "fa", "ur": return [page(.windowsArabic), page(.isoLatinArabic)]
        case "vi": return [page(.windowsVietnamese)]
        case "th": return [page(.dosThai)]
        case "et", "lv", "lt": return [page(.windowsBalticRim), page(.isoLatin4)]
        case "ja": return [page(.dosJapanese), page(.EUC_JP), page(.ISO_2022_JP)]
        case "zh": return [page(.GB_18030_2000), page(.big5), page(.big5_HKSCS_1999)]
        case "ko": return [page(.dosKorean), page(.EUC_KR)]
        default: return [CFStringBuiltInEncodings.windowsLatin1.rawValue, CFStringBuiltInEncodings.macRoman.rawValue]
        }
    }

    private static func encoding(_ page: CFStringEncoding) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(page))
    }

    /// The name iconv (and so ffmpeg's -sub_charenc) knows the language's usual code page by.
    static func iconvName(forLanguage code: String?) -> String? {
        guard let page = codePages(Lang.normalize(code)).first,
              let name = CFStringConvertEncodingToIANACharSetName(page) else { return nil }
        return name as String
    }

    static func decode(_ data: Data, language: String?) -> String? {
        let bytes = [UInt8](data.prefix(4))
        func text(_ encoding: String.Encoding, dropping count: Int) -> String? { String(data: data.dropFirst(count), encoding: encoding) }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return text(.utf32LittleEndian, dropping: 4) }
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return text(.utf32BigEndian, dropping: 4) }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return text(.utf8, dropping: 3) }
        if bytes.starts(with: [0xFF, 0xFE]) { return text(.utf16LittleEndian, dropping: 2) }
        if bytes.starts(with: [0xFE, 0xFF]) { return text(.utf16BigEndian, dropping: 2) }

        // UTF-16 without a mark: every other byte of Latin text is zero. Checked before UTF-8,
        // which would happily accept those zeroes.
        let sample = [UInt8](data.prefix(4096))
        let zeroes = (odd: stride(from: 1, to: sample.count, by: 2).filter { sample[$0] == 0 }.count,
                      even: stride(from: 0, to: sample.count, by: 2).filter { sample[$0] == 0 }.count)
        if zeroes.odd > sample.count / 4, let s = text(.utf16LittleEndian, dropping: 0) { return s }
        if zeroes.even > sample.count / 4, let s = text(.utf16BigEndian, dropping: 0) { return s }

        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }

        // The file's own language if its name gives one, else the one the person reads.
        let hint = Lang.normalize(language) ?? Lang.normalize(Prefs.string(Prefs.subtitleLanguage))
        let pages = codePages(hint).map(encoding)
        var converted: NSString?
        var lossy = ObjCBool(false)
        var options: [StringEncodingDetectionOptionsKey: Any] = [
            .suggestedEncodingsKey: pages.map { NSNumber(value: $0.rawValue) },
            .useOnlySuggestedEncodingsKey: true,
            .allowLossyKey: false,
        ]
        if let hint { options[.likelyLanguageKey] = hint }
        let found = NSString.stringEncoding(for: data, encodingOptions: options, convertedString: &converted, usedLossyConversion: &lossy)
        if found != 0, let converted { return converted as String }
        for page in pages { if let s = String(data: data, encoding: page) { return s } }
        return String(data: data, encoding: .isoLatin1)
    }
}

/// Converts any text subtitle (embedded or external) to cues through ffmpeg's WebVTT writer.
actor SubtitleLoader {
    static let shared = SubtitleLoader()
    private var cache: [String: [SubtitleCue]] = [:]

    func cues(for choice: SubtitleChoice, media: URL) async throws -> [SubtitleCue] {
        // With the file's date in the key, a subtitle fixed or replaced while Driftcast is open is read
        // again the next time it is chosen, instead of its old cues being served until a relaunch.
        let source: URL
        if case .external(let url) = choice { source = url } else { source = media }
        let modified = (try? FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let key = choice.id + "|" + media.path + "|\(modified)"
        if let c = cache[key] { return c }
        guard let exe = FFmpeg.ffmpeg else { throw FFmpegError.notFound }
        let cues: [SubtitleCue]
        switch choice {
        case .embedded(let s):
            let args = ["-hide_banner", "-nostdin", "-loglevel", "error", "-i", media.path,
                        "-map", "0:\(s.index)", "-vn", "-an", "-f", "webvtt", "-"]
            var found = (try? await FFmpeg.run(exe, args)).map { WebVTT.parse(String(decoding: $0, as: UTF8.self)) } ?? []
            if found.isEmpty, let charset = SubtitleText.iconvName(forLanguage: choice.language) {
                // Old MKVs can carry subtitles in a legacy encoding, which ffmpeg won't guess.
                let retry = ["-hide_banner", "-nostdin", "-loglevel", "error", "-sub_charenc", charset, "-i", media.path,
                             "-map", "0:\(s.index)", "-vn", "-an", "-f", "webvtt", "-"]
                found = WebVTT.parse(String(decoding: try await FFmpeg.run(exe, retry), as: UTF8.self))
            }
            cues = found
        case .external(let url):
            let data = try Data(contentsOf: url)
            guard let text = SubtitleText.decode(data, language: choice.language) else {
                throw FFmpegError.failed("\(url.lastPathComponent) isn't a text file Driftcast can read.")
            }
            if url.pathExtension.lowercased() == "vtt" {
                cues = WebVTT.parse(text)
            } else {
                // ffmpeg reads the text as UTF-8, so it gets a UTF-8 copy.
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("driftcast-subtitle-\(UUID().uuidString)")
                    .appendingPathExtension(url.pathExtension)
                try text.write(to: copy, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: copy) }
                let args = ["-hide_banner", "-nostdin", "-loglevel", "error", "-i", copy.path, "-f", "webvtt", "-"]
                cues = WebVTT.parse(String(decoding: try await FFmpeg.run(exe, args), as: UTF8.self))
            }
        }
        // A load that was called off (ffmpeg stopped part-way) must not leave half a subtitle
        // behind as the one to serve from then on.
        try Task.checkCancellation()
        cache[key] = cues
        return cues
    }
}

enum WebVTT {
    static func parse(_ text: String) -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard let i = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[i].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = time(parts[0]),
                  let end = time(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "") else { continue }
            let body = lines[(i + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: body)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    static func time(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let comps = s.split(separator: ":").map(String.init)
        guard (2...3).contains(comps.count), let sec = Double(comps[comps.count - 1]) else { return nil }
        let units = comps.dropLast().compactMap { Double($0) }
        guard units.count == comps.count - 1 else { return nil }
        return units.count == 2 ? units[0] * 3600 + units[1] * 60 + sec : units[0] * 60 + sec
    }

    static func stamp(_ t: Double) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    /// A WebVTT document with cue times moved earlier by `shift` (for streams that start mid-file).
    /// `window` limits output to cues overlapping that range (HLS subtitle segments).
    static func document(_ cues: [SubtitleCue], shift: Double, window: Range<Double>? = nil, timestampMap: Bool = false) -> String {
        var out = "WEBVTT\n"
        if timestampMap { out += "X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n" }
        out += "\n"
        for cue in cues {
            let s = cue.start - shift, e = cue.end - shift
            guard e > 0 else { continue }
            if let w = window, !(s < w.upperBound && e > w.lowerBound) { continue }
            out += "\(stamp(s)) --> \(stamp(e))\n\(cue.text)\n\n"
        }
        return out
    }
}
