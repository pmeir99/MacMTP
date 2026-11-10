import AppKit
import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers
import ImageIO

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
    private var selected: [Entry] { entries.filter { selection.contains($0.id) } }
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
                                           description: Text("Unlock your Android device and select USB File Transfer."))
                } else {
                    browserContent
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
                        LabeledContent("Size", value: sizeLabel(item))
                    } else {
                        Text("Select one item to see its details.")
                    }
                }.padding()
            }
            .toolbar {
                Button("Back", systemImage: "chevron.left") {
                    folders.removeLast()
                    run { try await reload() }
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
                    Button("Recent Activity") { showHistory = true }
                }.help("Sorting, hidden files, inspector, and recent activity")
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
        .task(id: listingVersion) { await measureFolders() }
        .onChange(of: storage) {
            directoryCache = [:]
            folderSizes = [:]
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

    @ViewBuilder private var browserContent: some View {
        if layout == .columns {
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(0...folders.count, id: \.self) { index in
                        let container = index == 0 ? UInt32.max : folders[index - 1].id
                        let items = index == folders.count ? visible :
                            (directoryCache[container] ?? []).filter { showHidden || !$0.name.hasPrefix(".") }
                                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(items) { item in
                                    let highlighted = index < folders.count ? folders[index].id == item.id :
                                        selection.contains(item.id)
                                    itemRow(item, highlighted: highlighted) { event in
                                        if item.folder, !busy {
                                            folders = Array(folders.prefix(index)) + [item]
                                            selection = []
                                            run { try await reload() }
                                        } else if index == folders.count {
                                            select(item, event: event)
                                        }
                                    }
                                }
                            }.padding(6)
                        }
                        .frame(width: 225)
                        Divider()
                    }
                }
                .scrollTargetLayout()
            }
            .defaultScrollAnchor(.trailing, for: .sizeChanges)
        } else if visible.isEmpty {
            ContentUnavailableView(search.isEmpty ? "Empty Folder" : "No Results",
                                   systemImage: search.isEmpty ? "folder" : "magnifyingglass")
        } else if layout == .icons {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 16) {
                    ForEach(visible) { item in
                        VStack(spacing: 6) {
                            PreviewTile(entry: item, device: device, dimension: 96)
                                .id(listingVersion)
                            Text(item.name).lineLimit(2).multilineTextAlignment(.center)
                            Text(sizeLabel(item)).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 145)
                        .background(selection.contains(item.id) ? Color.accentColor.opacity(0.16) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay { dragSource(item) { select(item, event: $0) } }
                        .contextMenu { actions([item]) }
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            receiveDrop(providers, to: item.folder ? item.id : parent)
                        }
                    }
                }.padding(18)
            }
        } else if layout == .gallery {
            VStack(spacing: 10) {
                if let item = selected.first ?? visible.first {
                    PreviewTile(entry: item, device: device, dimension: 360)
                        .id(listingVersion)
                        .frame(maxHeight: .infinity)
                    Text(item.name).font(.headline)
                    Text(sizeLabel(item)).foregroundStyle(.secondary)
                }
                Divider()
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(visible) { item in
                            VStack {
                                PreviewTile(entry: item, device: device, dimension: 65)
                                    .id(listingVersion)
                                Text(item.name).lineLimit(1).font(.caption)
                            }
                            .frame(width: 105, height: 94)
                            .background(selection.contains(item.id) ? Color.accentColor.opacity(0.16) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .overlay { dragSource(item) { select(item, event: $0) } }
                            .contextMenu { actions([item]) }
                            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                                receiveDrop(providers, to: item.folder ? item.id : parent)
                            }
                        }
                    }.padding(.horizontal, 10)
                }.frame(height: 108)
            }.padding(.top, 12)
        } else {
            Table(visible, selection: $selection) {
                TableColumn("Name") { item in
                    Label(item.name, systemImage: item.folder ? "folder.fill" : "doc")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay { dragSource(item) { select(item, event: $0) } }
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            receiveDrop(providers, to: item.folder ? item.id : parent)
                        }
                }
                TableColumn("Date Modified") { item in
                    Text(item.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                }
                TableColumn("Kind") { item in Text(item.folder ? "Folder" : "File") }
                TableColumn("Size") { item in Text(sizeLabel(item)) }
            }
            .contextMenu(forSelectionType: UInt32.self) { ids in
                actions(entries.filter { ids.contains($0.id) })
            }
        }
    }

    private func itemRow(_ item: Entry, highlighted: Bool, click: @escaping (NSEvent) -> Void) -> some View {
        HStack {
            Label(item.name, systemImage: item.folder ? "folder.fill" : "doc")
                .lineLimit(1)
            Spacer()
            if item.folder { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
        }
        .padding(6)
        .background(highlighted ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .overlay { dragSource(item, click: click) }
        .contextMenu { actions([item]) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard item.folder else { return false }
            return receiveDrop(providers, to: item.id)
        }
    }

    private func dragSource(_ item: Entry, click: @escaping (NSEvent) -> Void) -> some View {
        let storageID = storage
        return FileDrag(symbol: item.folder ? "folder.fill" : "doc", title: item.name, click: click) {
            guard storageID != nil, !busy else { return [] }
            return selection.contains(item.id) ? selected : [item]
        } export: { entry, destination in
            guard let storageID else { throw DeviceError.unavailable }
            try await device.download(entry, storage: storageID, into: destination.deletingLastPathComponent(),
                                      filename: destination.lastPathComponent) { _ in }
        }
    }

    private func select(_ item: Entry, event: NSEvent) {
        if event.clickCount == 2, item.folder {
            open(item)
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
        for item in entries where item.folder {
            var remaining = [item.id]
            var visited = Set<UInt32>()
            var total: UInt64 = 0
            do {
                while let handle = remaining.popLast() {
                    try Task.checkCancellation()
                    guard revision == listingVersion, self.storage == storage else { return }
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
        selection = []
        run { try await reload() }
    }

    private func reload() async throws {
        guard let storage else { return }
        do {
            entries = try await device.list(storage: storage, parent: parent)
            directoryCache[parent] = entries
            folderSizes = [:]
            listingVersion += 1
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
            for url in urls {
                transferred = 0
                status = "Uploading \(url.lastPathComponent)"
                try await device.upload(url, storage: storage, parent: destination) { count in
                    Task { @MainActor in
                        if busy { transferred = count }
                    }
                }
                record("Uploaded \(url.lastPathComponent)")
            }
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

private struct PreviewTile: View {
    let entry: Entry
    let device: Device
    let dimension: CGFloat
    @State private var preview: NSImage?

    var body: some View {
        Group {
            if let preview {
                Image(nsImage: preview).resizable().scaledToFit()
            } else {
                Image(systemName: entry.folder ? "folder.fill" : "doc")
                    .font(.system(size: min(dimension * 0.52, 125)))
                    .foregroundStyle(entry.folder ? Color.accentColor : Color.secondary)
            }
        }
        .frame(width: dimension, height: dimension)
        .help(entry.name)
        .task(id: entry.id) { await load() }
    }

    private func load() async {
        preview = nil
        guard !entry.folder,
              let type = UTType(filenameExtension: (entry.name as NSString).pathExtension),
              type.conforms(to: .image) || type.conforms(to: .movie) else { return }
        do {
            try Task.checkCancellation()
            let data = try await device.thumbnail(entry)
            try Task.checkCancellation()
            guard !data.isEmpty else { return }
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 720
               ] as CFDictionary) {
                preview = NSImage(cgImage: image, size: .zero)
            } else if type.conforms(to: .movie) {
                let suffix = type.preferredFilenameExtension ?? "mov"
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
                defer { try? FileManager.default.removeItem(at: url) }
                try data.write(to: url)
                let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 720, height: 720),
                                                           scale: 1, representationTypes: .thumbnail)
                let result = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
                try Task.checkCancellation()
                preview = result.nsImage
            }
        } catch {
            // Keep the system symbol when the device or Quick Look cannot preview the file.
        }
    }
}
