import Foundation

public struct FileRecord: Identifiable, Hashable, Sendable {
    public let id: UInt64
    public let name: String
    public let normalizedName: String
    public let path: String
    public let normalizedPath: String
    public let fileExtension: String
    public let isDirectory: Bool
    public let size: UInt64
    public let createdAt: Date?
    public let modifiedAt: Date?

    public init(
        id: UInt64,
        name: String,
        normalizedName: String,
        path: String,
        normalizedPath: String,
        fileExtension: String,
        isDirectory: Bool,
        size: UInt64,
        createdAt: Date?,
        modifiedAt: Date?
    ) {
        self.id = id
        self.name = name
        self.normalizedName = normalizedName
        self.path = path
        self.normalizedPath = normalizedPath
        self.fileExtension = fileExtension
        self.isDirectory = isDirectory
        self.size = size
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}
