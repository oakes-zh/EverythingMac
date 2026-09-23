#if os(macOS)
import SwiftUI
import AppKit
import Carbon
import CoreServices
import EverythingCore

extension Notification.Name {
    static let everythingFocusSearch = Notification.Name("EverythingMac.focusSearch")
    static let everythingMoveSelection = Notification.Name("EverythingMac.moveSelection")
    static let everythingOpenSelection = Notification.Name("EverythingMac.openSelection")
    static let everythingRevealSelection = Notification.Name("EverythingMac.revealSelection")
    static let everythingQuickLookSelection = Notification.Name("EverythingMac.quickLookSelection")
    static let everythingEscape = Notification.Name("EverythingMac.escape")
    static let everythingToggleWindow = Notification.Name("EverythingMac.toggleWindow")
}

@main
struct EverythingMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = SearchModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var localKeyMonitor: Any?
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installKeyboardHandling()
        hotKey = GlobalHotKey()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleWindow),
            name: .everythingToggleWindow,
            object: nil
        )

        // SwiftUI's first window is normally available by the end of this run-loop turn.
        // Hop once on the MainActor so the window can finish being created before we focus it.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.showWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installKeyboardHandling() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "f" {
                NotificationCenter.default.post(name: .everythingFocusSearch, object: nil)
                return nil
            }
            if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "y" {
                NotificationCenter.default.post(name: .everythingQuickLookSelection, object: nil)
                return nil
            }

            switch event.keyCode {
            case 125: // down
                NotificationCenter.default.post(name: .everythingMoveSelection, object: 1)
                return nil
            case 126: // up
                NotificationCenter.default.post(name: .everythingMoveSelection, object: -1)
                return nil
            case 36, 76: // return / keypad enter
                NotificationCenter.default.post(
                    name: flags.contains(.command) ? .everythingRevealSelection : .everythingOpenSelection,
                    object: nil
                )
                return nil
            case 53: // escape
                NotificationCenter.default.post(name: .everythingEscape, object: nil)
                return nil
            default:
                return event
            }
        }
    }

    @objc private func handleToggleWindow() {
        toggleWindow()
    }

    private func toggleWindow() {
        guard let window = NSApp.windows.first else { return }
        if window.isVisible && NSApp.isActive {
            window.orderOut(nil)
        } else {
            showWindow()
        }
    }

    private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.windows.first else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        NotificationCenter.default.post(name: .everythingFocusSearch, object: nil)
    }
}

/// Global Option+Space hotkey, implemented through Carbon so it does not need
/// Accessibility permission just to summon the search window.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ -> OSStatus in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .everythingToggleWindow, object: nil)
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )

        let hotKeyID = EventHotKeyID(signature: 0x45564D43, id: 1) // EVMC
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

final class FSEventMonitor {
    private var stream: FSEventStreamRef?
    private let path: String
    private let callback: @Sendable ([String]) -> Void

    init(path: String, callback: @escaping @Sendable ([String]) -> Void) {
        self.path = path
        self.callback = callback
    }

    func start() {
        guard stream == nil else { return }
        let unmanagedSelf = Unmanaged.passUnretained(self)
        var context = FSEventStreamContext(
            version: 0,
            info: unmanagedSelf.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, eventPaths, _, _ in
                guard let info, count > 0 else { return }
                let monitor = Unmanaged<FSEventMonitor>.fromOpaque(info).takeUnretainedValue()

                // With kFSEventStreamCreateFlagUseCFTypes, eventPaths is a CFArray<CFString>.
                // Do not reinterpret it as a C string array; doing so can silently drop events.
                let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
                let nsPaths = cfPaths as NSArray
                var paths: [String] = []
                paths.reserveCapacity(count)
                for item in nsPaths {
                    if let path = item as? String { paths.append(path) }
                }

                // We intentionally do not filter by item flags here. FSEvents can emit
                // coalesced/root/drop-related events whose flag combinations differ by OS.
                // Any touched path is cheap to reconcile, and this is much safer for a search index.
                if !paths.isEmpty { monitor.callback(paths) }
            },
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.12,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagWatchRoot
            )
        )

        guard let stream else { return }
        FSEventStreamSetDispatchQueue(
            stream,
            DispatchQueue(label: "EverythingMac.FSEvents", qos: .utility)
        )
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}

@MainActor
@Observable
final class SearchModel {
    var query=""; var results:[SearchResult]=[]; var selectedID:UInt64?; var status="Choose an existing index or build a new one"
    var searchLatencyMS:Double=0; var indexPhase:IndexPhase = .idle; var progressCompleted=0; var progressTotal:Int?; var currentIndexPath=""
    var indexStoragePath=""; var indexStorageBytes:UInt64=0; var showIndexDetails=false; var sessionStarted=false; var searchReady=false
    var candidateCount=0; var examinedCount=0; var searchRoute="idle"; var candidateTruncated=false
    private let index=IndexManager(); private var searchTask:Task<Void,Never>?; private var queryGeneration=0
    private var fileEventTask:Task<Void,Never>?; private var monitor:FSEventMonitor?; private var pendingFileEventPaths=Set<String>(); private var liveChangeBatches=0

    init(){ Task { await inspectDefaultIndex() } }
    var progressFraction:Double?{guard let t=progressTotal,t>0 else{return nil};return min(1,Double(progressCompleted)/Double(t))}
    var isIndexBusy:Bool{sessionStarted && indexPhase != .ready && indexPhase != .idle}

    func inspectDefaultIndex() async {
        indexStoragePath=await index.storagePath; indexStorageBytes=await index.storageSizeBytes
        if let info=await index.persistedInfo { progressCompleted=info.itemCount; status="Existing index • \(info.itemCount.formatted()) items • click Load Existing Index" }
    }
    func loadExistingIndex() { Task { await loadSelectedIndex() } }
    private func loadSelectedIndex() async {
        sessionStarted=true; searchReady=false; results=[]
        let root=FileManager.default.homeDirectoryForCurrentUser
        let ok=await index.loadPersisted(root:root,progress:progressHandler)
        guard ok else { indexPhase = .idle; status="No valid index found at selected location"; sessionStarted=false; return }
        let count=await index.indexedCount; indexStorageBytes=await index.storageSizeBytes; indexStoragePath=await index.storagePath
        searchReady=true; status="Search ready • \(count.formatted()) items • filesystem rescan off (debug)"
    }
    func chooseIndexFolder(){
        let panel=NSOpenPanel(); panel.canChooseDirectories=true; panel.canChooseFiles=false; panel.allowsMultipleSelection=false; panel.prompt="Use Index"
        if panel.runModal() == NSApplication.ModalResponse.OK, let u = panel.url { Task { await index.useStorageDirectory(u); indexStoragePath=await index.storagePath; indexStorageBytes=await index.storageSizeBytes; await inspectDefaultIndex() } }
    }
    func buildNewIndex(){ sessionStarted=true; Task { await rebuild() } }
    func rebuild() async { let root=FileManager.default.homeDirectoryForCurrentUser;searchReady=false;results=[];await index.rebuild(root:root,progress:progressHandler);let c=await index.indexedCount;indexStoragePath=await index.storagePath;indexStorageBytes=await index.storageSizeBytes;searchReady=true;status="Search ready • \(c.formatted()) items • filesystem rescan off (debug)" }
    nonisolated private func progressHandler(_ p:IndexProgress){Task{@MainActor[weak self] in self?.applyProgress(p)}}
    private func applyProgress(_ p:IndexProgress){indexPhase=p.phase;progressCompleted=p.completed;progressTotal=p.total;currentIndexPath=p.currentPath;switch p.phase{case .idle:status="Idle";case .loading:status="Loading records…";case .scanning:status="Scanning… \(p.completed.formatted()) items";case .building:status="Building search engine… \(p.completed.formatted()) / \((p.total ?? 0).formatted())";case .saving:status="Saving index…";case .ready:status="Search ready • \(p.completed.formatted()) items"}}
    func openIndexFolder(){guard !indexStoragePath.isEmpty else{return};NSWorkspace.shared.open(URL(fileURLWithPath:indexStoragePath,isDirectory:true))}
    func rebuildRequested(){sessionStarted=true;Task{await rebuild()}}
    func clearAndRebuild(){sessionStarted=true;Task{await index.clearPersisted();await rebuild()}}

    func queryChanged(){
        queryGeneration += 1; let generation=queryGeneration; searchTask?.cancel()
        guard searchReady else { results=[]; return }
        searchTask=Task { try? await Task.sleep(for:.milliseconds(35)); guard !Task.isCancelled,generation==self.queryGeneration else{return}; await self.performSearch(generation:generation) }
    }
    func performSearch(generation:Int?=nil) async {
        let value=query; if value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { results=[];searchLatencyMS=0;candidateCount=0;examinedCount=0;searchRoute="empty";return }
        let clock=ContinuousClock(),start=clock.now;let response=await index.search(value,limit:200)
        guard !Task.isCancelled, generation == nil || generation==queryGeneration, value==query else{return}
        searchLatencyMS=Double(start.duration(to:clock.now).components.attoseconds)/1_000_000_000_000_000
        candidateCount=response.diagnostics.candidateCount;examinedCount=response.diagnostics.examinedCount;searchRoute=response.diagnostics.route;candidateTruncated=response.diagnostics.truncated
        results=response.results;if let selectedID,results.contains(where:{$0.id==selectedID}){return};selectedID=results.first?.id
    }
    func moveSelection(_ d:Int){guard !results.isEmpty else{return};let c=selectedID.flatMap{id in results.firstIndex(where:{$0.id==id})} ?? 0;selectedID=results[min(max(c+d,0),results.count-1)].id}
    private var selectedResult:SearchResult?{guard let selectedID else{return results.first};return results.first(where:{$0.id==selectedID}) ?? results.first}
    func openSelected(){if let r=selectedResult{open(r)}};func revealSelected(){if let r=selectedResult{reveal(r)}}
    func quickLookSelected(){guard let r=selectedResult else{return};let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/qlmanage");p.arguments=["-p",r.record.path];try?p.run()}
    func escape(){if !query.isEmpty{query="";queryChanged()}else{NSApp.keyWindow?.orderOut(nil)}};func open(_ r:SearchResult){NSWorkspace.shared.open(URL(fileURLWithPath:r.record.path))};func reveal(_ r:SearchResult){NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:r.record.path)])}
    private func startLiveMonitor(root:URL){monitor?.stop();monitor=FSEventMonitor(path:root.path){[weak self]paths in Task{@MainActor[weak self]in self?.scheduleFileEventUpdate(paths)}};monitor?.start()}
    private func scheduleFileEventUpdate(_ paths:[String]){pendingFileEventPaths.formUnion(paths);fileEventTask?.cancel();fileEventTask=Task{@MainActor[weak self]in try?await Task.sleep(for:.milliseconds(300));guard !Task.isCancelled,let self else{return};let b=Array(self.pendingFileEventPaths);self.pendingFileEventPaths.removeAll(keepingCapacity:true);guard !b.isEmpty else{return};let stats=await self.index.applyFileSystemChanges(paths:b,root:FileManager.default.homeDirectoryForCurrentUser);self.liveChangeBatches += 1;let c=await self.index.indexedCount;let d=stats.delta==0 ? "±0":(stats.delta>0 ? "+\(stats.delta)":"\(stats.delta)");self.status="Search ready • \(c.formatted()) items • \(self.liveChangeBatches) updates • \(d)";self.queryChanged()}}
}
struct ContentView: View {
    @Bindable var model: SearchModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("Search files…  ext:pdf  kind:image  path:Downloads", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($searchFocused)
                    .onChange(of: model.query) { _, _ in model.queryChanged() }

                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                        model.queryChanged()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 62)

            Divider()

            if !model.sessionStarted {
                StartupIndexView(model: model)
                Divider()
            } else if model.isIndexBusy {
                IndexProgressView(model: model)
                Divider()
            }

            List(selection: $model.selectedID) {
                ForEach(model.results) { result in
                    ResultRow(result: result)
                        .tag(result.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.open(result) }
                        .contextMenu {
                            Button("Open") { model.open(result) }
                            Button("Quick Look") {
                                model.selectedID = result.id
                                model.quickLookSelected()
                            }
                            Button("Reveal in Finder") { model.reveal(result) }
                        }
                }
            }
            .listStyle(.plain)

            Divider()
            HStack(spacing: 12) {
                Button { model.showIndexDetails = true } label: {
                    HStack(spacing: 5) { Image(systemName: "externaldrive.fill"); Text(model.status) }
                }.buttonStyle(.plain)
                Spacer()
                Text(String(format: "%.1f ms", model.searchLatencyMS))
                Text("\(model.results.count) results")
                Text("\(model.searchRoute) • \(model.candidateCount.formatted()) cand • \(model.examinedCount.formatted()) checked" + (model.candidateTruncated ? " • capped" : ""))
                Text("⌥Space summon  ↑↓ select  ↩ open  ⌘↩ reveal  ⌘Y preview")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 30)
        }
        .onAppear { focusSearchSoon() }
        .onReceive(NotificationCenter.default.publisher(for: .everythingFocusSearch)) { _ in focusSearchSoon() }
        .onReceive(NotificationCenter.default.publisher(for: .everythingMoveSelection)) { note in
            if let delta = note.object as? Int { model.moveSelection(delta) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .everythingOpenSelection)) { _ in model.openSelected() }
        .onReceive(NotificationCenter.default.publisher(for: .everythingRevealSelection)) { _ in model.revealSelected() }
        .onReceive(NotificationCenter.default.publisher(for: .everythingQuickLookSelection)) { _ in model.quickLookSelected() }
        .onReceive(NotificationCenter.default.publisher(for: .everythingEscape)) { _ in model.escape() }
        .sheet(isPresented: $model.showIndexDetails) { IndexDetailsView(model: model) }
    }

    private func focusSearchSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            searchFocused = true
        }
    }
}



struct StartupIndexView: View {
    @Bindable var model: SearchModel
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("Index Session").font(.title2.bold())
            Text("Debug mode does not scan or rebuild automatically. Load an existing index, choose another index folder, or explicitly build a new one.").foregroundStyle(.secondary)
            HStack(spacing:12) {
                Button("Load Existing Index") { model.loadExistingIndex() }.buttonStyle(.borderedProminent)
                Button("Choose Index Folder…") { model.chooseIndexFolder() }
                Button("Build New Index") { model.buildNewIndex() }
            }
            if !model.indexStoragePath.isEmpty {
                Text(model.indexStoragePath).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.padding(22).frame(maxWidth:.infinity,alignment:.leading)
    }
}

struct IndexProgressView: View {
    @Bindable var model: SearchModel
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Text(phaseTitle).font(.headline); Spacer(); Text(model.progressCompleted.formatted()).monospacedDigit() }
            if let f = model.progressFraction { ProgressView(value: f) } else { ProgressView() }
            HStack { Text(model.currentIndexPath.isEmpty ? "Discovering files and folders…" : model.currentIndexPath).lineLimit(1).truncationMode(.middle); Spacer(); if let total=model.progressTotal { Text("\(model.progressCompleted.formatted()) / \(total.formatted())") } }
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 18).padding(.vertical, 12)
    }
    private var phaseTitle:String { switch model.indexPhase { case .idle:"Idle";case .loading:"Loading persisted index";case .scanning:"Scanning files & folders";case .building:"Building search index";case .saving:"Saving index";case .ready:"Index ready" } }
}

struct IndexDetailsView: View {
    @Bindable var model: SearchModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack { Text("Index Status").font(.title2.bold()); Spacer(); Button("Done"){dismiss()} }
            Grid(alignment:.leading,horizontalSpacing:18,verticalSpacing:10) {
                GridRow { Text("Status").foregroundStyle(.secondary); Text(model.indexPhase == .ready ? "Up to date" : model.status) }
                GridRow { Text("Items").foregroundStyle(.secondary); Text(model.progressCompleted.formatted()) }
                GridRow { Text("Index size").foregroundStyle(.secondary); Text(ByteCountFormatter.string(fromByteCount:Int64(model.indexStorageBytes),countStyle:.file)) }
                GridRow { Text("Index location").foregroundStyle(.secondary); Text(model.indexStoragePath).textSelection(.enabled) }
            }
            HStack { Button("Open in Finder"){model.openIndexFolder()}; Spacer(); Button("Rebuild Index"){dismiss();model.rebuildRequested()}; Button("Clear & Rebuild",role:.destructive){dismiss();model.clearAndRebuild()} }
        }.padding(22).frame(width:620)
    }
}

struct ResultRow: View {
    let result: SearchResult

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: result.record.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 22))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(result.record.name)
                    .lineLimit(1)
                Text(result.record.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !result.record.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: Int64(result.record.size), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
#else
import Foundation
import EverythingCore

@main
struct LinuxSmokeMain {
    static func main() {
        print("EverythingMac UI is macOS-only. EverythingCore is portable.")
    }
}
#endif
