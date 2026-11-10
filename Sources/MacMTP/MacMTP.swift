import AppKit
import SwiftUI

#if !arch(arm64) || !os(macOS)
#error("MacMTP requires Apple Silicon macOS.")
#endif

@main
struct MacMTPApp: App {
    var body: some Scene {
        Window("MacMTP", id: "browser") { Browser() }
            .defaultSize(width: 1000, height: 650)
    }
}

private struct Browser: View {
    private enum Sort: String, CaseIterable {
        case name = "Name", kind = "Kind", size = "Size", modified = "Date Modified"
    }

    @State private var sort: Sort = .name
    @State private var device = Device()
    @State private var storages: [Storage] = []
    @State private var storage: UInt32?
    @State private var folders: [Entry] = []
    @State private var entries: [Entry] = []
    @State private var selection: Set<UInt32> = []
    @State private var search = ""
    @State private var busy = false
    @State private var status = ""
    @State private var transferred = 0
    @State private var failure: String?
    @State private var name = ""
    @State private var renaming: Entry?
    @State private var naming = false
    @State private var deleting = false
    @State private var showHidden = false
    @State private var grid = false
    @State private var inspector = false
    @State private var history: [String] = []
    @State private var showHistory = false

    private var parent: UInt32 { folders.last?.id ?? UInt32.max }
    private var selected: [Entry] { entries.filter { selection.contains($0.id) } }
    private var visible: [Entry] {
        entries.filter {
            (showHidden || !$0.name.hasPrefix(".")) &&
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
        }.sorted {
            if $0.folder != $1.folder { return $0.folder }
            switch sort {
            case .size where $0.size != $1.size: return $0.size < $1.size
            case .modified where $0.modified != $1.modified:
                return ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast)
            case .kind:
                let lhs = ($0.name as NSString).pathExtension.lowercased()
                let rhs = ($1.name as NSString).pathExtension.lowercased()
                if lhs != rhs { return lhs < rhs }
            default: break
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $storage) {
                Section("Device Storage") {
                    ForEach(storages) { item in
                        Label(item.name, systemImage: "externaldrive").tag(item.id)
                    }
                }
            }
            .disabled(busy)
            .navigationSplitViewColumnWidth(min: 170, ideal: 210)
        } detail: {
            VStack(spacing: 0) {
                if storage == nil {
                    ContentUnavailableView("No Storage Selected", systemImage: "cable.connector",
                                           description: Text("Unlock your Android device and select USB File Transfer."))
                } else if visible.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "Empty Folder" : "No Results",
                                           systemImage: search.isEmpty ? "folder" : "magnifyingglass")
                } else if grid {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 16) {
                            ForEach(visible) { item in
                                VStack(spacing: 8) {
                                    Image(systemName: item.folder ? "folder.fill" : "doc")
                                        .font(.system(size: 38))
                                        .foregroundStyle(item.folder ? Color.accentColor : Color.secondary)
                                    Text(item.name).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, minHeight: 96)
                                .background(selection.contains(item.id) ? Color.accentColor.opacity(0.15) : .clear,
                                            in: RoundedRectangle(cornerRadius: 12))
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { open(item) }
                                .onTapGesture { selection = [item.id] }
                                .contextMenu { actions([item]) }
                                .accessibilityAddTraits(.isButton)
                            }
                        }.padding()
                    }
                } else {
                    Table(visible, selection: $selection) {
                        TableColumn("Name") { item in
                            Label(item.name, systemImage: item.folder ? "folder.fill" : "doc")
                                .onTapGesture(count: 2) { open(item) }
                        }
                        TableColumn("Date Modified") { item in
                            Text(item.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                        }
                        TableColumn("Kind") { item in Text(item.folder ? "Folder" : "File") }
                        TableColumn("Size") { item in Text(item.folder ? "—" : ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)) }
                    }
                    .contextMenu(forSelectionType: UInt32.self) { ids in
                        actions(entries.filter { ids.contains($0.id) })
                    }
                }
                Divider()
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    Text(status.isEmpty ? "\(visible.count) items" : status)
                    if busy && transferred > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(transferred), countStyle: .file))
                    }
                    Spacer()
                    Text("\(selection.count) selected")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
            }
            .navigationTitle(folders.last?.name ?? "MacMTP")
            .searchable(text: $search, prompt: "Search this folder")
            .inspector(isPresented: $inspector) {
                Form {
                    if selected.count == 1, let item = selected.first {
                        LabeledContent("Name", value: item.name)
                        LabeledContent("Kind", value: item.folder ? "Folder" : "File")
                        if let modified = item.modified {
                            LabeledContent("Modified", value: modified.formatted(date: .abbreviated, time: .shortened))
                        }
                        if !item.folder { LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)) }
                    } else {
                        Text("Select one item to see its details.")
                    }
                }.padding()
            }
            .toolbar {
                Button("Back", systemImage: "chevron.left") {
                    folders.removeLast()
                    run { try await reload() }
                }.disabled(busy || folders.isEmpty)
                Button("Refresh", systemImage: "arrow.clockwise") { run { try await reconnect() } }.disabled(busy)
                Button("Upload", systemImage: "square.and.arrow.up") { chooseUpload() }.disabled(busy || storage == nil)
                Button("Download", systemImage: "square.and.arrow.down") { chooseDownload(selected) }.disabled(busy || selected.isEmpty)
                Button("New Folder", systemImage: "folder.badge.plus") {
                    renaming = nil
                    name = ""
                    naming = true
                }.disabled(busy || storage == nil)
                Menu("View", systemImage: "slider.horizontal.3") {
                    Picker("Sort By", selection: $sort) {
                        ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Grid", isOn: $grid)
                    Toggle("Hidden Files", isOn: $showHidden)
                    Toggle("Inspector", isOn: $inspector)
                    Button("Recent Activity") { showHistory = true }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                if !busy {
                    busy = true
                    let previous = storages
                    do {
                        storages = try await device.connect()
                        if !storages.contains(where: { $0.id == storage }) {
                            storage = storages.first?.id
                        }
                    } catch {
                        storages = []
                        storage = nil
                        entries = []
                        if !previous.isEmpty { status = "Device disconnected" }
                    }
                    busy = false
                }
                do { try await Task.sleep(for: .seconds(6)) } catch { return }
            }
        }
        .onChange(of: storage) {
            folders = []
            entries = []
            selection = []
            if storage != nil { run { try await reload() } }
        }
        .alert(renaming == nil ? "New Folder" : "Rename Item", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                guard let storage else { return }
                run {
                    if let renaming { try await device.rename(renaming, to: name) }
                    else { try await device.makeFolder(name, storage: storage, parent: parent) }
                    record(renaming == nil ? "Created folder \(name)" : "Renamed item to \(name)")
                    try await reload()
                }
            }.disabled(name.isEmpty)
        }
        .confirmationDialog("Permanently delete the selected items?", isPresented: $deleting) {
            Button("Delete", role: .destructive) {
                let items = selected
                run {
                    for item in items { try await device.remove(item); record("Deleted \(item.name)") }
                    try await reload()
                }
            }
        }
        .alert("MacMTP", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
        .sheet(isPresented: $showHistory) {
            VStack(alignment: .leading) {
                Text("Recent Activity").font(.headline)
                List(history.indices, id: \.self) { index in Text(history[index]) }
                Button("Done") { showHistory = false }.keyboardShortcut(.defaultAction)
            }.padding().frame(width: 460, height: 320)
        }
    }

    @ViewBuilder private func actions(_ items: [Entry]) -> some View {
        if let item = items.first, items.count == 1 {
            if item.folder { Button("Open") { open(item) }.disabled(busy) }
            Button("Rename") { renaming = item; name = item.name; naming = true }.disabled(busy)
            Button("Get Info") { selection = [item.id]; inspector = true }
        }
        if !items.isEmpty {
            Button("Download") { chooseDownload(items) }.disabled(busy)
            Button("Delete", role: .destructive) {
                selection = Set(items.map(\.id))
                deleting = true
            }.disabled(busy)
        }
    }

    private func open(_ entry: Entry) {
        guard entry.folder, !busy else { return }
        folders.append(entry)
        run { try await reload() }
    }

    private func reload() async throws {
        guard let storage else { return }
        do {
            entries = try await device.list(storage: storage, parent: parent)
        } catch {
            entries = []
            selection = []
            throw error
        }
        selection.formIntersection(entries.map(\.id))
    }

    private func reconnect() async throws {
        await device.disconnect()
        storages = try await device.connect()
        if !storages.contains(where: { $0.id == storage }) { storage = storages.first?.id }
        else { try await reload() }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false; status = ""; transferred = 0 }
            do { try await operation() }
            catch { failure = error.localizedDescription; try? await reload() }
        }
    }

    private func chooseUpload() {
        guard let storage, !busy else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = true
        guard picker.runModal() == .OK else { return }
        let urls = picker.urls
        run {
            for url in urls {
                transferred = 0
                status = "Uploading \(url.lastPathComponent)"
                try await device.upload(url, storage: storage, parent: parent) { count in
                    Task { @MainActor in
                        if busy { transferred = count }
                    }
                }
                record("Uploaded \(url.lastPathComponent)")
            }
            try await reload()
        }
    }

    private func chooseDownload(_ items: [Entry]) {
        guard let storage, !busy else { return }
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        guard picker.runModal() == .OK, let target = picker.url else { return }
        run {
            for item in items {
                transferred = 0
                status = "Downloading \(item.name)"
                try await device.download(item, storage: storage, into: target) { count in
                    Task { @MainActor in
                        if busy { transferred = count }
                    }
                }
                record("Downloaded \(item.name)")
            }
        }
    }

    private func record(_ event: String) {
        history = Array(([event] + history).prefix(100))
    }
}
