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
        "zul": "zu",
    ]

    /// Two-letter code for any 2- or 3-letter code, or nil for "und" / unknown values.
    static func normalize(_ code: String?) -> String? {
        guard var c = code?.lowercased().trimmingCharacters(in: .whitespaces), !c.isEmpty, c != "und" else { return nil }
        if let dash = c.firstIndex(where: { $0 == "-" || $0 == "_" }) { c = String(c[..<dash]) }
        if c.count == 2 { return c }
        return threeToTwo[c]
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

    static func matches(_ a: String?, _ b: String?) -> Bool {
        guard let x = normalize(a), let y = normalize(b) else { return false }
        return x == y
    }

    /// Languages offered in Settings pickers.
    static let common: [String] = ["en", "es", "fr", "de", "it", "pt", "nl", "sv", "no", "da", "fi", "pl",
                                   "ru", "uk", "tr", "el", "he", "ar", "hi", "ja", "ko", "zh", "th", "vi", "id"]
}
