import Foundation

public enum StringNormalizer {
    public static func normalize(_ input: String) -> String {
        input
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    /// Latin transliteration used for Chinese filename search. For example:
    /// 产品报告 -> chan pin bao gao
    public static func latinized(_ input: String) -> String {
        let normalized = input.precomposedStringWithCanonicalMapping
        let latin = normalized.applyingTransform(.toLatin, reverse: false) ?? normalized
        return latin
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "'", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Compact pinyin makes `chanpin` match `产品`; initials make `cpbg`
    /// match `产品报告`. Non-Latin tokens are ignored for initials.
    public static func pinyinAliases(_ input: String) -> (full: String, compact: String, initials: String) {
        let full = latinized(input)
        let tokens = full.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let compact = tokens.joined()
        let initials = tokens.compactMap { token -> Character? in
            guard let first = token.first, first.isASCII, first.isLetter else { return nil }
            return first
        }.map(String.init).joined()
        return (full, compact, initials)
    }
}
