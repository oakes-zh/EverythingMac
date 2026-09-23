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
    public private(set) var lastDiagnostics = SearchDiagnostics(totalEntries: 0, candidateCount: 0, examinedCount: 0, truncated: false, route: "idle")
    private let maxCandidates = 20_000

    public init(records: [FileRecord] = []) { replaceIndex(with: records) }
    public var count: Int { records.count }

    public func replaceIndex(with records: [FileRecord], progress: (@Sendable (Int, Int) -> Void)? = nil) {
        self.records = records
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

    public func search(_ rawQuery: String, limit: Int = 100) -> [SearchResult] {
        let parsed = QueryParser.parse(rawQuery)
        var text = parsed.text
        var implicitExtension: String? = nil
        if parsed.fileExtension == nil, text.hasPrefix("."), !text.dropFirst().contains(" ") {
            let ext = String(text.dropFirst()).lowercased()
            if !ext.isEmpty { implicitExtension = ext; text = "" }
        }
        let selection = candidateIndices(for: text, explicitExtension: parsed.fileExtension ?? implicitExtension)
        var out: [SearchResult] = []; out.reserveCapacity(min(limit, 128)); var examined = 0
        for i in selection.ids.prefix(maxCandidates) {
            if Task.isCancelled { break }
            examined += 1
            let record = records[i]
            var q = parsed
            if let implicitExtension { q.fileExtension = implicitExtension }
            guard passesFilters(record, query: q) else { continue }
            let score: Int
            if text.isEmpty { score = 8_000 }
            else if let s = nameScore(text, record: record) { score = s }
            else { continue }
            insertBounded(SearchResult(record: record, score: score), into: &out, limit: limit)
        }
        out.sort(by: resultOrder)
        lastDiagnostics = SearchDiagnostics(totalEntries: records.count, candidateCount: selection.ids.count, examinedCount: examined, truncated: selection.ids.count > maxCandidates, route: selection.route)
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
    private func uniqueSorted(_ a:[Int])->[Int]{Array(Set(a)).sorted()}
    private func intersectSorted(_ a:[Int],_ b:[Int],cap:Int)->[Int]{var i=0,j=0,o:[Int]=[];o.reserveCapacity(min(min(a.count,b.count),cap));while i<a.count&&j<b.count&&o.count<cap{if a[i]==b[j]{o.append(a[i]);i+=1;j+=1}else if a[i]<b[j]{i+=1}else{j+=1}};return o}
    private func insertBounded(_ r:SearchResult,into top:inout[SearchResult],limit:Int){guard limit>0 else{return};if top.count<limit{top.append(r);return};guard let w=top.indices.min(by:{resultOrder(top[$0],top[$1])})else{return};if resultOrder(r,top[w]){top[w]=r}}
    private func resultOrder(_ a:SearchResult,_ b:SearchResult)->Bool{if a.score != b.score{return a.score>b.score};if a.record.name.count != b.record.name.count{return a.record.name.count<b.record.name.count};if a.record.isDirectory != b.record.isDirectory{return a.record.isDirectory};return a.record.path.localizedStandardCompare(b.record.path) == .orderedAscending}
}
