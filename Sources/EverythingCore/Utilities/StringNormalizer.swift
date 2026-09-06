import Foundation

public enum StringNormalizer {
    public static func normalize(_ input: String) -> String {
        input
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }
}
