import Foundation

public actor IndexManager {
    private let scanner = FileScanner()
    private let engine = SearchEngine()
    private(set) public var isIndexing = false
    private(set) public var indexedCount = 0

    public init() {}

    public func rebuild(root: URL, limit: Int? = nil) async {
        isIndexing = true
        let records = await Task.detached(priority: .userInitiated) {
            FileScanner().scan(root: root, limit: limit)
        }.value
        engine.replaceIndex(with: records)
        indexedCount = records.count
        isIndexing = false
    }

    public func search(_ query: String, limit: Int = 100) async -> [SearchResult] {
        engine.search(query, limit: limit)
    }
}
