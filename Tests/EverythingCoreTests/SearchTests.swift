import XCTest
@testable import EverythingCore

final class SearchTests: XCTestCase {
    func testFuzzySubsequence() {
        XCTAssertNotNil(FuzzyMatcher.score(query: "pdrpt", candidate: "productreport"))
        XCTAssertNil(FuzzyMatcher.score(query: "zzzz", candidate: "productreport"))
    }

    func testTokenSearch() {
        let engine = SearchEngine(records: [record(1, "product report.pdf")])
        XCTAssertEqual(engine.search("prd rpt").first?.record.name, "product report.pdf")
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

    func testDefaultQueryDoesNotMatchPath() {
        let r = record(1, "invoice.pdf", path: "/tmp/report-folder/invoice.pdf")
        let engine = SearchEngine(records: [r])
        XCTAssertTrue(engine.search("report").isEmpty)
        XCTAssertEqual(engine.search("invoice").first?.record.name, "invoice.pdf")
        XCTAssertEqual(engine.search("invoice path:report-folder").first?.record.name, "invoice.pdf")
    }

    func testProgressiveNarrowingRemainsCorrect() {
        let engine = SearchEngine(records: [
            record(1, "report.pdf"),
            record(2, "repository.txt"),
            record(3, "photo.jpg")
        ])
        XCTAssertFalse(engine.search("r").isEmpty)
        XCTAssertEqual(engine.search("re").count, 2)
        XCTAssertEqual(engine.search("repos").first?.record.name, "repository.txt")
        // Backspace forces a full-index search rather than incorrectly reusing the narrower set.
        XCTAssertEqual(engine.search("re").count, 2)
    }

    func testScannerStableIDs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sample.txt")
        try Data("hello".utf8).write(to: file)

        let scanner = FileScanner()
        let a = scanner.record(for: file)
        let b = scanner.record(for: file)
        XCTAssertEqual(a?.id, b?.id)
    }

    func testChineseDirectAndPinyinSearch() {
        let name = "产品报告.pdf"
        let aliases = StringNormalizer.pinyinAliases(name)
        let chinese = FileRecord(
            id: 99,
            name: name,
            normalizedName: StringNormalizer.normalize(name),
            pinyinName: aliases.full,
            pinyinCompact: aliases.compact,
            pinyinInitials: aliases.initials,
            path: "/tmp/\(name)",
            normalizedPath: StringNormalizer.normalize("/tmp/\(name)"),
            fileExtension: "pdf",
            isDirectory: false,
            size: 100,
            createdAt: nil,
            modifiedAt: nil
        )
        let engine = SearchEngine(records: [chinese])
        XCTAssertEqual(engine.search("产品").first?.record.name, name)
        XCTAssertEqual(engine.search("chanpin").first?.record.name, name)
        XCTAssertEqual(engine.search("cpbg").first?.record.name, name)
    }

    func testDotExtensionUsesExtensionIndex() {
        let engine = SearchEngine(records: [record(1, "body.glb"), record(2, "body.gltf"), record(3, "notes.txt")])
        XCTAssertEqual(engine.search(".glb").map(\.record.name), ["body.glb"])
        XCTAssertEqual(engine.lastDiagnostics.route, "extension")
    }

    private func record(_ id: UInt64, _ name: String, path: String? = nil) -> FileRecord {
        FileRecord(
            id: id,
            name: name,
            normalizedName: StringNormalizer.normalize(name),
            path: path ?? "/tmp/\(name)",
            normalizedPath: StringNormalizer.normalize(path ?? "/tmp/\(name)"),
            fileExtension: URL(fileURLWithPath: name).pathExtension,
            isDirectory: false,
            size: 100,
            createdAt: nil,
            modifiedAt: nil
        )
    }
}

extension SearchTests {
    func testLargeExtensionPostingStopsAtLimit() {
        let records = (0..<1500).map { i in
            record(UInt64(i + 1), "file\(i).doc")
        }
        let engine = SearchEngine(records: records)
        let results = engine.search(".doc", limit: 200)
        XCTAssertEqual(results.count, 200)
        XCTAssertEqual(engine.lastDiagnostics.route, "extension")
        XCTAssertLessThanOrEqual(engine.lastDiagnostics.examinedCount, 200)
    }
}

extension SearchTests {
    func testBinaryIndexRoundTrip() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let storage = IndexStorage(baseURL: base)
        let input = [record(1, "模型.glb"), record(2, "report.pdf")]
        try storage.save(records: input, root: URL(fileURLWithPath: "/tmp"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("index/records.bin").path))
        XCTAssertEqual(storage.preferredFormat, .binary)
        let output = try XCTUnwrap(storage.load(root: URL(fileURLWithPath: "/tmp")))
        XCTAssertEqual(output, input)
    }
}

extension SearchTests {
    func testPersistentPostingsRoundTripPreservesFastRoutes() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("search-postings.bin")
        let input = [record(1, "body.glb"), record(2, "模型.glb"), record(3, "report.doc")]
        let source = SearchEngine(records: input)
        try source.savePersistentPostings(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let restored = SearchEngine()
        XCTAssertTrue(restored.loadPersistentPostings(records: input, from: url))
        XCTAssertEqual(restored.search(".glb").count, 2)
        XCTAssertEqual(restored.lastDiagnostics.route, "extension")
        XCTAssertEqual(restored.search("模型").first?.record.name, "模型.glb")
        XCTAssertEqual(restored.lastDiagnostics.route, "bigram")
    }
}
