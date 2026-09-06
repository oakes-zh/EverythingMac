import Foundation

public struct SearchResult: Identifiable, Sendable {
    public let record: FileRecord
    public let score: Int
    public var id: UInt64 { record.id }
}

public final class SearchEngine: @unchecked Sendable {
    private var records: [FileRecord] = []

    public init(records: [FileRecord] = []) {
        self.records = records
    }

    public func replaceIndex(with records: [FileRecord]) {
        self.records = records
    }

    public var count: Int { records.count }

    public func search(_ rawQuery: String, limit: Int = 100) -> [SearchResult] {
        let query = QueryParser.parse(rawQuery)
        var results: [SearchResult] = []
        results.reserveCapacity(min(limit * 2, 1_000))

        for record in records {
            guard passesFilters(record, query: query) else { continue }

            let score: Int
            if query.text.isEmpty {
                score = metadataScore(record)
            } else {
                guard let fuzzy = FuzzyMatcher.score(query: query.text, candidate: record.normalizedName) else { continue }
                score = fuzzy + metadataScore(record)
            }

            results.append(SearchResult(record: record, score: score))
        }

        results.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.record.name.count != $1.record.name.count { return $0.record.name.count < $1.record.name.count }
            return $0.record.path < $1.record.path
        }
        if results.count > limit { results.removeSubrange(limit...) }
        return results
    }

    private func passesFilters(_ record: FileRecord, query: SearchQuery) -> Bool {
        if let ext = query.fileExtension, record.fileExtension != ext { return false }
        if let path = query.pathContains, !record.normalizedPath.contains(path) { return false }
        if let min = query.minimumSize, record.size <= min { return false }
        if let max = query.maximumSize, record.size >= max { return false }
        if let after = query.modifiedAfter, (record.modifiedAt ?? .distantPast) < after { return false }

        if let kind = query.kind {
            switch kind {
            case .folder: if !record.isDirectory { return false }
            case .file: if record.isDirectory { return false }
            case .image: if !["png","jpg","jpeg","gif","webp","heic","tiff","svg"].contains(record.fileExtension) { return false }
            case .video: if !["mp4","mov","m4v","avi","mkv","webm"].contains(record.fileExtension) { return false }
            case .audio: if !["mp3","m4a","wav","aac","flac","aiff"].contains(record.fileExtension) { return false }
            case .document: if !["pdf","doc","docx","txt","md","rtf","pages","xls","xlsx","ppt","pptx"].contains(record.fileExtension) { return false }
            }
        }
        return true
    }

    private func metadataScore(_ record: FileRecord) -> Int {
        var score = record.isDirectory ? 0 : 20
        if let date = record.modifiedAt {
            let age = Date().timeIntervalSince(date)
            if age < 86_400 { score += 30 }
            else if age < 604_800 { score += 15 }
        }
        return score
    }
}
