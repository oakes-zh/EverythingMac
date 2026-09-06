import Foundation

public struct FileScanner: Sendable {
    public init() {}

    public func scan(root: URL, limit: Int? = nil) -> [FileRecord] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey,
            .isHiddenKey, .isSymbolicLinkKey
        ]

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var results: [FileRecord] = []
        results.reserveCapacity(50_000)
        var nextID: UInt64 = 1

        for case let url as URL in enumerator {
            if let limit, results.count >= limit { break }

            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                if values.isSymbolicLink == true { continue }

                let name = url.lastPathComponent
                let path = url.path
                let ext = url.pathExtension.lowercased()
                let size = UInt64(max(values.fileSize ?? 0, 0))

                results.append(FileRecord(
                    id: nextID,
                    name: name,
                    normalizedName: StringNormalizer.normalize(name),
                    path: path,
                    normalizedPath: StringNormalizer.normalize(path),
                    fileExtension: ext,
                    isDirectory: values.isDirectory ?? false,
                    size: size,
                    createdAt: values.creationDate,
                    modifiedAt: values.contentModificationDate
                ))
                nextID &+= 1
            } catch {
                continue
            }
        }

        return results
    }
}
