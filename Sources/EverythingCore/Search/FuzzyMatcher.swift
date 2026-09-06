import Foundation

public enum FuzzyMatcher {
    /// Returns nil when the candidate does not match. Higher is better.
    public static func score(query: String, candidate: String) -> Int? {
        guard !query.isEmpty else { return 1 }
        if candidate == query { return 10_000 }
        if candidate.hasPrefix(query) { return 9_000 - min(candidate.count - query.count, 1_000) }
        if let range = candidate.range(of: query) {
            let offset = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
            let boundaryBonus = isWordBoundary(candidate, at: range.lowerBound) ? 500 : 0
            return 7_500 + boundaryBonus - min(offset, 1_000)
        }

        let q = Array(query)
        let c = Array(candidate)
        var qi = 0
        var score = 0
        var lastMatch = -2
        var firstMatch = Int.max

        for (ci, char) in c.enumerated() {
            guard qi < q.count else { break }
            if char == q[qi] {
                if firstMatch == Int.max { firstMatch = ci }
                score += 100
                if ci == lastMatch + 1 { score += 80 }
                if ci == 0 || isBoundary(c, ci) { score += 60 }
                lastMatch = ci
                qi += 1
            }
        }

        guard qi == q.count else { return nil }
        score -= min(firstMatch * 8, 500)
        score -= min(c.count - q.count, 500)
        return max(score, 1)
    }

    private static func isWordBoundary(_ string: String, at index: String.Index) -> Bool {
        if index == string.startIndex { return true }
        let previous = string[string.index(before: index)]
        return !previous.isLetter && !previous.isNumber
    }

    private static func isBoundary(_ chars: [Character], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        return !chars[index - 1].isLetter && !chars[index - 1].isNumber
    }
}
