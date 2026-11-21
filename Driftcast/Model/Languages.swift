import Foundation

/// Language code helpers. Containers use ISO 639-2 ("eng", "ger"/"deu"), settings use ISO 639-1 ("en").
enum Lang {
    private static let threeToTwo: [String: String] = [
        "eng": "en", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de", "spa": "es", "ita": "it",
        "jpn": "ja", "por": "pt", "rus": "ru", "chi": "zh", "zho": "zh", "kor": "ko", "dut": "nl",
        "nld": "nl", "swe": "sv", "nor": "no", "nob": "nb", "dan": "da", "fin": "fi", "pol": "pl",
        "tur": "tr", "ara": "ar", "heb": "he", "hin": "hi", "cze": "cs", "ces": "cs", "gre": "el",
        "ell": "el", "hun": "hu", "rum": "ro", "ron": "ro", "tha": "th", "vie": "vi", "ukr": "uk",
        "ind": "id", "may": "ms", "msa": "ms", "per": "fa", "fas": "fa", "bul": "bg", "hrv": "hr",
        "srp": "sr", "slo": "sk", "slk": "sk", "slv": "sl", "est": "et", "lav": "lv", "lit": "lt",
        "ice": "is", "isl": "is", "cat": "ca", "baq": "eu", "eus": "eu", "glg": "gl", "fil": "tl",
        "tgl": "tl", "tam": "ta", "tel": "te", "ben": "bn", "urd": "ur",
        "afr": "af", "alb": "sq", "sqi": "sq", "amh": "am", "arm": "hy", "hye": "hy", "aze": "az", "bel": "be",
        "bos": "bs", "geo": "ka", "kat": "ka", "kaz": "kk", "khm": "km", "kur": "ku", "lao": "lo", "mac": "mk",
        "mkd": "mk", "mal": "ml", "mar": "mr", "mon": "mn", "nep": "ne", "nno": "nn", "pan": "pa", "pus": "ps",
        "sin": "si", "som": "so", "swa": "sw", "tgk": "tg", "uzb": "uz", "wel": "cy", "cym": "cy", "yid": "yi",
        "zul": "zu", "cmn": "zh",
    ]

    /// Codes that name no language: undetermined, several, none, uncoded.
    private static let notALanguage: Set<String> = ["und", "mul", "zxx", "mis"]

    /// Two-letter code for any 2- or 3-letter code, or nil for "und" / unknown values. A 3-letter code
    /// not in the table above is looked up in the system's list (Kannada "kan" is "kn", Irish "gle" is
    /// "ga"), and one with no 2-letter form (Cantonese "yue") is kept as it is, so the track still gets
    /// a language name instead of none.
    static func normalize(_ code: String?) -> String? {
        guard var c = code?.lowercased().trimmingCharacters(in: .whitespaces), !c.isEmpty, c != "und" else { return nil }
        if let dash = c.firstIndex(where: { $0 == "-" || $0 == "_" }) { c = String(c[..<dash]) }
        if c.count == 2 { return c }
        if let two = threeToTwo[c] { return two }
        guard c.count == 3, !notALanguage.contains(c) else { return nil }
        let system = Locale.LanguageCode(c)
        guard system.isISOLanguage, let two = system.identifier(.alpha2), !notALanguage.contains(two) else { return nil }
        return two
    }

    static func name(_ code: String?) -> String? {
        guard let n = normalize(code) else { return nil }
        return Locale.current.localizedString(forLanguageCode: n)
    }

    /// True only for codes the system knows a name for, so "Up.srt" isn't language "up".
    static func isLanguageCode(_ s: String) -> Bool {
        guard s.count <= 3, let n = normalize(s), let name = Locale.current.localizedString(forLanguageCode: n) else { return false }
        return name.lowercased() != n
    }

    /// Norwegian is tagged three ways: "no" (or "nor") for the language, "nb" (Bokmål, which a Mac set
    /// to Norwegian reports) and "nn" (Nynorsk) for its two written forms. Every Norwegian reader reads
    /// both, and a track tagged "nor" used to count as some other language than "nb".
    private static func matchKey(_ code: String) -> String {
        ["nb", "nn"].contains(code) ? "no" : code
    }

    static func matches(_ a: String?, _ b: String?) -> Bool {
        guard let x = normalize(a), let y = normalize(b) else { return false }
        return matchKey(x) == matchKey(y)
    }

    /// Languages offered in Settings pickers.
    static let common: [String] = ["en", "es", "fr", "de", "it", "pt", "nl", "sv", "no", "da", "fi", "pl",
                                   "ru", "uk", "tr", "el", "he", "ar", "hi", "ja", "ko", "zh", "th", "vi", "id"]

    // MARK: Languages in file names

    /// The languages a subtitle file name is taken to name: the table above and the Settings list. A
    /// word of a title that happens to be some other code ("ii", "to") is not one of them, and neither
    /// are the 3-letter codes that are everyday English words ("Cat", "Ice", "May"), which name the
    /// file's language far less often than they end a film's title.
    private static let fileNameCodes: Set<String> = Set(threeToTwo.keys).union(threeToTwo.values).union(common)
        .subtracting(["cat", "may", "per", "ice", "pan", "mon", "mar", "mal", "sin", "arm", "geo", "mac", "wel",
                      "lit", "ben", "tam", "som"])

    /// Language names, folded to lowercase without accents, in English, in the language itself and in
    /// this Mac's language: "English", "Español", "Svenska". "Brazilian" is Brazilian Portuguese.
    private static let namedLanguages: [String: String] = {
        var names: [String: String] = ["brazilian": "pt-BR", "farsi": "fa", "flemish": "nl", "castilian": "es"]
        let english = Locale(identifier: "en_US")
        for code in Set(threeToTwo.values).union(common) {
            for name in [english.localizedString(forLanguageCode: code),
                         Locale(identifier: code).localizedString(forLanguageCode: code),
                         Locale.current.localizedString(forLanguageCode: code)].compactMap({ $0 }) {
                let key = fold(name)
                if names[key] == nil { names[key] = code }
            }
        }
        return names
    }()

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
    }

    /// The language one part of a subtitle file name names, or nil: a code ("en", "eng"), a code with a
    /// region or script ("pt-BR", "zh-Hans", "pt_BR"), or a language's name ("English", "Français").
    /// Codes are given back as written, with "_" as "-"; names as their 2-letter code.
    static func fileNameLanguage(_ part: String) -> String? {
        let lower = part.lowercased()
        if lower.count <= 3 {
            return lower.allSatisfy(\.isLetter) && fileNameCodes.contains(lower) ? part : nil
        }
        // After the code, a region ("BR", or "419" for Latin America) or a script ("Hans").
        let pieces = part.split(whereSeparator: { $0 == "-" || $0 == "_" })
        if pieces.count == 2, (2 ... 3).contains(pieces[0].count), fileNameCodes.contains(pieces[0].lowercased()) {
            let tail = pieces[1]
            let letters = tail.allSatisfy { $0.isASCII && $0.isLetter }, digits = tail.allSatisfy { $0.isASCII && $0.isNumber }
            if (tail.count == 2 && letters) || (tail.count == 3 && digits) || (tail.count == 4 && letters) {
                return pieces.joined(separator: "-")
            }
        }
        return namedLanguages[fold(part)]
    }
}
