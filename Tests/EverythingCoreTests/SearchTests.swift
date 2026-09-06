import XCTest
@testable import EverythingCore

final class SearchTests: XCTestCase {
    func testFuzzySubsequence() {
        XCTAssertNotNil(FuzzyMatcher.score(query: "prd rpt", candidate: "product report"))
        XCTAssertNotNil(FuzzyMatcher.score(query: "pdrpt", candidate: "productreport"))
        XCTAssertNil(FuzzyMatcher.score(query: "zzzz", candidate: "productreport"))
    }

    func testParser() {
        let q = QueryParser.parse("dashboard ext:fig path:work size:>10mb")
        XCTAssertEqual(q.text, "dashboard")
        XCTAssertEqual(q.fileExtension, "fig")
        XCTAssertEqual(q.pathContains, "work")
        XCTAssertEqual(q.minimumSize, 10_000_000)
    }

    func testRanking() {
        let records = [
            record(1, "annual-report.pdf"),
            record(2, "report.pdf"),
            record(3, "old_report_backup.pdf")
        ]
        let engine = SearchEngine(records: records)
        let results = engine.search("report")
        XCTAssertEqual(results.first?.record.name, "report.pdf")
    }

    private func record(_ id: UInt64, _ name: String) -> FileRecord {
        FileRecord(
            id: id,
            name: name,
            normalizedName: StringNormalizer.normalize(name),
            path: "/tmp/\(name)",
            normalizedPath: StringNormalizer.normalize("/tmp/\(name)"),
            fileExtension: URL(fileURLWithPath: name).pathExtension,
            isDirectory: false,
            size: 100,
            createdAt: nil,
            modifiedAt: nil
        )
    }
}
