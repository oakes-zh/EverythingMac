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

struct LiveFSEvent: Sendable {
    let path: String
    let flags: FSEventStreamEventFlags
    let id: FSEventStreamEventId
    var requiresRescan: Bool {
        (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)) != 0 ||
        (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)) != 0 ||
        (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)) != 0
    }
}

final class FSEventMonitor {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let callback: @Sendable ([LiveFSEvent]) -> Void
    private let queue = DispatchQueue(label: "EverythingMac.FSEvents", qos: .utility)
    private(set) var running = false

    init(paths: [String], callback: @escaping @Sendable ([LiveFSEvent]) -> Void) {
        self.paths = paths
        self.callback = callback
    }

    @discardableResult func start() -> Bool {
        guard stream == nil, !paths.isEmpty else { return running }
        let unmanagedSelf = Unmanaged.passUnretained(self)
        var context = FSEventStreamContext(version: 0, info: unmanagedSelf.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, eventPaths, eventFlags, eventIDs in
                guard let info, count > 0 else { return }
                let monitor = Unmanaged<FSEventMonitor>.fromOpaque(info).takeUnretainedValue()
                let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
                var events: [LiveFSEvent] = []
                events.reserveCapacity(count)
                for i in 0..<count {
                    guard let value = CFArrayGetValueAtIndex(cfPaths, i) else { continue }
                    let cfString = unsafeBitCast(value, to: CFString.self)
                    let path = cfString as String
                    events.append(LiveFSEvent(path: path, flags: eventFlags[i], id: eventIDs[i]))
                }
                if !events.isEmpty { monitor.callback(events) }
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.10,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        )
        guard let created else { running = false; return false }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        running = FSEventStreamStart(created)
        if !running { FSEventStreamInvalidate(created); FSEventStreamRelease(created); stream = nil }
        return running
    }

    func stop() {
        guard let stream else { running = false; return }
        if running { FSEventStreamStop(stream) }
        FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        self.stream = nil; running = false
    }
    deinit { stop() }
}

struct IndexableVolume: Identifiable, Hashable {
    let id: String
    let url: URL
    let name: String
    let internalDrive: Bool
    let removable: Bool
    let capacity: Int64
    var selected: Bool
}

@MainActor
@Observable
final class SearchModel {
    var query=""; var results:[SearchResult]=[]; var selectedID:UInt64?; var status="Choose an existing index or build a new one"
    var searchLatencyMS:Double=0; var indexPhase:IndexPhase = .idle; var progressCompleted=0; var progressTotal:Int?; var currentIndexPath=""
    var indexStoragePath=""; var indexStorageBytes:UInt64=0; var showIndexDetails=false; var showBuildConfirmation=false; var showVolumePicker=false; var sessionStarted=false; var searchReady=false
    var volumes:[IndexableVolume]=[]; var monitoredRoots:[URL]=[]; var realtimeMonitoring=false; var lastRealtimeUpdate:Date?; var pendingRealtimeChanges=0
    var fseventsHealth="Stopped"; var lastFSEventAt:Date?; var lastReconciledPath="—"; var realtimeAdded=0; var realtimeRemoved=0; var realtimeChanged=0; var lastFSEventID:UInt64=0
    var candidateCount=0; var examinedCount=0; var searchRoute="idle"; var candidateTruncated=false
    var lookupMS=0.0; var matchMS=0.0; var rankMS=0.0; var slowQuery=false; var fullScan=false
    private let index=IndexManager(); private var searchTask:Task<Void,Never>?; private var queryGeneration=0
    private var fileEventTask:Task<Void,Never>?; private var monitor:FSEventMonitor?; private var pendingFileEventPaths=Set<String>(); private var liveChangeBatches=0; private var realtimeNeedsRebuild=false

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
        let savedRoots=(await index.persistedInfo)?.rootPaths?.map{URL(fileURLWithPath:$0,isDirectory:true)} ?? [root]
        let ok=await index.loadPersisted(root:root,progress:progressHandler)
        guard ok else { indexPhase = .idle; status="No valid index found at selected location"; sessionStarted=false; return }
        let count=await index.indexedCount; indexStorageBytes=await index.storageSizeBytes; indexStoragePath=await index.storagePath
        searchReady=true; monitoredRoots=savedRoots; startLiveMonitors(roots:monitoredRoots); status="Search ready • \(count.formatted()) items • realtime monitoring on"
    }
    func chooseIndexFolder(){
        let panel=NSOpenPanel(); panel.canChooseDirectories=true; panel.canChooseFiles=false; panel.allowsMultipleSelection=false; panel.prompt="Use Index"
        if panel.runModal() == NSApplication.ModalResponse.OK, let u = panel.url { Task { await index.useStorageDirectory(u); indexStoragePath=await index.storagePath; indexStorageBytes=await index.storageSizeBytes; await inspectDefaultIndex() } }
    }
    func buildNewIndex(){ showBuildConfirmation=true }
    func prepareVolumeSelection(){
        let keys:Set<URLResourceKey>=[.volumeNameKey,.volumeIsInternalKey,.volumeIsRemovableKey,.volumeTotalCapacityKey,.volumeIsReadOnlyKey]
        let urls=FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys:Array(keys),options:[.skipHiddenVolumes]) ?? []
        volumes=urls.compactMap { u in
            guard let v=try? u.resourceValues(forKeys:keys), v.volumeIsReadOnly != true else{return nil}
            let name=v.volumeName ?? u.lastPathComponent; if name.isEmpty{return nil}
            let internalDrive=v.volumeIsInternal ?? false; let removable=v.volumeIsRemovable ?? false
            return IndexableVolume(id:u.standardizedFileURL.path,url:u,name:name,internalDrive:internalDrive,removable:removable,capacity:Int64(v.volumeTotalCapacity ?? 0),selected:internalDrive)
        }.sorted{ ($0.internalDrive ? 0:1,$0.name) < ($1.internalDrive ? 0:1,$1.name) }
        showVolumePicker=true
    }
    func toggleVolume(_ id:String){ if let i=volumes.firstIndex(where:{$0.id==id}){volumes[i].selected.toggle()} }
    func buildSelectedVolumes(){ let roots=volumes.filter{$0.selected}.map{$0.url}; guard !roots.isEmpty else{return}; showVolumePicker=false; sessionStarted=true; Task{await rebuild(roots:roots)} }
    func rebuild(roots:[URL]?=nil) async { let chosen=roots ?? (monitoredRoots.isEmpty ? [FileManager.default.homeDirectoryForCurrentUser]:monitoredRoots); let hadReadyIndex=searchReady; if !hadReadyIndex { results=[] }; stopLiveMonitors();await index.rebuild(roots:chosen,progress:progressHandler);let c=await index.indexedCount;indexStoragePath=await index.storagePath;indexStorageBytes=await index.storageSizeBytes;monitoredRoots=chosen;searchReady=true;startLiveMonitors(roots:chosen);status="Search ready • \(c.formatted()) items • realtime monitoring on" }
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
        lookupMS=response.diagnostics.lookupMS;matchMS=response.diagnostics.matchMS;rankMS=response.diagnostics.rankMS;fullScan=response.diagnostics.fullScan;slowQuery=response.diagnostics.totalMS > 100
        results=response.results;if let selectedID,results.contains(where:{$0.id==selectedID}){return};selectedID=results.first?.id
    }
    func moveSelection(_ d:Int){guard !results.isEmpty else{return};let c=selectedID.flatMap{id in results.firstIndex(where:{$0.id==id})} ?? 0;selectedID=results[min(max(c+d,0),results.count-1)].id}
    private var selectedResult:SearchResult?{guard let selectedID else{return results.first};return results.first(where:{$0.id==selectedID}) ?? results.first}
    func openSelected(){if let r=selectedResult{open(r)}};func revealSelected(){if let r=selectedResult{reveal(r)}}
    func quickLookSelected(){guard let r=selectedResult else{return};let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/qlmanage");p.arguments=["-p",r.record.path];try?p.run()}
    func escape(){if !query.isEmpty{query="";queryChanged()}else{NSApp.keyWindow?.orderOut(nil)}};func open(_ r:SearchResult){NSWorkspace.shared.open(URL(fileURLWithPath:r.record.path))};func reveal(_ r:SearchResult){NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:r.record.path)])}
    private func startLiveMonitors(roots:[URL]) {
        stopLiveMonitors(); realtimeNeedsRebuild=false
        let paths = Array(Set(roots.map { $0.standardizedFileURL.path })).sorted()
        guard !paths.isEmpty else { fseventsHealth="No volumes"; return }
        let m = FSEventMonitor(paths: paths) { [weak self] events in
            Task { @MainActor [weak self] in self?.receiveFSEvents(events) }
        }
        monitor = m
        realtimeMonitoring = m.start()
        fseventsHealth = realtimeMonitoring ? "Running" : "Failed to start"
    }
    private func stopLiveMonitors() {
        monitor?.stop(); monitor=nil; realtimeMonitoring=false; fseventsHealth="Stopped"
        fileEventTask?.cancel(); fileEventTask=nil; pendingFileEventPaths.removeAll(); pendingRealtimeChanges=0
    }
    private func receiveFSEvents(_ events:[LiveFSEvent]) {
        guard !events.isEmpty else { return }
        lastFSEventAt=Date(); lastFSEventID=UInt64(events.map(\.id).max() ?? 0)
        if events.contains(where: \.requiresRescan) {
            realtimeNeedsRebuild=true; fseventsHealth="Rescan required"; status="Index may be out of date • FSEvents requested a rescan"
            return
        }
        fseventsHealth="Running"
        scheduleFileEventUpdate(events.map(\.path))
    }
    private func scheduleFileEventUpdate(_ paths:[String]) {
        guard !realtimeNeedsRebuild else { return }
        pendingFileEventPaths.formUnion(paths); pendingRealtimeChanges=pendingFileEventPaths.count
        fileEventTask?.cancel()
        fileEventTask=Task { @MainActor [weak self] in
            try? await Task.sleep(for:.milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            let batch=Array(self.pendingFileEventPaths); self.pendingFileEventPaths.removeAll(keepingCapacity:true); self.pendingRealtimeChanges=0
            guard !batch.isEmpty else { return }
            let roots=self.monitoredRoots.isEmpty ? [FileManager.default.homeDirectoryForCurrentUser] : self.monitoredRoots
            let stats=await self.index.applyFileSystemChanges(paths:batch,roots:roots)
            self.liveChangeBatches += 1; self.lastRealtimeUpdate=Date(); self.lastReconciledPath=batch.count == 1 ? batch[0] : "\(batch.count) paths"
            if stats.delta > 0 { self.realtimeAdded += stats.delta } else if stats.delta < 0 { self.realtimeRemoved += -stats.delta } else { self.realtimeChanged += 1 }
            let c=await self.index.indexedCount; self.progressCompleted=c; let d=stats.delta == 0 ? "±0" : (stats.delta > 0 ? "+\(stats.delta)" : "\(stats.delta)")
            self.status="Search ready • \(c.formatted()) items • realtime \(d)"; self.queryChanged()
        }
    }
}
struct ContentView: View {
    @Bindable var model: SearchModel
    @FocusState private var searchFocused: Bool
    @State private var selectedSection = "search"

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model, selectedSection: $selectedSection)
                .frame(width: 206)
                .background(.ultraThinMaterial)

            Divider()

            VStack(spacing: 0) {
                SearchHeader(model: model, searchFocused: $searchFocused)
                Divider().opacity(0.55)

                if model.isIndexBusy {
                    IndexProgressView(model: model)
                    Divider().opacity(0.55)
                }

                ResultsPane(model: model)
                Divider().opacity(0.55)
                StatusBar(model: model)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 900, minHeight: 560)
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
        .alert("Build a New Index?", isPresented: $model.showBuildConfirmation) { Button("Cancel", role: .cancel){}; Button("Choose Disks…"){ model.prepareVolumeSelection() } } message: { Text("EverythingMac will build a complete filename index for the disks you select. Your current index remains available until you confirm the new build.") }
        .sheet(isPresented: $model.showVolumePicker) { VolumePickerView(model:model) }
    }

    private func focusSearchSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            searchFocused = true
        }
    }
}

struct SidebarView: View {
    @Bindable var model: SearchModel
    @Binding var selectedSection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("EverythingMac")
                .font(.system(size: 17, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 20)

            SidebarCaption("INDEX")
            SidebarAction(icon: "externaldrive", title: "Load Existing Index", active: !model.sessionStarted) {
                model.loadExistingIndex()
            }
            SidebarAction(icon: "folder.badge.gearshape", title: "Choose Index Folder…") {
                model.chooseIndexFolder()
            }
            SidebarAction(icon: "cylinder.split.1x2", title: "Build New Index") {
                model.buildNewIndex()
            }

            Divider().padding(.horizontal, 12).padding(.vertical, 12)
            SidebarCaption("BROWSE")
            SidebarAction(icon: "magnifyingglass", title: "Search", active: selectedSection == "search") {
                selectedSection = "search"
                NotificationCenter.default.post(name: .everythingFocusSearch, object: nil)
            }
            SidebarAction(icon: "clock", title: "Recent", enabled: false) { }
            SidebarAction(icon: "gearshape", title: "Settings", enabled: false) { }

            Spacer()

            Button { model.showIndexDetails = true } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.searchReady ? Color.green : (model.isIndexBusy ? Color.orange : Color.secondary.opacity(0.55)))
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Index Status").font(.caption.weight(.medium))
                        Text(indexSummary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(12)
        }
    }

    private var indexSummary: String {
        if model.searchReady { return "Ready • \(model.progressCompleted.formatted()) items" }
        if model.isIndexBusy { return model.status }
        return model.progressCompleted > 0 ? "\(model.progressCompleted.formatted()) items" : "Not loaded"
    }
}

struct SidebarCaption: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 16)
            .padding(.bottom, 5)
    }
}

struct SidebarAction: View {
    let icon: String
    let title: String
    var active = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).frame(width: 18)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: active ? .medium : .regular))
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(active ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .padding(.horizontal, 7)
    }
}

struct SearchHeader: View {
    @Bindable var model: SearchModel
    var searchFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search files and folders", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused(searchFocused)
                    .onChange(of: model.query) { _, _ in model.queryChanged() }
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                        model.queryChanged()
                    } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 42)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(searchFocused.wrappedValue ? Color.accentColor.opacity(0.8) : Color(nsColor: .separatorColor).opacity(0.45), lineWidth: searchFocused.wrappedValue ? 1.5 : 1)
            }
            .shadow(color: .black.opacity(0.035), radius: 1, y: 1)

            HStack(spacing: 8) {
                Circle().fill(model.searchReady ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                Text(model.searchReady ? "Search ready" : model.status)
                    .lineLimit(1)
                Spacer()
                if model.searchReady && !model.query.isEmpty {
                    Text("route: \(model.searchRoute)")
                    Text("•")
                    Text("checked: \(model.examinedCount.formatted())")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 11)
    }
}

struct ResultsPane: View {
    @Bindable var model: SearchModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Path").frame(maxWidth: .infinity, alignment: .leading)
                Text("Size").frame(width: 86, alignment: .trailing)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(height: 29)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))

            Divider().opacity(0.45)

            if !model.sessionStarted {
                EmptyIndexState(model: model)
            } else if model.results.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: model.query.isEmpty ? "magnifyingglass" : "doc.text.magnifyingglass")
                        .font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                    Text(model.query.isEmpty ? "Start typing to search" : "No matching files or folders")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedID) {
                    ForEach(model.results) { result in
                        ResultRow(result: result)
                            .tag(result.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.open(result) }
                            .contextMenu {
                                Button("Open") { model.open(result) }
                                Button("Quick Look") { model.selectedID = result.id; model.quickLookSelected() }
                                Button("Reveal in Finder") { model.reveal(result) }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

struct EmptyIndexState: View {
    @Bindable var model: SearchModel
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "externaldrive.badge.magnifyingglass")
                .font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text("Load an index to begin")
                .font(.headline)
            Text("EverythingMac only searches file and folder names.\nIt does not search file contents.")
                .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Load Existing Index") { model.loadExistingIndex() }.buttonStyle(.borderedProminent)
                Button("Build New Index") { model.buildNewIndex() }.buttonStyle(.bordered)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusBar: View {
    @Bindable var model: SearchModel

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 9) {
                Button { model.showIndexDetails = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "externaldrive.fill")
                        Text(model.status).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .help("Index Status")

                Spacer(minLength: 10)

                if model.fullScan {
                    Text("⚠ FULL SCAN").foregroundStyle(.red).fontWeight(.bold)
                } else if model.slowQuery {
                    Text(String(format: "⚠ Slow %.1f ms", model.searchLatencyMS)).foregroundStyle(.orange).fontWeight(.semibold)
                } else {
                    Text(String(format: "%.1f ms", model.searchLatencyMS))
                }
                Text("\(model.results.count) results")
                Text("\(model.searchRoute) • \(model.candidateCount.formatted()) cand • \(model.examinedCount.formatted()) checked" + (model.candidateTruncated ? " • capped" : ""))
                Text(String(format: "lookup %.2f • match %.2f • rank %.2f ms", model.lookupMS, model.matchMS, model.rankMS))
            }

            HStack {
                if !model.indexStoragePath.isEmpty {
                    Text("Index: \(model.indexStoragePath)").lineLimit(1).truncationMode(.middle)
                } else {
                    Text("Index not loaded")
                }
                Spacer()
                Text("⌥Space summon   ↑↓ select   ↩ open   ⌘↩ reveal   ⌘Y preview")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(.bar)
    }
}

struct IndexProgressView: View {
    @Bindable var model: SearchModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(phaseTitle).font(.callout.weight(.medium))
                Spacer()
                Text(model.progressCompleted.formatted()).monospacedDigit().foregroundStyle(.secondary)
            }
            if let f = model.progressFraction { ProgressView(value: f) } else { ProgressView() }
            HStack {
                Text(model.currentIndexPath.isEmpty ? "Preparing index…" : model.currentIndexPath).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let total=model.progressTotal { Text("\(model.progressCompleted.formatted()) / \(total.formatted())") }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.035))
    }
    private var phaseTitle:String { switch model.indexPhase { case .idle:"Idle";case .loading:"Loading persisted index";case .scanning:"Scanning files & folders";case .building:"Building search index";case .saving:"Saving index";case .ready:"Index ready" } }
}

struct IndexDetailsView: View {
    @Bindable var model: SearchModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Index Status").font(.title2.bold())
                    Text("EverythingMac local filename index").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done"){dismiss()}.keyboardShortcut(.defaultAction)
            }
            Divider()
            Grid(alignment:.leading,horizontalSpacing:22,verticalSpacing:12) {
                GridRow { Text("Status").foregroundStyle(.secondary); Label(model.indexPhase == .ready ? "Up to date" : model.status, systemImage: model.searchReady ? "checkmark.circle.fill" : "circle.dotted") }
                GridRow { Text("Items").foregroundStyle(.secondary); Text(model.progressCompleted.formatted()).monospacedDigit() }
                GridRow { Text("Index size").foregroundStyle(.secondary); Text(ByteCountFormatter.string(fromByteCount:Int64(model.indexStorageBytes),countStyle:.file)) }
                GridRow { Text("Index location").foregroundStyle(.secondary); Text(model.indexStoragePath).textSelection(.enabled).lineLimit(2) }
                GridRow { Text("Realtime monitoring").foregroundStyle(.secondary); Text(model.realtimeMonitoring ? "On" : "Off") }
                GridRow { Text("Pending changes").foregroundStyle(.secondary); Text(model.pendingRealtimeChanges.formatted()).monospacedDigit() }
                GridRow { Text("Last update").foregroundStyle(.secondary); Text(model.lastRealtimeUpdate?.formatted(date:.omitted,time:.standard) ?? "—") }
                GridRow { Text("FSEvents").foregroundStyle(.secondary); Text(model.fseventsHealth) }
                GridRow { Text("Last event").foregroundStyle(.secondary); Text(model.lastFSEventAt?.formatted(date:.omitted,time:.standard) ?? "—") }
                GridRow { Text("Last reconciled").foregroundStyle(.secondary); Text(model.lastReconciledPath).lineLimit(1).truncationMode(.middle) }
                GridRow { Text("Realtime Δ").foregroundStyle(.secondary); Text("+\(model.realtimeAdded)  −\(model.realtimeRemoved)  ~\(model.realtimeChanged)").monospacedDigit() }
            }
            Divider()
            HStack {
                Button("Open in Finder"){model.openIndexFolder()}
                Spacer()
                Button("Rebuild Index"){dismiss();model.rebuildRequested()}
                Button("Clear & Rebuild",role:.destructive){dismiss();model.clearAndRebuild()}
            }
        }.padding(22).frame(width:620)
    }
}

struct VolumePickerView: View {
    @Bindable var model: SearchModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:16){
            VStack(alignment:.leading,spacing:4){Text("Select Disks to Index").font(.title2.bold());Text("A full filename index will be created for every selected disk.").foregroundStyle(.secondary)}
            Divider()
            ScrollView { VStack(spacing:6){ ForEach(model.volumes){v in Button{model.toggleVolume(v.id)}label:{HStack(spacing:12){Image(systemName:v.selected ? "checkmark.circle.fill":"circle").foregroundStyle(v.selected ? Color.accentColor:.secondary);Image(systemName:v.internalDrive ? "internaldrive":"externaldrive");VStack(alignment:.leading){Text(v.name).foregroundStyle(.primary);Text(v.internalDrive ? "Internal disk":"External disk").font(.caption).foregroundStyle(.secondary)};Spacer();if v.capacity>0{Text(ByteCountFormatter.string(fromByteCount:v.capacity,countStyle:.file)).font(.caption).foregroundStyle(.secondary)}}.padding(10).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:9))}.buttonStyle(.plain)}} }
            Divider();HStack{Text("\(model.volumes.filter{$0.selected}.count) disks selected").font(.caption).foregroundStyle(.secondary);Spacer();Button("Cancel"){dismiss()};Button("Build Index"){model.buildSelectedVolumes()}.buttonStyle(.borderedProminent).disabled(!model.volumes.contains{$0.selected})}
        }.padding(22).frame(width:560,height:430)
    }
}

struct ResultRow: View {
    let result: SearchResult

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: result.record.isDirectory ? "folder.fill" : "doc.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(result.record.isDirectory ? Color.accentColor : Color.secondary)
                    .frame(width: 22)
                Text(result.record.name).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(result.record.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(result.record.isDirectory ? "Folder" : ByteCountFormatter.string(fromByteCount: Int64(result.record.size), countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 34)
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
