import Foundation
public struct LiveUpdateStats:Sendable{public let anchors:Int;public let beforeCount:Int;public let afterCount:Int;public var delta:Int{afterCount-beforeCount}}
public actor IndexManager {
    private let engine=SearchEngine(); private var storage=IndexStorage(); private var recordsByPath:[String:FileRecord]=[:]
    private(set) public var isIndexing=false; private(set) public var indexedCount=0
    public init(){}
    public var storagePath:String{storage.baseURL.path}; public var storageSizeBytes:UInt64{storage.sizeBytes()}; public var storageExists:Bool{storage.exists}; public var persistedInfo:PersistedIndexInfo?{storage.info()}
    public func useStorageDirectory(_ url:URL){storage=IndexStorage(baseURL:url.standardizedFileURL)}
    @discardableResult public func loadPersisted(root:URL,progress:(@Sendable(IndexProgress)->Void)?=nil)async->Bool{progress?(IndexProgress(phase:.loading,completed:0,currentPath:"Loading records.bin"));guard let records=try?storage.load(root:root)else{return false};recordsByPath=Dictionary(uniqueKeysWithValues:records.map{($0.path,$0)});progress?(IndexProgress(phase:.building,completed:0,total:records.count,currentPath:"Loading persistent search postings"));if !engine.loadPersistentPostings(records:records,from:storage.postingsURL){engine.replaceIndex(with:records){d,t in progress?(IndexProgress(phase:.building,completed:d,total:t,currentPath:"Building postings (one-time migration)"))};try? engine.savePersistentPostings(to:storage.postingsURL)};indexedCount=records.count;progress?(IndexProgress(phase:.ready,completed:records.count,total:records.count,currentPath:storage.baseURL.path));return true}
    public func rebuild(root:URL,limit:Int?=nil,progress:(@Sendable(IndexProgress)->Void)?=nil)async{ await rebuild(roots:[root],limit:limit,progress:progress) }
    public func rebuild(roots:[URL],limit:Int?=nil,progress:(@Sendable(IndexProgress)->Void)?=nil)async{
        isIndexing=true
        let records=await Task.detached(priority:.userInitiated){
            let scanner=FileScanner(); var all:[FileRecord]=[]; var seen=Set<String>()
            for root in roots {
                let remaining=limit.map{max(0,$0-all.count)}; if remaining == 0 { break }
                let baseCount=all.count; let batch=scanner.scan(root:root,limit:remaining){c,path in progress?(IndexProgress(phase:.scanning,completed:baseCount+c,currentPath:path))}
                for r in batch where seen.insert(r.path).inserted { all.append(r) }
            }
            return all
        }.value
        recordsByPath=Dictionary(uniqueKeysWithValues:records.map{($0.path,$0)})
        engine.replaceIndex(with:records){d,t in progress?(IndexProgress(phase:.building,completed:d,total:t))}
        indexedCount=records.count; progress?(IndexProgress(phase:.saving,completed:records.count,total:records.count,currentPath:storage.baseURL.path))
        try?storage.save(records:records,roots:roots); try?engine.savePersistentPostings(to:storage.postingsURL)
        isIndexing=false; progress?(IndexProgress(phase:.ready,completed:records.count,total:records.count,currentPath:storage.baseURL.path))
    }
    public func clearPersisted(){try?storage.clear()}
    @discardableResult public func applyFileSystemChanges(paths:[String],roots:[URL])async->LiveUpdateStats{
        guard !paths.isEmpty else{return .init(anchors:0,beforeCount:indexedCount,afterCount:indexedCount)}
        let rootPaths=roots.map{$0.standardizedFileURL.path}; let before=recordsByPath.count
        let relevant=Array(Set(paths.map{URL(fileURLWithPath:$0).standardizedFileURL.path}.filter{p in rootPaths.contains{p==$0||p.hasPrefix($0+"/")}}))
        let snapshots=await Task.detached(priority:.utility){let scanner=FileScanner(),fm=FileManager.default;var out:[(String,[FileRecord])]=[];for path in relevant{var d:ObjCBool=false;if !fm.fileExists(atPath:path,isDirectory:&d){out.append((path,[]));continue};let u=URL(fileURLWithPath:path,isDirectory:d.boolValue);if d.boolValue{var rs:[FileRecord]=[];if let r=scanner.record(for:u){rs.append(r)};rs.append(contentsOf:scanner.scan(root:u));out.append((path,rs))}else{out.append((path,scanner.record(for:u).map{[$0]} ?? []))}};return out}.value
        var removed=Set<UInt64>(); var upserts:[FileRecord]=[]
        for(path,rs) in snapshots {
            // File-level FSEvents are the common case. Keep them O(1): never walk the
            // 1.6M-path dictionary just to update one created/renamed/deleted file.
            let oldAtPath = recordsByPath[path]
            let snapshotIsDirectory = rs.first(where: { $0.path == path })?.isDirectory == true
            let removedDirectory = rs.isEmpty && oldAtPath?.isDirectory == true
            if snapshotIsDirectory || removedDirectory {
                let prefix=path.hasSuffix("/") ? path:path+"/"
                let oldKeys=recordsByPath.keys.filter{$0==path||$0.hasPrefix(prefix)}
                for k in oldKeys { if let old=recordsByPath.removeValue(forKey:k){removed.insert(old.id)} }
            } else if let old=recordsByPath.removeValue(forKey:path) {
                removed.insert(old.id)
            }
            for r in rs { recordsByPath[r.path]=r; upserts.append(r); removed.remove(r.id) }
        }
        engine.applyDelta(removedIDs:removed,upserts:upserts); indexedCount=recordsByPath.count
        return .init(anchors:relevant.count,beforeCount:before,afterCount:indexedCount)
    }
    @discardableResult public func applyFileSystemChanges(paths:[String],root:URL)async->LiveUpdateStats{ await applyFileSystemChanges(paths:paths,roots:[root]) }
    public func search(_ query:String,limit:Int=100)async->(results:[SearchResult],diagnostics:SearchDiagnostics){let r=engine.search(query,limit:limit);return(r,engine.lastDiagnostics)}
    private func reconciliationAnchors(for paths:[String],rootPath:String)->[String]{let fm=FileManager.default;var a=Set<String>();for raw in paths{let s=URL(fileURLWithPath:raw).standardizedFileURL.path;guard s==rootPath||s.hasPrefix(rootPath+"/")else{continue};var d:ObjCBool=false;if fm.fileExists(atPath:s,isDirectory:&d),d.boolValue{a.insert(s)}else{a.insert(URL(fileURLWithPath:s).deletingLastPathComponent().standardizedFileURL.path)}};let sorted=a.sorted{$0.count<$1.count};var c:[String]=[];for x in sorted{if c.contains(where:{x==$0||x.hasPrefix($0+"/")}){continue};c.append(x)};return c}
    private func removeSubtree(_ path:String){let p=path.hasSuffix("/") ? path:path+"/";for k in recordsByPath.keys.filter({$0==path||$0.hasPrefix(p)}){recordsByPath.removeValue(forKey:k)}}
}
