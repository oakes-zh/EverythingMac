import Foundation

public struct PersistedIndexInfo: Codable, Sendable {
    public let version: Int
    public let rootPath: String
    public let itemCount: Int
    public let savedAt: Date
}

public enum IndexLoadFormat: String, Sendable { case binary, legacyPlist }

public struct IndexStorage: Sendable {
    public let baseURL: URL
    public var binaryRecordsURL: URL { baseURL.appendingPathComponent("index/records.bin") }
    public var legacyRecordsURL: URL { baseURL.appendingPathComponent("index/records.plist") }
    public var stateURL: URL { baseURL.appendingPathComponent("state/index-state.json") }
    public var postingsURL: URL { baseURL.appendingPathComponent("index/search-postings.bin") }

    public init(baseURL: URL? = nil) {
        if let baseURL { self.baseURL = baseURL }
        else {
            let a = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.baseURL = a.appendingPathComponent("EverythingMac", isDirectory: true)
        }
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: binaryRecordsURL.path) || FileManager.default.fileExists(atPath: legacyRecordsURL.path)
    }

    public var preferredFormat: IndexLoadFormat? {
        if FileManager.default.fileExists(atPath: binaryRecordsURL.path) { return .binary }
        if FileManager.default.fileExists(atPath: legacyRecordsURL.path) { return .legacyPlist }
        return nil
    }

    public func prepare() throws {
        let f = FileManager.default
        try f.createDirectory(at: binaryRecordsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try f.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    /// v0.3.0 primary persistence path. SearchEngine itself is intentionally unchanged.
    public func save(records: [FileRecord], root: URL) throws {
        try prepare()
        try BinaryRecordCodec.write(records, to: binaryRecordsURL)
        let info = PersistedIndexInfo(version: 3, rootPath: root.standardizedFileURL.path, itemCount: records.count, savedAt: Date())
        let j = JSONEncoder(); j.outputFormatting = [.prettyPrinted, .sortedKeys]; j.dateEncodingStrategy = .iso8601
        try j.encode(info).write(to: stateURL, options: .atomic)
    }

    /// Loads records.bin when present. A v0.2.x records.plist is still accepted and is
    /// migrated once to records.bin so the next debug launch uses the binary path.
    public func load(root: URL) throws -> [FileRecord]? {
        if FileManager.default.fileExists(atPath: binaryRecordsURL.path) {
            return try BinaryRecordCodec.read(from: binaryRecordsURL)
        }
        guard FileManager.default.fileExists(atPath: legacyRecordsURL.path) else { return nil }
        let records = try PropertyListDecoder().decode([FileRecord].self, from: Data(contentsOf: legacyRecordsURL, options: .mappedIfSafe))
        // Best-effort migration. Never make a valid legacy index unusable if migration fails.
        try? prepare()
        try? BinaryRecordCodec.write(records, to: binaryRecordsURL)
        return records
    }

    public func info() -> PersistedIndexInfo? {
        guard let d = try? Data(contentsOf: stateURL) else { return nil }
        let j = JSONDecoder(); j.dateDecodingStrategy = .iso8601
        return try? j.decode(PersistedIndexInfo.self, from: d)
    }
    public func clear() throws { if FileManager.default.fileExists(atPath: baseURL.path) { try FileManager.default.removeItem(at: baseURL) } }
    public func sizeBytes() -> UInt64 {
        let f = FileManager.default
        guard let e = f.enumerator(at: baseURL, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var t: UInt64 = 0
        for case let u as URL in e { if let n = try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize { t += UInt64(max(0, n)) } }
        return t
    }
}

private enum BinaryRecordCodec {
    static let magic = Data([0x45,0x56,0x4d,0x42,0x49,0x4e,0x30,0x31]) // EVMBIN01
    static let version: UInt32 = 1

    static func write(_ records: [FileRecord], to url: URL) throws {
        var d = Data(); d.reserveCapacity(max(1024, records.count * 160))
        d.append(magic); append(version, to: &d); append(UInt64(records.count), to: &d)
        for r in records {
            append(r.id, to: &d)
            appendString(r.name, to: &d); appendString(r.normalizedName, to: &d)
            appendString(r.pinyinName, to: &d); appendString(r.pinyinCompact, to: &d); appendString(r.pinyinInitials, to: &d)
            appendString(r.path, to: &d); appendString(r.normalizedPath, to: &d); appendString(r.fileExtension, to: &d)
            d.append(r.isDirectory ? 1 : 0); append(r.size, to: &d)
            appendDate(r.createdAt, to: &d); appendDate(r.modifiedAt, to: &d)
        }
        try d.write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> [FileRecord] {
        let d = try Data(contentsOf: url, options: .mappedIfSafe)
        var r = Reader(data: d)
        guard try r.bytes(magic.count) == magic else { throw CodecError.badMagic }
        guard try r.u32() == version else { throw CodecError.badVersion }
        let count64 = try r.u64(); guard count64 <= UInt64(Int.max) else { throw CodecError.corrupt }
        let count = Int(count64); var out: [FileRecord] = []; out.reserveCapacity(count)
        for _ in 0..<count {
            let id = try r.u64(); let name = try r.string(); let normalizedName = try r.string()
            let pinyinName = try r.string(); let pinyinCompact = try r.string(); let pinyinInitials = try r.string()
            let path = try r.string(); let normalizedPath = try r.string(); let ext = try r.string()
            let isDirectory = try r.byte() != 0; let size = try r.u64(); let created = try r.date(); let modified = try r.date()
            out.append(FileRecord(id: id, name: name, normalizedName: normalizedName, pinyinName: pinyinName, pinyinCompact: pinyinCompact, pinyinInitials: pinyinInitials, path: path, normalizedPath: normalizedPath, fileExtension: ext, isDirectory: isDirectory, size: size, createdAt: created, modifiedAt: modified))
        }
        return out
    }

    static func append<T: FixedWidthInteger>(_ value: T, to d: inout Data) {
        var v = value.littleEndian; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) }
    }
    static func appendString(_ s: String, to d: inout Data) {
        let b = Data(s.utf8); append(UInt32(b.count), to: &d); d.append(b)
    }
    static func appendDate(_ date: Date?, to d: inout Data) {
        let v: Int64 = date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? Int64.min
        append(v, to: &d)
    }

    enum CodecError: Error { case badMagic, badVersion, corrupt }
    struct Reader {
        let data: Data; var offset = 0
        mutating func bytes(_ n: Int) throws -> Data { guard n >= 0, offset <= data.count - n else { throw CodecError.corrupt }; defer { offset += n }; return data.subdata(in: offset..<(offset+n)) }
        mutating func byte() throws -> UInt8 { guard offset < data.count else { throw CodecError.corrupt }; defer { offset += 1 }; return data[offset] }
        mutating func u32() throws -> UInt32 { try integer(UInt32.self) }
        mutating func u64() throws -> UInt64 { try integer(UInt64.self) }
        mutating func i64() throws -> Int64 { try integer(Int64.self) }
        mutating func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            let n = MemoryLayout<T>.size; guard offset <= data.count - n else { throw CodecError.corrupt }
            var v: T = 0
            _ = withUnsafeMutableBytes(of: &v) { dst in data.copyBytes(to: dst, from: offset..<(offset+n)) }
            offset += n; return T(littleEndian: v)
        }
        mutating func string() throws -> String {
            let n = Int(try u32()); let b = try bytes(n); guard let s = String(data: b, encoding: .utf8) else { throw CodecError.corrupt }; return s
        }
        mutating func date() throws -> Date? { let v = try i64(); return v == Int64.min ? nil : Date(timeIntervalSince1970: Double(v) / 1000) }
    }
}

public enum IndexPhase: String, Sendable { case idle, loading, scanning, building, saving, ready }
public struct IndexProgress: Sendable {
    public let phase: IndexPhase; public let completed: Int; public let total: Int?; public let currentPath: String
    public init(phase: IndexPhase, completed: Int, total: Int? = nil, currentPath: String = "") { self.phase = phase; self.completed = completed; self.total = total; self.currentPath = currentPath }
}
