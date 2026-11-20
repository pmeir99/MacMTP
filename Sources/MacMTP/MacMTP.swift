import AppKit
import SwiftUI
import QuickLook
import UniformTypeIdentifiers

#if !arch(arm64) || !os(macOS)
#error("MacMTP requires Apple Silicon macOS.")
#endif

@main
struct MacMTPApp: App {
    @StateObject private var updater = AppUpdater()

    var body: some Scene {
        Window("MacMTP", id: "browser") {
            Browser()
                .environmentObject(updater)
                .sheet(isPresented: $updater.showWindow) { SoftwareUpdateView(updater: updater) }
                .onAppear { updater.launched() }
        }
            .defaultSize(width: 1000, height: 650)
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") {
                        updater.showWindow = true
                        Task { await updater.check() }
                    }.disabled(updater.isInstalling)
                }
            }

        Settings { SoftwareUpdateView(updater: updater) }
    }
}

struct Browser: View {
    private let automaticallyConnect: Bool
    private let selectionObserver: ((Set<UInt32>) -> Void)?
    #if DEBUG
    private let testPreviewFile: URL?
    #endif

    init() {
        automaticallyConnect = true
        selectionObserver = nil
        #if DEBUG
        testPreviewFile = nil
        #endif
    }

    #if DEBUG
    init(testEntries: [Entry], directories: [UInt32: [Entry]] = [:], previewFile: URL? = nil, layout name: String,
         selectionObserver: @escaping (Set<UInt32>) -> Void) {
        automaticallyConnect = false
        testPreviewFile = previewFile
        self.selectionObserver = selectionObserver
        _storages = State(initialValue: [Storage(id: 1, name: "Test Storage")])
        _storage = State(initialValue: 1)
        var initial = DirectoryContent()
        initial.begin(parent: .max, cached: testEntries)
        _content = State(initialValue: initial)
        _directoryCache = State(initialValue: directories.merging([.max: testEntries]) { _, root in root })
        _layout = AppStorage(wrappedValue: Layout(rawValue: name) ?? .list,
                             "testLayout-\(UUID().uuidString)")
    }
    #endif
    @EnvironmentObject private var updater: AppUpdater
    private enum Sort: String, CaseIterable {
        case name = "Name", kind = "Kind", size = "Size", modified = "Date Modified"
    }

    @StateObject private var previews = PreviewStore()
    @State private var previewURL: URL?
    @State private var content = DirectoryContent()
    private var loading: Bool { content.loading }
    private var loadedParent: UInt32? { content.loadedParent }
    @State private var keyboardAnchor: UInt32?
    @State private var gridColumns = 1
    @State private var activeColumn = 0
    @State private var renameRequest: Task<Void, Never>?
    @FocusState private var fileAreaFocused: Bool
    @AppStorage("calculateFolderSizes") private var calculateFolderSizes = false
    @State private var sort: Sort = .name
    @State private var device = Device()
    @State private var deviceSession: UUID?
    @State private var usbRecovery = USBRecovery()
    @AppStorage("automaticUSBRecovery") private var automaticUSBRecovery = true
    @State private var startupRecoveryDone = false
    @State private var connectionMessage = DeviceError.unavailable.localizedDescription
    @State private var storages: [Storage] = []
    @State private var storage: UInt32?
    @State private var folders: [Entry] = []
    private var entries: [Entry] { content.entries }
    @State private var selection: Set<UInt32> = []
    @State private var search = ""
    @State private var busy = false
    @State private var status = ""
    @State private var transfers: [TransferProgress] = []
    @State private var activeExports = 0
    @State private var failure: String?
    @State private var name = ""
    @State private var renaming: Entry?
    @State private var naming = false
    @State private var deleting = false
    @State private var showHidden = false
    private enum Layout: String, CaseIterable {
        case icons = "Icons", list = "List", columns = "Columns", gallery = "Gallery"

        var symbol: String {
            switch self {
            case .icons: "square.grid.2x2"
            case .list: "list.bullet"
            case .columns: "rectangle.split.3x1"
            case .gallery: "rectangle.on.rectangle"
            }
        }
    }

    @AppStorage("browserLayout") private var layout: Layout = .list
    @State private var directoryCache: [UInt32: [Entry]] = [:]
    @State private var folderSizes: [UInt32: UInt64] = [:]
    @State private var listingVersion = 0
    @State private var dropTargeted = false
    @State private var inspector = false
    @State private var history: [String] = []
    @State private var showHistory = false

    private var parent: UInt32 { folders.last?.id ?? UInt32.max }
    private var selected: [Entry] {
        guard !selection.isEmpty else { return [] }
        var pending = selection
        var result: [Entry] = []
        for item in entries + folders where pending.remove(item.id) != nil {
            result.append(item)
        }
        if pending.isEmpty { return result }
        for items in directoryCache.values {
            for item in items where pending.remove(item.id) != nil { result.append(item) }
            if pending.isEmpty { break }
        }
        return result
    }
    private var visible: [Entry] {
        entries.filter {
            (showHidden || !$0.name.hasPrefix(".")) &&
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
        }.sorted {
            if $0.folder != $1.folder { return $0.folder }
            switch sort {
            case .size where byteCount($0) != byteCount($1): return (byteCount($0) ?? .max) < (byteCount($1) ?? .max)
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
                                           description: Text(connectionMessage))
                } else {
                    browserContent
                        .background(FileKeyboard(handle: handleNativeKey))
                        .focusable()
                        .focusEffectDisabled()
                        .focused($fileAreaFocused)
                        .onKeyPress(phases: [.down, .repeat]) { press in
                            handleKey(press)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .overlay {
                            if dropTargeted {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color.accentColor, lineWidth: 2)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                            receiveDrop(providers, to: parent)
                        }
                }
                if !transfers.isEmpty {
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(transfers) { TransferProgressView(transfer: $0) }
                        }
                    }
                    .frame(height: min(CGFloat(transfers.count) * 104, 208))
                }
                Divider()
                HStack {
                    if busy && transfers.isEmpty { ProgressView().controlSize(.small) }
                    Text(status.isEmpty ? "\(visible.count) items" : status)
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
                        PreviewTile(entry: item, device: device, store: previews, storage: storage ?? 0, dimension: 180)
                        LabeledContent("Kind", value: item.kind)
                        if let modified = item.modified {
                            LabeledContent("Modified", value: modified.formatted(date: .abbreviated, time: .shortened))
                        }
                        LabeledContent("Size", value: sizeLabel(item))
                    } else {
                        Text("Select one item to see its details.")
                    }
                }.padding()
            }
            .toolbar {
                Button("Back", systemImage: "chevron.left") {
                    goBack()
                }.help("Go to the enclosing folder").disabled(busy || folders.isEmpty)
                Button("Refresh", systemImage: "arrow.clockwise") { run { try await reconnect() } }.help("Refresh the device connection").disabled(busy)
                Button("Upload", systemImage: "square.and.arrow.up") { chooseUpload() }.help("Copy files or folders to Android").disabled(busy || storage == nil)
                Button("Download", systemImage: "square.and.arrow.down") { chooseDownload(selected) }.help("Copy selected items to this Mac").disabled(busy || selected.isEmpty)
                Button("New Folder", systemImage: "folder.badge.plus") {
                    renaming = nil
                    name = ""
                    naming = true
                }.help("Create a folder on Android").disabled(busy || storage == nil)
                Picker("View as", selection: $layout) {
                    ForEach(Layout.allCases, id: \.self) { option in
                        Label(option.rawValue, systemImage: option.symbol)
                            .labelStyle(.iconOnly)
                            .help("Show as \(option.rawValue.lowercased())")
                            .tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .help("Choose icons, list, columns, or gallery")
                Menu("View", systemImage: "slider.horizontal.3") {
                    Picker("Sort By", selection: $sort) {
                        ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Hidden Files", isOn: $showHidden)
                    Toggle("Inspector", isOn: $inspector)
                    Toggle("Calculate Folder Sizes", isOn: $calculateFolderSizes)
                        .help("Calculate recursive sizes while idle. Large directory trees can take time over USB.")
                    Button("Recent Activity") { showHistory = true }
                    Divider()
                    Toggle("Automatic USB Recovery on Launch", isOn: $automaticUSBRecovery)
                        .help("On launch, quits OpenMTP and Android File Transfer and stops the local ADB server. This can interrupt their transfers or debugging sessions.")
                    Button("Recover USB Connection") {
                        run { try await recoverUSBConnection() }
                    }
                    .disabled(busy)
                    .help("Release Android USB from known transfer apps and the local ADB server, then reconnect")
                    Button("Open macOS Permission Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }.help("Sorting, hidden files, inspector, and recent activity")
            }
        }
        .disabled(updater.isInstalling)
        .onAppear {
            if !automaticallyConnect { fileAreaFocused = true }
            let connectedDevice = device
            updater.prepareForRelaunch = { await connectedDevice.disconnect() }
        }
        .onChange(of: busy, initial: true) { _, value in
            updater.blockedByTransfer = value
            previews.suspended = value
        }
        .task {
            guard automaticallyConnect else { return }
            if !startupRecoveryDone {
                startupRecoveryDone = true
                if automaticUSBRecovery {
                    busy = true
                    status = "Releasing Android USB…"
                    let messages = await usbRecovery.recover()
                    messages.forEach { record($0) }
                    status = messages.isEmpty ? "" : "USB recovery checked. Connecting…"
                    busy = false
                }
            }
            while !Task.isCancelled {
                if !busy && !updater.isInstalling {
                    busy = true
                    let previous = storages
                    do {
                        storages = try await device.connect()
                        let session = await device.sessionIdentifier
                        let changedSession = deviceSession != session
                        deviceSession = session
                        if changedSession {
                            previews.reset()
                            directoryCache = [:]
                            folderSizes = [:]
                            folders = []
                            activeColumn = 0
                            selection = []
                            content.reset()
                        }
                        connectionMessage = DeviceError.unavailable.localizedDescription
                        status = ""
                        if !storages.contains(where: { $0.id == storage }) {
                            storage = storages.first?.id
                        } else if changedSession {
                            try await reload()
                        }
                    } catch {
                        storages = []
                        storage = nil
                        content.reset()
                        connectionMessage = error.localizedDescription
                        status = previous.isEmpty ? error.localizedDescription : "Device disconnected. \(error.localizedDescription)"
                    }
                    busy = false
                }
                do { try await Task.sleep(for: .seconds(6)) } catch { return }
            }
        }
        .task(id: "\(listingVersion)-\(calculateFolderSizes)-\(busy)") {
            if calculateFolderSizes && !busy { await measureFolders() }
        }
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { _, url in
            if url == nil { previews.clearLocalFiles() }
        }
        .onChange(of: selection) { _, ids in
            selectionObserver?(ids)
            if ids.count == 1 { keyboardAnchor = ids.first }
        }
        .onChange(of: layout) {
            activeColumn = folders.count
            renaming = nil
            selection = []
            keyboardAnchor = nil
        }
        .onChange(of: storage) {
            previews.reset()
            content.reset()
            directoryCache = [:]
            folderSizes = [:]
            folders = []
            activeColumn = 0
            selection = []
            if storage != nil { run { try await reload() } }
        }
        .alert("New Folder", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                guard let storage else { return }
                run {
                    try await device.makeFolder(name, storage: storage, parent: parent)
                    record("Created folder \(name)")
                    await invalidateContent()
                    try await reload()
                }
            }.disabled(name.isEmpty)
        }
        .confirmationDialog("Permanently delete the selected items?", isPresented: $deleting) {
            Button("Delete", role: .destructive) {
                let items = selected
                run {
                    for item in items { try await device.remove(item); record("Deleted \(item.name)") }
                    if let index = folders.firstIndex(where: { folder in items.contains { $0.id == folder.id } }) {
                        folders = Array(folders.prefix(index))
                        activeColumn = folders.count
                        selection = []
                        content.reset()
                    }
                    await invalidateContent()
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

    @ViewBuilder private var browserContent: some View {
        if layout == .columns { columnContent }
        else if loading || loadedParent != parent { loadingPlaceholder }
        else if visible.isEmpty {
            ContentUnavailableView(search.isEmpty ? "Empty Folder" : "No Results",
                                   systemImage: search.isEmpty ? "folder" : "magnifyingglass")
        } else if layout == .icons { iconContent }
        else if layout == .gallery { galleryContent }
        else { listContent }
    }

    private var columnContent: some View {
        ScrollViewReader { columns in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(0...folders.count, id: \.self) { index in
                        let container = index == 0 ? UInt32.max : folders[index - 1].id
                        let items = index == folders.count ? visible :
                            sortedItems(directoryCache[container] ?? [])
                        ScrollViewReader { reader in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                if index == folders.count && (loading || loadedParent != parent) {
                                    loadingPlaceholder
                                }
                                ForEach(items) { item in
                                    let highlighted = index < folders.count ? folders[index].id == item.id :
                                        selection.contains(item.id)
                                    itemRow(item, highlighted: highlighted, emphasized: index == activeColumn) { event in
                                        fileAreaFocused = true
                                        if event.clickCount == 2, !item.folder { quickLook(item) }
                                        else if index == folders.count,
                                                event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift) {
                                            select(item, event: event)
                                        } else if selection != [item.id] || index != activeColumn {
                                            columnSelect(item, index: index)
                                        }
                                    }
                                }
                            }.padding(6)
                        }
                        .onChange(of: selection) { _, ids in
                            if index == activeColumn, let id = keyboardAnchor ?? ids.first { reader.scrollTo(id) }
                        }
                        }
                        .frame(width: 225)
                        .id("column-\(index)")
                        Divider()
                    }
                    if let item = selected.first, !loading {
                        previewDetails(item).frame(width: 260)
                    }
                }
                .scrollTargetLayout()
            }
            .defaultScrollAnchor(.trailing, for: .sizeChanges)
            .onChange(of: activeColumn) { _, index in
                columns.scrollTo("column-\(index)", anchor: .leading)
            }
        }
    }

    private var iconContent: some View {
            GeometryReader { geometry in
            ScrollViewReader { reader in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 16) {
                    ForEach(visible) { item in
                        VStack(spacing: 6) {
                            PreviewTile(entry: item, device: device, store: previews, storage: storage ?? 0, dimension: 96)

                            editableName(item).lineLimit(2).multilineTextAlignment(.center)
                            Text(sizeLabel(item)).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 145)
                        .background(selection.contains(item.id) ? Color.accentColor.opacity(0.16) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay { if renaming?.id != item.id { dragSource(item) { select(item, event: $0) } } }
                        .id(item.id)
                        .contextMenu { actions([item]) }
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            receiveDrop(providers, to: item.folder ? item.id : parent)
                        }
                    }
                }.padding(18)
            }
            .onChange(of: selection) { _, ids in
                if let id = ids.first { reader.scrollTo(id) }
            }
            .onChange(of: geometry.size.width, initial: true) { _, width in
                gridColumns = max(1, Int((width - 36 + 8) / 138))
            }
            }
            }
    }

    private var galleryContent: some View {
            VStack(spacing: 10) {
                if let item = selected.first ?? visible.first {
                    PreviewTile(entry: item, device: device, store: previews, storage: storage ?? 0, dimension: 360)

                        .frame(maxHeight: .infinity)
                    Text(item.name).font(.headline)
                    Text("\(item.kind) · \(sizeLabel(item))").foregroundStyle(.secondary)
                }
                Divider()
                ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(visible) { item in
                            VStack {
                                PreviewTile(entry: item, device: device, store: previews, storage: storage ?? 0, dimension: 65)
    
                                editableName(item).lineLimit(1).font(.caption)
                            }
                            .frame(width: 105, height: 94)
                            .background(selection.contains(item.id) ? Color.accentColor.opacity(0.16) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .overlay { if renaming?.id != item.id { dragSource(item) { select(item, event: $0) } } }
                            .id(item.id)
                            .contextMenu { actions([item]) }
                            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                                receiveDrop(providers, to: item.folder ? item.id : parent)
                            }
                        }
                    }.padding(.horizontal, 10)
                }.frame(height: 108)
                .onChange(of: selection) { _, ids in
                    if let id = ids.first { reader.scrollTo(id) }
                }
                }
            }.padding(.top, 12)
    }

    private var listContent: some View {
            ScrollViewReader { reader in
            Table(visible, selection: $selection) {
                TableColumn("Name") { item in
                    HStack(spacing: 6) {
                        PreviewTile(entry: item, device: device, store: previews, storage: storage ?? 0, dimension: 20)
                        editableName(item)
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay { if renaming?.id != item.id { dragSource(item) { select(item, event: $0) } } }
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            receiveDrop(providers, to: item.folder ? item.id : parent)
                        }
                }
                TableColumn("Date Modified") { item in
                    Text(item.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                }
                TableColumn("Kind") { item in Text(item.kind) }
                TableColumn("Size") { item in Text(sizeLabel(item)) }
            }
            .contextMenu(forSelectionType: UInt32.self) { ids in
                actions(entries.filter { ids.contains($0.id) })
            }
            .onChange(of: selection) { _, ids in
                if let id = keyboardAnchor, ids.contains(id) { reader.scrollTo(id) }
            }
            }
    }

    private func itemRow(_ item: Entry, highlighted: Bool, emphasized: Bool, click: @escaping (NSEvent) -> Void) -> some View {
        HStack {
            PreviewTile(entry: item, device: device, store: previews, storage: storage ?? 0, dimension: 20)
            editableName(item).lineLimit(1)
                .foregroundStyle(highlighted && emphasized ? Color.white : Color.primary)
            Spacer()
            if item.folder { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
        }
        .padding(6)
        .background(highlighted ? (emphasized ? Color.accentColor : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .overlay { if renaming?.id != item.id { dragSource(item, click: click) } }
        .id(item.id)
        .contextMenu { actions([item]) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard item.folder else { return false }
            return receiveDrop(providers, to: item.id)
        }
    }

    private func dragSource(_ item: Entry, click: @escaping (NSEvent) -> Void) -> some View {
        let storageID = storage
        return FileDrag(symbol: item.symbol, title: item.name, nameArea: layout == .icons || layout == .gallery,
                        nameClick: { scheduleRename(item) }, key: handleNativeKey, click: { event in
            if event.clickCount > 1 { renameRequest?.cancel() }
            click(event)
        }) {
            guard storageID != nil, !busy else { return [] }
            return selection.contains(item.id) ? selected : [item]
        } export: { entry, destination in
            guard let storageID else { throw DeviceError.unavailable }
            await MainActor.run {
                activeExports += 1
                busy = true
            }
            do {
                try await download([entry], storage: storageID, to: destination.deletingLastPathComponent(),
                                   filename: destination.lastPathComponent)
                await MainActor.run {
                    activeExports -= 1
                    busy = activeExports > 0
                    if !busy { status = "" }
                }
            } catch {
                await MainActor.run {
                    activeExports -= 1
                    busy = activeExports > 0
                    if !busy { status = "" }
                }
                throw error
            }
        }
    }

    private func select(_ item: Entry, event: NSEvent) {
        fileAreaFocused = true
        keyboardAnchor = item.id
        if event.clickCount == 2 {
            if item.folder { open(item) } else { quickLook(item) }
        } else if event.modifierFlags.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) }
            else { selection.insert(item.id) }
        } else if event.modifierFlags.contains(.shift),
                  let anchor = visible.firstIndex(where: { selection.contains($0.id) }),
                  let endpoint = visible.firstIndex(where: { $0.id == item.id }) {
            let items = visible
            selection.formUnion(items[min(anchor, endpoint)...max(anchor, endpoint)].map(\.id))
        } else {
            selection = [item.id]
        }
    }

    private func byteCount(_ item: Entry) -> UInt64? {
        item.folder ? folderSizes[item.id] : UInt64(item.size)
    }

    private func sizeLabel(_ item: Entry) -> String {
        guard let size = byteCount(item) else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)
    }

    private func measureFolders() async {
        guard let storage else { return }
        let revision = listingVersion
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        for item in entries where item.folder {
            var remaining = [item.id]
            var visited = Set<UInt32>()
            var total: UInt64 = 0
            do {
                while let handle = remaining.popLast() {
                    try Task.checkCancellation()
                    guard !busy, revision == listingVersion, self.storage == storage else { return }
                    guard visited.insert(handle).inserted else { continue }
                    let children = try await device.list(storage: storage, parent: handle)
                    for child in children {
                        if child.folder { remaining.append(child.id) }
                        else { total += UInt64(child.size) }
                    }
                    await Task.yield()
                }
                try Task.checkCancellation()
                guard revision == listingVersion, self.storage == storage else { return }
                folderSizes[item.id] = total
            } catch is CancellationError {
                return
            } catch {
                continue
            }
        }
    }

    @ViewBuilder private func actions(_ items: [Entry]) -> some View {
        if let item = items.first, items.count == 1 {
            if item.folder { Button("Open") { open(item) }.disabled(busy) }
            Button("Rename") { beginRename(item) }.disabled(busy)
            Button("Quick Look") { quickLook(item) }.disabled(busy || item.folder)
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

    private var loadingPlaceholder: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100, maxHeight: .infinity)
        .accessibilityLabel("Loading folder contents")
    }

    private func previewDetails(_ item: Entry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PreviewTile(entry: item, device: device, store: previews, storage: storage ?? 0, dimension: 220)
                    .frame(maxWidth: .infinity)
                Text(item.name).font(.headline).textSelection(.enabled)
                Text(item.kind).foregroundStyle(.secondary)
                Divider()
                LabeledContent("Size", value: sizeLabel(item))
                if let width = item.pixelWidth, let height = item.pixelHeight {
                    LabeledContent("Dimensions", value: "\(width) × \(height)")
                }
                if let created = item.created {
                    LabeledContent("Created", value: created.formatted(date: .abbreviated, time: .shortened))
                }
                if item.folder, let contents = directoryCache[item.id] {
                    LabeledContent("Contains", value: "\(contents.count) items")
                }
                if let modified = item.modified {
                    LabeledContent("Modified", value: modified.formatted(date: .abbreviated, time: .shortened))
                }
                if !item.folder {
                    Button("Quick Look", systemImage: "eye") { quickLook(item) }.disabled(busy)
                }
            }.padding(16)
        }
    }

    @ViewBuilder private func editableName(_ item: Entry) -> some View {
        if renaming?.id == item.id {
            InlineFileName(name: item.name, isFolder: item.folder) { result in
                renaming = nil
                fileAreaFocused = true
                guard let result, result != item.name else { return }
                run {
                    try await device.rename(item, to: result)
                    if let index = folders.firstIndex(where: { $0.id == item.id }) {
                        folders[index] = Entry(id: item.id, name: result, folder: item.folder,
                                               size: item.size, modified: item.modified, created: item.created,
                                               pixelWidth: item.pixelWidth, pixelHeight: item.pixelHeight)
                    }
                    record("Renamed \(item.name) to \(result)")
                    await invalidateContent()
                    try await reload()
                }
            }
        } else {
            Text(item.name)
        }
    }

    private func scheduleRename(_ item: Entry) {
        renameRequest?.cancel()
        guard selection == [item.id], !busy else { return }
        let directory = parent
        renameRequest = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            guard selection == [item.id], parent == directory, !busy else { return }
            beginRename(item)
        }
    }

    private func beginRename(_ item: Entry) {
        guard !busy else { return }
        selection = [item.id]
        renaming = item
    }

    private func invalidateContent() async {
        previewURL = nil
        directoryCache = [:]
        folderSizes = [:]
        previews.reset()
        await device.invalidateDirectories()
    }

    private func quickLook(_ item: Entry) {
        guard !busy, !item.folder, let storage else { return }
        #if DEBUG
        if let testPreviewFile { previewURL = testPreviewFile; return }
        #endif
        run {
            let transfer = addTransfer("Preparing Quick Look")
            transfer.begin(TransferSize(bytes: UInt64(item.size), files: 1))
            do {
                previewURL = try await previews.localFile(item, storage: storage, device: device) { transfer.update($0) }
                transfer.finish()
            } catch {
                transfer.finish(error: error)
                throw error
            }
        }
    }

    private func handleNativeKey(_ event: NSEvent) -> Bool {
        // FileDrag owns mouse interaction; return keyboard focus to the SwiftUI file area.
        fileAreaFocused = true
        return navigateKey(code: event.keyCode, shift: event.modifierFlags.contains(.shift),
                           command: event.modifierFlags.contains(.command))
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let code: UInt16
        switch press.key {
        case .upArrow: code = 126
        case .downArrow: code = 125
        case .leftArrow: code = 123
        case .rightArrow: code = 124
        case .return: code = 36
        case .space: code = 49
        default: return .ignored
        }
        return navigateKey(code: code, shift: press.modifiers.contains(.shift),
                           command: press.modifiers.contains(.command)) ? .handled : .ignored
    }

    private func navigateKey(code: UInt16, shift: Bool, command: Bool) -> Bool {
        renameRequest?.cancel()
        guard renaming == nil else { return false }
        guard [123, 124, 125, 126, 36, 49].contains(code) else { return false }
        guard !busy else { return true }
        if code == 49 {
            if previewURL != nil { previewURL = nil }
            else if let item = selected.first { quickLook(item) }
            return true
        }
        if code == 36 {
            if let item = selected.first { beginRename(item) }
            return true
        }
        if command && code == 126 { goBack(); return true }
        if command && code == 125 {
            if let item = selected.first, item.folder { open(item) }
            return true
        }
        if layout == .columns {
            let index = min(activeColumn, folders.count)
            if code == 123 {
                guard index > 0 else { return true }
                activeColumn = index - 1
                selection = [folders[index - 1].id]
                keyboardAnchor = folders[index - 1].id
                return true
            }
            if code == 124 {
                if index < folders.count {
                    activeColumn = index + 1
                    let container = folders[index].id
                    if let first = sortedItems(directoryCache[container] ?? []).first {
                        columnSelect(first, index: index + 1)
                    }
                } else if let item = selected.first, item.folder { columnSelect(item, index: index) }
                return true
            }
            let container = index == 0 ? UInt32.max : folders[index - 1].id
            let items = index == folders.count ? visible : sortedItems(directoryCache[container] ?? [])
            let current = index < folders.count ? folders[index].id : keyboardAnchor ?? selection.first
            if let id = FileNavigation.destination(ids: items.map(\.id), selected: current, delta: code == 126 ? -1 : 1),
               let item = items.first(where: { $0.id == id }) {
                if shift {
                    var ids = selection
                    if let current { ids.insert(current) }
                    ids.insert(id)
                    if index < folders.count { navigate(to: Array(folders.prefix(index)), activeAt: index) }
                    selection = ids
                    keyboardAnchor = id
                } else { columnSelect(item, index: index) }
            }
            return true
        }
        let delta: Int
        if code == 126 { delta = layout == .icons ? -gridColumns : -1 }
        else if code == 125 { delta = layout == .icons ? gridColumns : 1 }
        else if layout == .icons || layout == .gallery { delta = code == 123 ? -1 : 1 }
        else { return false }
        if let id = FileNavigation.destination(ids: visible.map(\.id), selected: keyboardAnchor ?? selection.first, delta: delta) {
            if shift { selection.insert(id) } else { selection = [id] }
            keyboardAnchor = id
        }
        return true
    }

    private func sortedItems(_ items: [Entry]) -> [Entry] {
        items.filter { showHidden || !$0.name.hasPrefix(".") }
            .sorted { lhs, rhs in
                if lhs.folder != rhs.folder { return lhs.folder }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private func columnSelect(_ item: Entry, index: Int) {
        guard !busy else { return }
        if item.folder {
            navigate(to: Array(folders.prefix(index)) + [item], activeAt: index)
            selection = [item.id]
        } else {
            if index < folders.count {
                navigate(to: Array(folders.prefix(index)), selecting: item.id, activeAt: index)
            } else {
                selection = [item.id]
                keyboardAnchor = item.id
                activeColumn = index
            }
        }
    }

    private func open(_ entry: Entry) {
        guard entry.folder, !busy else { return }
        navigate(to: folders + [entry])
    }

    private func navigate(to path: [Entry], selecting id: UInt32? = nil, activeAt: Int? = nil) {
        guard !busy else { return }
        renameRequest?.cancel()
        renaming = nil
        folders = path
        activeColumn = activeAt ?? path.count
        selection = id.map { [$0] } ?? []
        keyboardAnchor = id
        search = ""
        content.begin(parent: parent, cached: directoryCache[parent])
        listingVersion += 1 // Cancels recursive size work before issuing navigation I/O.
        run { try await reload() }
    }

    private func goBack() {
        guard let folder = folders.last else { return }
        navigate(to: Array(folders.dropLast()), selecting: folder.id)
    }

    private func reload() async throws {
        guard let storage else { return }
        let requestedParent = parent
        content.begin(parent: requestedParent, cached: directoryCache[requestedParent])
        do {
            let result: [Entry]
            #if DEBUG
            if !automaticallyConnect {
                result = directoryCache[requestedParent] ?? []
            } else {
                result = try await device.list(storage: storage, parent: requestedParent)
            }
            #else
            result = try await device.list(storage: storage, parent: requestedParent)
            #endif
            guard self.storage == storage, parent == requestedParent else { return }
            guard content.receive(result, parent: requestedParent) else { return }
            directoryCache[requestedParent] = result
            if directoryCache.count > 64 {
                let ancestors = Set([UInt32.max] + folders.map(\.id))
                for key in Array(directoryCache.keys) where !ancestors.contains(key) && directoryCache.count > 64 {
                    directoryCache.removeValue(forKey: key)
                }
            }
            listingVersion += 1
        } catch {
            content.receive([], parent: requestedParent)
            selection = []
            throw error
        }
        if layout != .columns || activeColumn == folders.count {
            selection.formIntersection(entries.map(\.id))
        }
    }

    private func recoverUSBConnection() async throws {
        await device.disconnect()
        storages = []
        storage = nil
        content.reset()
        selection = []
        status = "Releasing Android USB…"
        let messages = await usbRecovery.recover()
        messages.forEach { record($0) }
        do {
            storages = try await device.connect()
            deviceSession = await device.sessionIdentifier
            storage = storages.first?.id
            connectionMessage = DeviceError.unavailable.localizedDescription
        } catch {
            connectionMessage = error.localizedDescription
            throw error
        }
    }

    private func reconnect() async throws {
        previews.reset()
        directoryCache = [:]
        folderSizes = [:]
        content.reset()
        await device.disconnect()
        storages = try await device.connect()
        deviceSession = await device.sessionIdentifier
        if !storages.contains(where: { $0.id == storage }) { storage = storages.first?.id }
        else { try await reload() }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = activeExports > 0; status = "" }
            do { try await operation() }
            catch { failure = error.localizedDescription; try? await reload() }
        }
    }

    private func chooseUpload() {
        guard storage != nil, !busy else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = true
        guard picker.runModal() == .OK else { return }
        _ = uploadDropped(picker.urls, to: parent)
    }

    private func receiveDrop(_ providers: [NSItemProvider], to destination: UInt32) -> Bool {
        guard let storage, !busy else { return false }
        let accepted = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !accepted.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in accepted {
                let url = await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                    _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                        continuation.resume(returning: data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
                    }
                }
                if let url { urls.append(url) }
            }
            guard self.storage == storage, uploadDropped(urls, to: destination) else {
                failure = "The dropped items could not be opened or the device is busy."
                return
            }
        }
        return true
    }

    @discardableResult
    private func uploadDropped(_ urls: [URL], to destination: UInt32) -> Bool {
        let urls = urls.filter(\.isFileURL)
        guard let storage, !busy, !urls.isEmpty else { return false }
        run {
            let transfer = addTransfer("Uploading to Android")
            do {
                let size = try await device.uploadSize(urls)
                transfer.begin(size)
                for url in urls {
                    status = "Uploading \(url.lastPathComponent)"
                    try await device.upload(url, storage: storage, parent: destination) { transfer.update($0) }
                    record("Uploaded \(url.lastPathComponent)")
                }
            } catch {
                transfer.finish(error: error)
                throw error
            }
            transfer.finish()
            await invalidateContent()
            try await reload()
        }
        return true
    }

    private func chooseDownload(_ items: [Entry]) {
        guard let storage, !busy else { return }
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        guard picker.runModal() == .OK, let target = picker.url else { return }
        run { try await download(items, storage: storage, to: target) }
    }

    @MainActor
    private func addTransfer(_ title: String) -> TransferProgress {
        // Keep active transfers and the most recent completed operations.
        if transfers.count >= 10 {
            transfers.removeAll {
                switch $0.snapshot().phase {
                case .complete, .failed: true
                default: false
                }
            }
        }
        let transfer = TransferProgress(title: title)
        transfers.insert(transfer, at: 0)
        return transfer
    }

    @MainActor
    private func download(_ items: [Entry], storage: UInt32, to target: URL,
                          filename: String? = nil) async throws {
        let transfer = addTransfer("Downloading to Mac")
        do {
            let size = try await device.downloadSize(items, storage: storage)
            transfer.begin(size)
            for item in items {
                status = "Downloading \(item.name)"
                try await device.download(item, storage: storage, into: target,
                                          filename: filename) { transfer.update($0) }
                record("Downloaded \(item.name)")
            }
            transfer.finish()
        } catch {
            transfer.finish(error: error)
            throw error
        }
    }

    private func record(_ event: String) {
        history = Array(([event] + history).prefix(100))
    }
}

private struct PreviewTile: View {
    let entry: Entry
    let device: Device
    @ObservedObject var store: PreviewStore
    let storage: UInt32
    let dimension: CGFloat
    @State private var preview: NSImage?

    var body: some View {
        Group {
            if let preview {
                Image(nsImage: preview).resizable().scaledToFit()
            } else {
                Image(systemName: entry.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: min(dimension * 0.72, 125)))
                    .foregroundStyle(entry.folder ? Color.cyan : Color.secondary)
            }
        }
        .frame(width: dimension, height: dimension)
        .help("\(entry.name) — \(entry.kind)")
        .task(id: "\(store.generation)-\(storage)-\(entry.id)-\(entry.name)-\(entry.size)") {
            preview = nil
            guard !entry.folder else { return }
            preview = await store.image(entry, storage: storage, device: device)
        }
    }
}
