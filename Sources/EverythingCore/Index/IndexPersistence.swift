import Foundation
public struct PersistedIndexInfo: Codable, Sendable { public let version:Int; public let rootPath:String; public let itemCount:Int; public let savedAt:Date }
public struct IndexStorage: Sendable {
    public let baseURL:URL; public var recordsURL:URL{baseURL.appendingPathComponent("index/records.plist")}; public var stateURL:URL{baseURL.appendingPathComponent("state/index-state.json")}
    public init(baseURL:URL?=nil){if let baseURL{self.baseURL=baseURL}else{let a=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!;self.baseURL=a.appendingPathComponent("EverythingMac",isDirectory:true)}}
    public var exists:Bool{FileManager.default.fileExists(atPath:recordsURL.path)}
    public func prepare()throws{let f=FileManager.default;try f.createDirectory(at:recordsURL.deletingLastPathComponent(),withIntermediateDirectories:true);try f.createDirectory(at:stateURL.deletingLastPathComponent(),withIntermediateDirectories:true)}
    public func save(records:[FileRecord],root:URL)throws{try prepare();let e=PropertyListEncoder();e.outputFormat = .binary;try e.encode(records).write(to:recordsURL,options:.atomic);let info=PersistedIndexInfo(version:2,rootPath:root.standardizedFileURL.path,itemCount:records.count,savedAt:Date());let j=JSONEncoder();j.outputFormatting=[.prettyPrinted,.sortedKeys];j.dateEncodingStrategy = .iso8601;try j.encode(info).write(to:stateURL,options:.atomic)}
    public func load(root:URL)throws->[FileRecord]?{guard exists else{return nil};return try PropertyListDecoder().decode([FileRecord].self,from:Data(contentsOf:recordsURL))}
    public func info()->PersistedIndexInfo?{guard let d=try? Data(contentsOf:stateURL) else{return nil};let j=JSONDecoder();j.dateDecodingStrategy = .iso8601;return try? j.decode(PersistedIndexInfo.self,from:d)}
    public func clear()throws{if FileManager.default.fileExists(atPath:baseURL.path){try FileManager.default.removeItem(at:baseURL)}}
    public func sizeBytes()->UInt64{let f=FileManager.default;guard let e=f.enumerator(at:baseURL,includingPropertiesForKeys:[.fileSizeKey])else{return 0};var t:UInt64=0;for case let u as URL in e{if let n=try?u.resourceValues(forKeys:[.fileSizeKey]).fileSize{t += UInt64(max(0,n))}};return t}
}
public enum IndexPhase:String,Sendable{case idle,loading,scanning,building,saving,ready}
public struct IndexProgress:Sendable{public let phase:IndexPhase;public let completed:Int;public let total:Int?;public let currentPath:String;public init(phase:IndexPhase,completed:Int,total:Int?=nil,currentPath:String=""){self.phase=phase;self.completed=completed;self.total=total;self.currentPath=currentPath}}
