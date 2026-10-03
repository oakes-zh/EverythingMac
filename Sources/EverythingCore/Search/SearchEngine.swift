import Foundation

public struct SearchResult: Identifiable, Sendable {
    public let record: FileRecord
    public let score: Int
    public var id: UInt64 { record.id }
}

public struct SearchDiagnostics: Sendable {
    public let totalEntries: Int
    public let candidateCount: Int
    public let examinedCount: Int
    public let truncated: Bool
    public let route: String
    public let lookupMS: Double
    public let matchMS: Double
    public let rankMS: Double
    public let totalMS: Double
    public let fullScan: Bool
}

/// Indexed, filename-only search engine. No file contents are indexed or searched.
/// Normal query paths are bounded: they never intentionally walk the full record set.
public final class SearchEngine: @unchecked Sendable {
    private var records: [FileRecord] = []
    private var exact: [String: [Int]] = [:]
    private var prefix1: [String: [Int]] = [:]
    private var prefix2: [String: [Int]] = [:]
    private var grams: [String: [Int]] = [:]
    private var charIndex: [Character: [Int]] = [:]
    private var extensionIndex: [String: [Int]] = [:]
    private var active: [Bool] = []
    private var slotByID: [UInt64: Int] = [:]
    public private(set) var lastDiagnostics = SearchDiagnostics(totalEntries: 0, candidateCount: 0, examinedCount: 0, truncated: false, route: "idle", lookupMS: 0, matchMS: 0, rankMS: 0, totalMS: 0, fullScan: false)
    private let maxCandidates = 20_000

    public init(records: [FileRecord] = []) { replaceIndex(with: records) }
    public var count: Int { active.isEmpty ? records.count : active.lazy.filter { $0 }.count }

    /// v0.3.1: restore the already-built posting tables instead of rebuilding them
    /// from every filename on every launch. Records remain the source of result metadata.
    @discardableResult
    public func loadPersistentPostings(records: [FileRecord], from url: URL) -> Bool {
        do {
            let snapshot = try PersistentPostingCodec.read(from: url)
            guard snapshot.recordCount == records.count else { return false }
            self.records = records
            self.exact = snapshot.exact
            self.prefix1 = snapshot.prefix1
            self.prefix2 = snapshot.prefix2
            self.grams = snapshot.grams
            self.charIndex = snapshot.charIndex
            self.extensionIndex = snapshot.extensionIndex
            self.active = Array(repeating: true, count: records.count)
            self.slotByID = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($0.element.id, $0.offset) })
            return true
        } catch { return false }
    }

    public func savePersistentPostings(to url: URL) throws {
        try PersistentPostingCodec.write(
            recordCount: records.count,
            exact: exact, prefix1: prefix1, prefix2: prefix2,
            grams: grams, charIndex: charIndex, extensionIndex: extensionIndex,
            to: url
        )
    }

    public func replaceIndex(with records: [FileRecord], progress: (@Sendable (Int, Int) -> Void)? = nil) {
        self.records = records
        self.active = Array(repeating: true, count: records.count)
        self.slotByID = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($0.element.id, $0.offset) })
        exact.removeAll(keepingCapacity: true); prefix1.removeAll(keepingCapacity: true); prefix2.removeAll(keepingCapacity: true)
        grams.removeAll(keepingCapacity: true); charIndex.removeAll(keepingCapacity: true); extensionIndex.removeAll(keepingCapacity: true)
        for (i, record) in records.enumerated() {
            if i % 2000 == 0 { progress?(i, records.count) }
            if !record.isDirectory, !record.fileExtension.isEmpty { extensionIndex[record.fileExtension, default: []].append(i) }
            var aliases = [record.normalizedName]
            if !record.pinyinCompact.isEmpty { aliases.append(record.pinyinCompact) }
            if !record.pinyinInitials.isEmpty { aliases.append(record.pinyinInitials) }
            var seenAliases = Set<String>()
            for alias in aliases where !alias.isEmpty && seenAliases.insert(alias).inserted {
                exact[alias, default: []].append(i)
                let chars = Array(alias)
                if let first = chars.first { prefix1[String(first), default: []].append(i); charIndex[first, default: []].append(i) }
                if chars.count >= 2 { prefix2[String(chars[0...1]), default: []].append(i) }
                if chars.count >= 2 { // 2-grams improve Chinese two-character queries such as “模型”
                    var seen = Set<String>()
                    for start in 0...(chars.count - 2) {
                        let gram = String(chars[start...start+1])
                        if seen.insert(gram).inserted { grams["2:" + gram, default: []].append(i) }
                    }
                }
                if chars.count >= 3 {
                    var seen = Set<String>()
                    for start in 0...(chars.count - 3) {
                        let gram = String(chars[start...start+2])
                        if seen.insert(gram).inserted { grams["3:" + gram, default: []].append(i) }
                    }
                }
            }
        }
        prefix1 = prefix1.mapValues(uniqueSorted); prefix2 = prefix2.mapValues(uniqueSorted)
        grams = grams.mapValues(uniqueSorted); charIndex = charIndex.mapValues(uniqueSorted); extensionIndex = extensionIndex.mapValues(uniqueSorted)
        progress?(records.count, records.count)
    }

    /// Applies a small filesystem delta without rebuilding the million-record search index.
    /// Removed slots become tombstones; new/changed records are appended and indexed in-place.
    public func applyDelta(removedIDs: Set<UInt64>, upserts: [FileRecord]) {
        for id in removedIDs {
            guard let slot = slotByID.removeValue(forKey: id), slot < active.count, active[slot] else { continue }
            active[slot] = false
            removeRecordFromPostings(records[slot], slot: slot)
        }
        for record in upserts {
            if let old = slotByID.removeValue(forKey: record.id), old < active.count, active[old] {
                active[old] = false
                removeRecordFromPostings(records[old], slot: old)
            }
            let slot = records.count
            records.append(record); active.append(true); slotByID[record.id] = slot
            addRecordToPostings(record, slot: slot)
        }
    }

    private func addRecordToPostings(_ record: FileRecord, slot: Int) {
        if !record.isDirectory, !record.fileExtension.isEmpty { insertSortedUnique(slot, into: &extensionIndex[record.fileExtension, default: []]) }
        var aliases = [record.normalizedName]
        if !record.pinyinCompact.isEmpty { aliases.append(record.pinyinCompact) }
        if !record.pinyinInitials.isEmpty { aliases.append(record.pinyinInitials) }
        var seenAliases = Set<String>()
        for alias in aliases where !alias.isEmpty && seenAliases.insert(alias).inserted {
            insertSortedUnique(slot, into: &exact[alias, default: []])
            let chars = Array(alias)
            if let first = chars.first { insertSortedUnique(slot, into: &prefix1[String(first), default: []]); insertSortedUnique(slot, into: &charIndex[first, default: []]) }
            if chars.count >= 2 { insertSortedUnique(slot, into: &prefix2[String(chars[0...1]), default: []]) }
            if chars.count >= 2 { var seen=Set<String>(); for start in 0...(chars.count-2) { let k="2:"+String(chars[start...start+1]); if seen.insert(k).inserted { insertSortedUnique(slot, into: &grams[k, default: []]) } } }
            if chars.count >= 3 { var seen=Set<String>(); for start in 0...(chars.count-3) { let k="3:"+String(chars[start...start+2]); if seen.insert(k).inserted { insertSortedUnique(slot, into: &grams[k, default: []]) } } }
        }
    }

    private func removeRecordFromPostings(_ record: FileRecord, slot: Int) {
        if !record.isDirectory, !record.fileExtension.isEmpty { removeSorted(slot, from: &extensionIndex[record.fileExtension]) }
        var aliases = [record.normalizedName]
        if !record.pinyinCompact.isEmpty { aliases.append(record.pinyinCompact) }
        if !record.pinyinInitials.isEmpty { aliases.append(record.pinyinInitials) }
        var seenAliases=Set<String>()
        for alias in aliases where !alias.isEmpty && seenAliases.insert(alias).inserted {
            removeSorted(slot, from: &exact[alias]); let chars=Array(alias)
            if let first=chars.first { removeSorted(slot, from:&prefix1[String(first)]); removeSorted(slot, from:&charIndex[first]) }
            if chars.count >= 2 { removeSorted(slot, from:&prefix2[String(chars[0...1])]) }
            if chars.count >= 2 { var seen=Set<String>(); for start in 0...(chars.count-2) { let k="2:"+String(chars[start...start+1]); if seen.insert(k).inserted { removeSorted(slot, from:&grams[k]) } } }
            if chars.count >= 3 { var seen=Set<String>(); for start in 0...(chars.count-3) { let k="3:"+String(chars[start...start+2]); if seen.insert(k).inserted { removeSorted(slot, from:&grams[k]) } } }
        }
    }
    private func insertSortedUnique(_ value:Int, into a: inout [Int]) { if a.last == value { return }; if a.last.map({$0 < value}) ?? true { a.append(value); return }; let i=a.partitioningIndex{$0 >= value}; if i==a.count || a[i] != value { a.insert(value,at:i) } }
    private func removeSorted(_ value:Int, from a: inout [Int]?) { guard var x=a else{return}; if let i=x.firstIndex(of:value){x.remove(at:i)}; a = x.isEmpty ? nil : x }

    public func search(_ rawQuery: String, limit: Int = 100) -> [SearchResult] {
        let parsed = QueryParser.parse(rawQuery)
        var text = parsed.text
        var implicitExtension: String? = nil
        if parsed.fileExtension == nil, text.hasPrefix("."), !text.dropFirst().contains(" ") {
            let ext = String(text.dropFirst()).lowercased()
            if !ext.isEmpty { implicitExtension = ext; text = "" }
        }
        let clock = ContinuousClock(); let totalStart = clock.now
        let lookupStart = clock.now
        let selection = candidateIndices(for: text, explicitExtension: parsed.fileExtension ?? implicitExtension)
        let lookupMS = milliseconds(lookupStart.duration(to: clock.now))
        let matchStart = clock.now
        var out: [SearchResult] = []; out.reserveCapacity(min(limit, 128)); var examined = 0
        for i in selection.ids.prefix(maxCandidates) {
            if Task.isCancelled { break }
            guard i < active.count, active[i] else { continue }
            examined += 1
            let record = records[i]
            var q = parsed
            if let implicitExtension { q.fileExtension = implicitExtension }
            guard passesFilters(record, query: q) else { continue }
            let score: Int
            if text.isEmpty { score = 8_000 }
            else if let s = nameScore(text, record: record) { score = s }
            else { continue }
            out.append(SearchResult(record: record, score: score))
            // Pure extension queries are guaranteed matches. Once we have enough rows,
            // stop instead of running ranking work across every file with that extension.
            if text.isEmpty, parsed.pathContains == nil, parsed.kind == nil, parsed.minimumSize == nil, parsed.maximumSize == nil, parsed.modifiedAfter == nil, out.count >= limit { break }
        }
        let matchMS = milliseconds(matchStart.duration(to: clock.now))
        let rankStart = clock.now
        // Candidate retrieval already provides a bounded set. Sort once rather than doing
        // O(candidates × limit) bounded insertion with expensive localized path compares.
        out.sort(by: resultOrder)
        if out.count > limit { out.removeSubrange(limit..<out.count) }
        let rankMS = milliseconds(rankStart.duration(to: clock.now))
        let totalMS = milliseconds(totalStart.duration(to: clock.now))
        let fullScan = examined >= records.count && records.count > 10_000
        lastDiagnostics = SearchDiagnostics(totalEntries: records.count, candidateCount: selection.ids.count, examinedCount: examined, truncated: selection.ids.count > maxCandidates, route: selection.route, lookupMS: lookupMS, matchMS: matchMS, rankMS: rankMS, totalMS: totalMS, fullScan: fullScan)
        return out
    }

    private func candidateIndices(for query: String, explicitExtension: String?) -> (ids:[Int], route:String) {
        if let ext = explicitExtension { return (extensionIndex[ext] ?? [], "extension") }
        guard !query.isEmpty else { return ([], "empty") }
        if let ids = exact[query] { return (ids, "exact") }
        if query.contains(" ") {
            let tokens = query.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            guard !tokens.isEmpty else { return ([], "tokens-empty") }
            let lists = tokens.compactMap { token -> [Int]? in
                guard let first = token.first else { return nil }
                return charIndex[first]
            }.sorted { $0.count < $1.count }
            guard var current = lists.first else { return ([], "tokens-none") }
            for list in lists.dropFirst() { current = intersectSorted(current, list, cap: maxCandidates + 1) }
            return (Array(current.prefix(maxCandidates + 1)), "tokens")
        }
        let chars = Array(query)
        if chars.count == 1 { return (Array((prefix1[query] ?? []).prefix(maxCandidates + 1)), "prefix-1") }
        if chars.count == 2 {
            if let ids = grams["2:" + query] { return (Array(ids.prefix(maxCandidates + 1)), "bigram") }
            return (Array((prefix2[query] ?? []).prefix(maxCandidates + 1)), "prefix-2")
        }
        var lists:[[Int]]=[]
        for start in 0...(chars.count-3) {
            let gram="3:"+String(chars[start...start+2])
            guard let ids=grams[gram] else { return ([], "no-gram") }
            lists.append(ids)
        }
        lists.sort{$0.count<$1.count}; guard var current=lists.first else{return([],"none")}
        for list in lists.dropFirst(){current=intersectSorted(current,list,cap:maxCandidates+1);if current.isEmpty{break}}
        return (Array(current.prefix(maxCandidates+1)), "trigram")
    }

    private func nameScore(_ query:String, record:FileRecord)->Int? {
        if query.contains(" ") {
            let qs = query.split(separator: " ").map(String.init)
            let words = record.normalizedName.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            var total = 0
            for q in qs {
                guard let best = words.compactMap({ boundedSubsequenceScore(q, $0) }).max() else { return nil }
                total += best
            }
            return 7_200 + total
        }
        if let s=strictScore(query,record.normalizedName){return s}
        if !record.pinyinCompact.isEmpty { if record.pinyinCompact==query{return 6800}; if record.pinyinCompact.hasPrefix(query){return 6500}; if query.count>=3 && record.pinyinCompact.contains(query){return 6100} }
        if !record.pinyinInitials.isEmpty { if record.pinyinInitials==query{return 6200}; if record.pinyinInitials.hasPrefix(query){return 6000} }
        return nil
    }
    private func boundedSubsequenceScore(_ q:String,_ c:String)->Int? {
        let qa=Array(q),ca=Array(c); guard !qa.isEmpty else{return nil}; var qi=0
        for ch in ca where qi<qa.count { if ch==qa[qi]{qi += 1} }
        return qi==qa.count ? max(1, 500-(ca.count-qa.count)*4) : nil
    }
    private func strictScore(_ q:String,_ c:String)->Int? {
        if c==q{return 10000}; if c.hasPrefix(q){return 9000-min(c.count-q.count,700)}
        if let r=c.range(of:q){let offset=c.distance(from:c.startIndex,to:r.lowerBound);return 7000-min(offset*8,700)}
        return nil // intentionally no unbounded subsequence fuzzy in the hot path
    }
    private func passesFilters(_ r:FileRecord,query q:SearchQuery)->Bool {
        if let e=q.fileExtension,r.fileExtension != e{return false}; if let p=q.pathContains,!r.normalizedPath.contains(p){return false}
        if let x=q.minimumSize,r.size<=x{return false}; if let x=q.maximumSize,r.size>=x{return false}; if let x=q.modifiedAfter,(r.modifiedAt ?? .distantPast)<x{return false}
        if let k=q.kind { switch k { case .folder:if !r.isDirectory{return false};case .file:if r.isDirectory{return false};case .image:if !["png","jpg","jpeg","gif","webp","heic","tiff","svg"].contains(r.fileExtension){return false};case .video:if !["mp4","mov","m4v","avi","mkv","webm"].contains(r.fileExtension){return false};case .audio:if !["mp3","m4a","wav","aac","flac","aiff"].contains(r.fileExtension){return false};case .document:if !["pdf","doc","docx","txt","md","rtf","pages","xls","xlsx","ppt","pptx"].contains(r.fileExtension){return false} } }
        return true
    }
    private func milliseconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1_000_000_000_000_000
    }
    private func uniqueSorted(_ a:[Int])->[Int]{Array(Set(a)).sorted()}
    private func intersectSorted(_ a:[Int],_ b:[Int],cap:Int)->[Int]{var i=0,j=0,o:[Int]=[];o.reserveCapacity(min(min(a.count,b.count),cap));while i<a.count&&j<b.count&&o.count<cap{if a[i]==b[j]{o.append(a[i]);i+=1;j+=1}else if a[i]<b[j]{i+=1}else{j+=1}};return o}
    private func resultOrder(_ a:SearchResult,_ b:SearchResult)->Bool{if a.score != b.score{return a.score>b.score};if a.record.name.count != b.record.name.count{return a.record.name.count<b.record.name.count};if a.record.isDirectory != b.record.isDirectory{return a.record.isDirectory};return a.record.path.localizedStandardCompare(b.record.path) == .orderedAscending}
}


private enum PersistentPostingCodec {
    static let magic = Data([0x45,0x56,0x4d,0x50,0x4f,0x53,0x54,0x31]) // EVMPOST1
    static let version: UInt32 = 1
    struct Snapshot {
        let recordCount: Int
        let exact, prefix1, prefix2, grams, extensionIndex: [String:[Int]]
        let charIndex: [Character:[Int]]
    }
    enum CodecError: Error { case corrupt, badMagic, badVersion }

    static func write(recordCount: Int, exact:[String:[Int]], prefix1:[String:[Int]], prefix2:[String:[Int]], grams:[String:[Int]], charIndex:[Character:[Int]], extensionIndex:[String:[Int]], to url:URL) throws {
        var d=Data(); d.reserveCapacity(max(4096, recordCount * 32)); d.append(magic); append(version,to:&d); append(UInt64(recordCount),to:&d)
        writeMap(exact,to:&d); writeMap(prefix1,to:&d); writeMap(prefix2,to:&d); writeMap(grams,to:&d)
        writeMap(Dictionary(uniqueKeysWithValues: charIndex.map { (String($0.key), $0.value) }),to:&d)
        writeMap(extensionIndex,to:&d)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try d.write(to:url,options:.atomic)
    }
    static func read(from url:URL) throws -> Snapshot {
        let d=try Data(contentsOf:url,options:.mappedIfSafe); var r=Reader(data:d)
        guard try r.bytes(magic.count)==magic else { throw CodecError.badMagic }
        guard try r.u32()==version else { throw CodecError.badVersion }
        let n=try r.u64(); guard n <= UInt64(Int.max) else { throw CodecError.corrupt }
        let exact=try r.map(), p1=try r.map(), p2=try r.map(), grams=try r.map(), chars=try r.map(), ext=try r.map()
        var ci:[Character:[Int]]=[:]; ci.reserveCapacity(chars.count)
        for (k,v) in chars { guard k.count==1, let c=k.first else { throw CodecError.corrupt }; ci[c]=v }
        return Snapshot(recordCount:Int(n),exact:exact,prefix1:p1,prefix2:p2,grams:grams,extensionIndex:ext,charIndex:ci)
    }
    static func writeMap(_ m:[String:[Int]],to d:inout Data) {
        append(UInt32(m.count),to:&d)
        for (k,v) in m { writeString(k,to:&d); append(UInt32(v.count),to:&d); for x in v { append(UInt32(x),to:&d) } }
    }
    static func writeString(_ s:String,to d:inout Data) { let b=Data(s.utf8); append(UInt32(b.count),to:&d); d.append(b) }
    static func append<T:FixedWidthInteger>(_ x:T,to d:inout Data) { var v=x.littleEndian; withUnsafeBytes(of:&v){d.append(contentsOf:$0)} }
    struct Reader {
        let data:Data; var offset=0
        mutating func bytes(_ n:Int)throws->Data { guard n>=0,offset<=data.count-n else{throw CodecError.corrupt};defer{offset+=n};return data.subdata(in:offset..<offset+n) }
        mutating func u32()throws->UInt32 { try integer(UInt32.self) }
        mutating func u64()throws->UInt64 { try integer(UInt64.self) }
        mutating func integer<T:FixedWidthInteger>(_ t:T.Type)throws->T { let n=MemoryLayout<T>.size;guard offset<=data.count-n else{throw CodecError.corrupt};var v:T=0;_=withUnsafeMutableBytes(of:&v){data.copyBytes(to:$0,from:offset..<offset+n)};offset+=n;return T(littleEndian:v) }
        mutating func string()throws->String { let n=Int(try u32());let b=try bytes(n);guard let s=String(data:b,encoding:.utf8)else{throw CodecError.corrupt};return s }
        mutating func map()throws->[String:[Int]] { let count=Int(try u32());var m:[String:[Int]]=[:];m.reserveCapacity(count);for _ in 0..<count{let k=try string();let n=Int(try u32());var a:[Int]=[];a.reserveCapacity(n);for _ in 0..<n{a.append(Int(try u32()))};m[k]=a};return m }
    }
}

private extension Array where Element == Int {
    func partitioningIndex(where predicate:(Int)->Bool)->Int { var l=0,r=count; while l<r { let m=(l+r)/2; if predicate(self[m]) { r=m } else { l=m+1 } }; return l }
}
