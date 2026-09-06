import Foundation

public enum QueryParser {
    public static func parse(_ raw: String, now: Date = Date()) -> SearchQuery {
        var query = SearchQuery()
        var freeText: [String] = []

        for token in splitRespectingQuotes(raw) {
            let lower = token.lowercased()

            if lower.hasPrefix("ext:") {
                let value = String(token.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if !value.isEmpty { query.fileExtension = value.lowercased() }
            } else if lower.hasPrefix("path:") {
                let value = String(token.dropFirst(5))
                if !value.isEmpty { query.pathContains = StringNormalizer.normalize(value) }
            } else if lower.hasPrefix("kind:"), let kind = FileKind(rawValue: String(lower.dropFirst(5))) {
                query.kind = kind
            } else if lower.hasPrefix("size:>") {
                query.minimumSize = parseByteSize(String(lower.dropFirst(6)))
            } else if lower.hasPrefix("size:<") {
                query.maximumSize = parseByteSize(String(lower.dropFirst(6)))
            } else if lower == "modified:today" {
                query.modifiedAfter = Calendar.current.startOfDay(for: now)
            } else if lower.hasPrefix("modified:<"), lower.hasSuffix("d") {
                let digits = lower.dropFirst("modified:<".count).dropLast()
                if let days = Int(digits), days > 0 {
                    query.modifiedAfter = Calendar.current.date(byAdding: .day, value: -days, to: now)
                }
            } else {
                freeText.append(token)
            }
        }

        query.text = StringNormalizer.normalize(freeText.joined(separator: " "))
        return query
    }

    private static func splitRespectingQuotes(_ input: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false

        for char in input {
            if char == "\"" {
                quoted.toggle()
            } else if char.isWhitespace && !quoted {
                if !current.isEmpty { parts.append(current); current = "" }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private static func parseByteSize(_ raw: String) -> UInt64? {
        let units: [(String, Double)] = [
            ("tb", 1_000_000_000_000), ("gb", 1_000_000_000),
            ("mb", 1_000_000), ("kb", 1_000), ("b", 1)
        ]
        for (suffix, multiplier) in units where raw.hasSuffix(suffix) {
            let number = raw.dropLast(suffix.count)
            if let value = Double(number) { return UInt64(value * multiplier) }
        }
        return UInt64(raw)
    }
}
