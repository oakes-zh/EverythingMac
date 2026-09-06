#if os(macOS)
import SwiftUI
import AppKit
import EverythingCore

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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
                window.makeMain()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@MainActor
@Observable
final class SearchModel {
    var query = ""
    var results: [SearchResult] = []
    var status = "Preparing index…"
    private let index = IndexManager()
    private var searchTask: Task<Void, Never>?

    init() {
        Task { await rebuild() }
    }

    func rebuild() async {
        status = "Indexing home folder…"
        await index.rebuild(root: FileManager.default.homeDirectoryForCurrentUser)
        let count = await index.indexedCount
        status = "Indexed \(count.formatted()) items"
        await performSearch()
    }

    func queryChanged() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(25))
            guard !Task.isCancelled else { return }
            await performSearch()
        }
    }

    func performSearch() async {
        let value = query
        results = await index.search(value, limit: 200)
    }

    func open(_ result: SearchResult) {
        NSWorkspace.shared.open(URL(fileURLWithPath: result.record.path))
    }

    func reveal(_ result: SearchResult) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result.record.path)])
    }
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
                    Button { model.query = ""; model.queryChanged() } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 62)

            Divider()

            List(model.results) { result in
                ResultRow(result: result)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.open(result) }
                    .contextMenu {
                        Button("Open") { model.open(result) }
                        Button("Reveal in Finder") { model.reveal(result) }
                    }
            }
            .listStyle(.plain)

            Divider()
            HStack {
                Text(model.status)
                Spacer()
                Text("\(model.results.count) results")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 28)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                searchFocused = true
            }
        }
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
