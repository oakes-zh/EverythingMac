import Foundation

public struct SearchQuery: Sendable, Equatable {
    public var text: String = ""
    public var fileExtension: String?
    public var pathContains: String?
    public var kind: FileKind?
    public var minimumSize: UInt64?
    public var maximumSize: UInt64?
    public var modifiedAfter: Date?

    public init() {}
}

public enum FileKind: String, Sendable, Equatable {
    case file, folder, image, video, audio, document
}
