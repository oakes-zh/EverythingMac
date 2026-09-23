import Foundation

public struct FileScanner: Sendable {
    public init() {}

    public func scan(root: URL, limit: Int? = nil, progress: (@Sendable (Int, String) -> Void)? = nil) -> [FileRecord] {
        let fm = FileManager.default
        let keys = resourceKeys

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var results: [FileRecord] = []
        results.reserveCapacity(50_000)

        for case let url as URL in enumerator {
            if let limit, results.count >= limit { break }
            if let record = record(for: url) {
                results.append(record)
                if results.count % 1000 == 0 { progress?(results.count, url.path) }
            }
        }

        progress?(results.count, root.path)
        return results
    }

    public func record(for url: URL) -> FileRecord? {
        do {
            let values = try url.resourceValues(forKeys: resourceKeys)
            if values.isSymbolicLink == true { return nil }

            let name = url.lastPathComponent
            let path = url.path
            let normalizedPath = StringNormalizer.normalize(path)

            let pinyin = StringNormalizer.pinyinAliases(name)

            return FileRecord(
                id: stableID(for: normalizedPath),
                name: name,
                normalizedName: StringNormalizer.normalize(name),
                pinyinName: pinyin.full,
                pinyinCompact: pinyin.compact,
                pinyinInitials: pinyin.initials,
                path: path,
                normalizedPath: normalizedPath,
                fileExtension: url.pathExtension.lowercased(),
                isDirectory: values.isDirectory ?? false,
                size: UInt64(max(values.fileSize ?? 0, 0)),
                createdAt: values.creationDate,
                modifiedAt: values.contentModificationDate
            )
        } catch {
            return nil
        }
    }

    private var resourceKeys: Set<URLResourceKey> {
        [
            .isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey,
            .isHiddenKey, .isSymbolicLinkKey
        ]
    }

    /// Deterministic FNV-1a hash so IDs remain stable across index rebuilds.
    private func stableID(for value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}
