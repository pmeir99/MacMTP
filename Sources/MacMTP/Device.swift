import Foundation
import USB
import FinderSupport

struct Storage: Identifiable, Sendable {
    let id: UInt32
    let name: String
    var kind: Kind = .unknown

    /// Preserve the device's order within each group, including unknown storage types.
    static func ordered(_ storages: [Storage]) -> [Storage] {
        storages.filter { $0.kind == .internalStorage }
        + storages.filter { $0.kind == .removable }
        + storages.filter { $0.kind == .unknown }
    }

    enum Kind: Equatable, Sendable {
        case internalStorage, removable, unknown

        init(storageType: UInt16) {
            switch storageType {
            case 0x0001, 0x0003: self = .internalStorage
            case 0x0002, 0x0004: self = .removable
            default: self = .unknown
            }
        }

        var symbol: String {
            switch self {
            case .internalStorage: "internaldrive"
            case .removable: "sdcard"
            case .unknown: "externaldrive"
            }
        }

        var description: String {
            switch self {
            case .internalStorage: "Internal storage"
            case .removable: "Removable storage"
            case .unknown: "Device storage"
            }
        }
    }
}

struct Entry: Identifiable, Sendable {
    let id: UInt32
    let name: String
    let folder: Bool
    let size: UInt32
    let modified: Date?
    var created: Date? = nil
    var pixelWidth: UInt32? = nil
    var pixelHeight: UInt32? = nil
}

enum DeviceError: LocalizedError {
    case unavailable, interfaceBusy, usbAccessDenied, interfaceAccessDenied, malformed, tooLarge, unsafeName
    case transport(Int32), rejected(UInt16)

    static func openingUSB(_ status: Int32, stage: Int32 = 0, driverActive: Bool = false) -> DeviceError {
        switch status {
        case -6: .interfaceBusy
        case -3 where stage >= 2: driverActive ? .interfaceBusy : .interfaceAccessDenied
        case -3: .usbAccessDenied
        case -4: .unavailable
        default: .transport(status)
        }
    }

    var errorDescription: String? {
        switch self {
        case .unavailable: "Unlock your Android device and select USB File Transfer."
        case .interfaceBusy:
            "An app or macOS USB driver is holding the phone’s file-transfer interface. Use Recover USB, then reconnect the phone in File Transfer mode."
        case .usbAccessDenied:
            "MacMTP could not open the USB device. Unlock the phone, select File Transfer (MTP), then reconnect the USB cable."
        case .interfaceAccessDenied:
            "macOS blocked the phone’s file-transfer interface. Recover USB or close other apps using the phone, then reconnect in File Transfer mode."
        case .malformed: "The device sent an invalid MTP response. Reconnect the device and try again."
        case .tooLarge: "This operation exceeds the supported MTP size."
        case .unsafeName: "The file or folder name is invalid."
        case .transport(let code): "USB communication failed (\(code)). Check the cable and reconnect."
        case .rejected(let code): "The device rejected the operation (0x\(String(code, radix: 16)))."
        }
    }
}

private extension Data {
    mutating func put<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func putName(_ value: String) throws {
        guard value.utf16.count < 255 else { throw DeviceError.unsafeName }
        append(UInt8(value.utf16.count + 1))
        for unit in value.utf16 { put(unit) }
        put(UInt16(0))
    }
}

private struct Reader {
    let data: Data
    var offset = 0

    mutating func take<T: FixedWidthInteger>(_ type: T.Type = T.self) throws -> T {
        guard data.count - offset >= MemoryLayout<T>.size else { throw DeviceError.malformed }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        offset += MemoryLayout<T>.size
        return T(littleEndian: value)
    }

    mutating func string() throws -> String {
        let count = Int(try take(UInt8.self))
        if count == 0 { return "" }
        let units = try (0..<count).map { _ in try take(UInt16.self) }
        guard units.last == 0 else { throw DeviceError.malformed }
        return String(decoding: units.dropLast(), as: UTF16.self)
    }

    mutating func handles() throws -> [UInt32] {
        let count = Int(try take(UInt32.self))
        guard count <= (data.count - offset) / 4 else { throw DeviceError.malformed }
        return try (0..<count).map { _ in try take() }
    }
}

/// StorageInfo reports fixed/removable media independently of a user-editable name.
enum StorageMetadata {
    static func decode(_ data: Data, id: UInt32) throws -> Storage {
        var info = Reader(data: data)
        let kind = Storage.Kind(storageType: try info.take(UInt16.self))
        info.offset = 26
        let description = try info.string()
        let volume = (try? info.string()) ?? ""
        let name = description.isEmpty ? (volume.isEmpty ? kind.description : volume) : description
        return Storage(id: id, name: name, kind: kind)
    }
}

/// Decodes the fixed fields defined by the MTP ObjectInfo dataset, then its UTF-16 strings.
enum ObjectMetadata {
    static func decode(_ data: Data, handle: UInt32, timestamp: DateFormatter) throws -> Entry {
        var info = Reader(data: data, offset: 4)
        let format = try info.take(UInt16.self)
        _ = try info.take(UInt16.self)
        let size = try info.take(UInt32.self)
        info.offset = 26
        let width = try info.take(UInt32.self)
        let height = try info.take(UInt32.self)
        info.offset = 52
        let name = try info.string()
        let created = (try? info.string()).flatMap { timestamp.date(from: String($0.prefix(15))) }
        let modified = (try? info.string()).flatMap { timestamp.date(from: String($0.prefix(15))) }
        return Entry(id: handle, name: name, folder: format == 0x3001, size: size, modified: modified,
                     created: created, pixelWidth: width > 0 ? width : nil, pixelHeight: height > 0 ? height : nil)
    }
}

actor Device {
    private(set) var sessionIdentifier = UUID()
    private var connection: OpaquePointer?
    private var supportedOperations: Set<UInt16> = []
    private var sequence: UInt32 = 0
    private var cachedDirectories: [String: (date: Date, entries: [Entry])] = [:]
    private var received = Data()
    private let block = 256 * 1024
    private let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter
    }()
    private struct Header {
        let size: Int
        let type: UInt16
        let code: UInt16
        let transaction: UInt32
    }

    deinit { mac_usb_close(connection) }

    func disconnect() {
        if connection != nil { _ = try? exchange(0x1003) }
        reset()
    }

    private func reset() {
        sessionIdentifier = UUID()
        mac_usb_close(connection)
        connection = nil
        received.removeAll()
        supportedOperations.removeAll()
        cachedDirectories.removeAll()
    }

    func connect(recovering target: USBResetTarget? = nil) throws -> [Storage] {
        if connection == nil {
            var status: Int32 = 0
            var diagnostics = MacUSBDiagnostics()
            let port: OpaquePointer?
            if let target {
                var identity = target.diagnostic
                port = mac_usb_open_recovering(&status, &diagnostics, &identity)
            } else {
                port = mac_usb_open_with_diagnostics(&status, &diagnostics)
            }
            guard let port else { throw USBOpenFailure(status: status, diagnostics: diagnostics) }
            connection = port
            sequence = 0
            do {
                var info = Reader(data: try exchange(0x1001).0, offset: 2)
                let extensionID = try info.take(UInt32.self)
                _ = try info.take(UInt16.self)
                let extensions = try info.string()
                guard extensionID == 6 || extensions.localizedCaseInsensitiveContains("MTP") else {
                    throw DeviceError.unavailable
                }
                _ = try? info.take(UInt16.self) // Functional mode.
                if let count = try? info.take(UInt32.self), count <= 65_536 {
                    supportedOperations = Set((0..<count).compactMap { _ in try? info.take(UInt16.self) })
                }
                sequence = 0
                _ = try exchange(0x1002, [1])
            }
            catch { reset(); throw error }
        }
        var list = Reader(data: try exchange(0x1004).0)
        return try Storage.ordered(list.handles().map { id in
            try StorageMetadata.decode(exchange(0x1005, [id]).0, id: id)
        })
    }

    func invalidateDirectories() { cachedDirectories.removeAll() }

    func list(storage: UInt32, parent: UInt32) throws -> [Entry] {
        try Task.checkCancellation()
        let key = "\(storage):\(parent)"
        if let cached = cachedDirectories[key], Date().timeIntervalSince(cached.date) < 15 { return cached.entries }
        let result = try readDirectory(storage: storage, parent: parent)
        if cachedDirectories.count >= 64,
           let oldest = cachedDirectories.min(by: { $0.value.date < $1.value.date })?.key {
            cachedDirectories.removeValue(forKey: oldest)
        }
        cachedDirectories[key] = (Date(), result)
        return result
    }

    private func readDirectory(storage: UInt32, parent: UInt32) throws -> [Entry] {
        var handles = Reader(data: try exchange(0x1007, [storage, 0, parent]).0)
        return try handles.handles().map { handle in
            try Task.checkCancellation()
            return try ObjectMetadata.decode(try exchange(0x1008, [handle]).0, handle: handle, timestamp: timestamp)
        }
    }

    func remove(_ entry: Entry) throws {
        cachedDirectories.removeAll()
        _ = try exchange(0x100B, [entry.id, 0])
    }

    func rename(_ entry: Entry, to name: String) throws {
        cachedDirectories.removeAll()
        try validate(name)
        var payload = Data()
        try payload.putName(name)
        _ = try exchange(0x9804, [entry.id, 0xDC07], payload: payload)
    }

    func makeFolder(_ name: String, storage: UInt32, parent: UInt32) throws {
        _ = try create(name, storage: storage, parent: parent, size: 0, folder: true)
    }

    func uploadSize(_ urls: [URL]) throws -> TransferSize {
        var total = TransferSize()
        for url in urls {
            let attributes = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey,
                                                              .isSymbolicLinkKey, .fileSizeKey])
            guard attributes.isSymbolicLink != true else { throw DeviceError.unsafeName }
            if attributes.isDirectory == true {
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                total.add(try uploadSize(children))
            } else {
                guard attributes.isRegularFile == true, let size = attributes.fileSize, size >= 0,
                      size <= Int(UInt32.max) - 12 else { throw DeviceError.tooLarge }
                total.bytes += UInt64(size)
                total.files += 1
            }
        }
        return total
    }

    func downloadSize(_ entries: [Entry], storage: UInt32) throws -> TransferSize {
        var visited = Set<UInt32>()
        return try downloadSize(entries, storage: storage, visited: &visited)
    }

    private func downloadSize(_ entries: [Entry], storage: UInt32,
                              visited: inout Set<UInt32>) throws -> TransferSize {
        var total = TransferSize()
        for entry in entries {
            guard visited.insert(entry.id).inserted else { throw DeviceError.malformed }
            if entry.folder {
                let children = try list(storage: storage, parent: entry.id)
                total.add(try downloadSize(children, storage: storage, visited: &visited))
            } else {
                total.bytes += UInt64(entry.size)
                total.files += 1
            }
        }
        return total
    }

    func upload(_ url: URL, storage: UInt32, parent: UInt32, progress: @Sendable (TransferEvent) -> Void) throws {
        try Task.checkCancellation()
        let attributes = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isSymbolicLink != true else { throw DeviceError.unsafeName }
        if attributes.isDirectory == true {
            let handle = try create(url.lastPathComponent, storage: storage, parent: parent, size: 0, folder: true)
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try upload(child, storage: storage, parent: handle, progress: progress)
            }
        } else {
            guard attributes.isRegularFile == true, let size = attributes.fileSize, size >= 0,
                  size <= Int(UInt32.max) - 12 else { throw DeviceError.tooLarge }
            progress(.file(url.lastPathComponent))
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let handle = try create(url.lastPathComponent, storage: storage, parent: parent, size: UInt32(size), folder: false)
            do {
                _ = try exchange(0x100D, upload: (file, size)) { progress(.bytes($0)) }
                progress(.finishedFile)
            } catch {
                if connection != nil { _ = try? exchange(0x100B, [handle, 0]) }
                throw error
            }
        }
    }

    func thumbnail(_ entry: Entry) throws -> Data {
        try Task.checkCancellation()
        do {
            let thumbnail = try exchange(0x100A, [entry.id]).0
            if !thumbnail.isEmpty { return thumbnail }
        } catch DeviceError.rejected(_) {}
        guard entry.size <= 24 * 1024 * 1024 else { return Data() }
        return try exchange(0x1009, [entry.id]).0
    }

    func download(_ entry: Entry, storage: UInt32, into folder: URL,
                  filename: String? = nil, progress: @Sendable (TransferEvent) -> Void) throws {
        try Task.checkCancellation()
        try validate(entry.name)
        let name = filename ?? entry.name
        try validate(name)
        let target = folder.appendingPathComponent(name, isDirectory: entry.folder)
        if entry.folder {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            for child in try list(storage: storage, parent: entry.id) {
                try download(child, storage: storage, into: target, progress: progress)
            }
        } else {
            progress(.file(name))
            let temporary = folder.appendingPathComponent(".macmtp-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { try? FileManager.default.removeItem(at: temporary) }
            let file = try FileHandle(forWritingTo: temporary)
            defer { try? file.close() }
            _ = try exchange(0x1009, [entry.id], download: file) { progress(.bytes($0)) }
            try file.close()
            try FileManager.default.moveItem(at: temporary, to: target)
            progress(.finishedFile)
        }
    }

    private func validate(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.utf8.contains(0), name.utf16.count < 255 else { throw DeviceError.unsafeName }
    }

    private func create(_ name: String, storage: UInt32, parent: UInt32, size: UInt32, folder: Bool) throws -> UInt32 {
        cachedDirectories.removeAll()
        try validate(name)
        let parent = parent == UInt32.max ? 0 : parent
        var info = Data()
        info.put(storage)
        info.put(UInt16(folder ? 0x3001 : 0x3000))
        info.put(UInt16(0))
        info.put(size)
        info.append(Data(repeating: 0, count: 26))
        info.put(parent)
        info.put(UInt16(folder ? 1 : 0))
        info.append(Data(repeating: 0, count: 8))
        try info.putName(name)
        info.append(contentsOf: [0, 0, 0])
        let result = try exchange(0x100C, [storage, parent == 0 ? UInt32.max : parent], payload: info).1
        guard result.count >= 3, result[2] != 0 else { throw DeviceError.malformed }
        return result[2]
    }

    private func header(_ size: Int, _ type: UInt16, _ code: UInt16, _ transaction: UInt32) -> Data {
        var data = Data()
        data.put(UInt32(size + 12))
        data.put(type)
        data.put(code)
        data.put(transaction)
        return data
    }

    private func write(_ data: Data, to port: OpaquePointer) throws {
        let count = data.withUnsafeBytes {
            mac_usb_write(port, $0.bindMemory(to: UInt8.self).baseAddress, Int32($0.count))
        }
        guard count == data.count else { throw DeviceError.transport(count) }
    }

    private func read(_ count: Int, from port: OpaquePointer) throws -> Data {
        var emptyPackets = 0
        while received.count < count {
            var buffer = Data(count: block)
            let actual = buffer.withUnsafeMutableBytes {
                mac_usb_read(port, $0.bindMemory(to: UInt8.self).baseAddress, Int32($0.count))
            }
            guard actual >= 0 else { throw DeviceError.transport(actual) }
            if actual == 0 {
                emptyPackets += 1
                guard emptyPackets < 3 else { throw DeviceError.malformed }
            } else {
                received.append(buffer.prefix(Int(actual)))
            }
        }
        let result = Data(received.prefix(count))
        received.removeFirst(count)
        return result
    }

    private func readHeader(from port: OpaquePointer) throws -> Header {
        var reader = Reader(data: try read(12, from: port))
        let length = Int(try reader.take(UInt32.self))
        guard length >= 12 else { throw DeviceError.malformed }
        return try Header(size: length - 12, type: reader.take(), code: reader.take(), transaction: reader.take())
    }

    private func exchange(_ operation: UInt16, _ parameters: [UInt32] = [], payload: Data? = nil,
                          upload: (FileHandle, Int)? = nil, download: FileHandle? = nil,
                          progress: @Sendable (Int) -> Void = { _ in }) throws -> (Data, [UInt32]) {
        guard let port = connection else { throw DeviceError.unavailable }
        do {
            let transaction = sequence
            sequence &+= 1
            var command = header(parameters.count * 4, 1, operation, transaction)
            parameters.forEach { command.put($0) }
            try write(command, to: port)
            if let payload {
                let packet = header(payload.count, 2, operation, transaction) + payload
                try write(packet, to: port)
                if packet.count % Int(mac_usb_packet_size(port)) == 0 { try write(Data(), to: port) }
            }
            if let (file, size) = upload {
                var packet = header(size, 2, operation, transaction)
                var remaining = size
                while !packet.isEmpty || remaining > 0 {
                    let length = min(block - packet.count, remaining)
                    if length > 0 {
                        guard let bytes = try file.read(upToCount: length), bytes.count == length else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        packet.append(bytes)
                        remaining -= length
                    }
                    try write(packet, to: port)
                    packet.removeAll(keepingCapacity: true)
                    progress(length)
                }
                if (size + 12) % Int(mac_usb_packet_size(port)) == 0 { try write(Data(), to: port) }
            }
            var response = try readHeader(from: port)
            var data = Data()
            if response.type == 2 {
                guard response.code == operation, response.transaction == transaction else { throw DeviceError.malformed }
                if let download {
                    var remaining = response.size
                    while remaining > 0 {
                        let bytes = try read(min(block, remaining), from: port)
                        try download.write(contentsOf: bytes)
                        remaining -= bytes.count
                        progress(bytes.count)
                    }
                } else {
                    guard response.size <= 32 * 1024 * 1024 else { throw DeviceError.tooLarge }
                    data = try read(response.size, from: port)
                }
                response = try readHeader(from: port)
            }
            guard response.type == 3, response.transaction == transaction,
                  response.size <= 20, response.size % 4 == 0 else { throw DeviceError.malformed }
            var values = Reader(data: try read(response.size, from: port))
            let output: [UInt32] = try (0..<(response.size / 4)).map { _ in try values.take() }
            guard response.code == 0x2001 else { throw DeviceError.rejected(response.code) }
            return (data, output)
        } catch DeviceError.rejected(let code) {
            throw DeviceError.rejected(code)
        } catch {
            reset()
            throw error
        }
    }
}

// Finder and the browser share this actor: a complete mount operation owns the
// USB transaction stream, including validation and safe replacement steps.
extension Device {
    func finderOperation(_ operation: DAVOperation, session: UUID, storages: [Storage]) throws -> DAVResult {
        guard connection != nil, sessionIdentifier == session else { throw DAVError(503, "This phone session ended. Eject and mount again.") }
        try Task.checkCancellation()
        // Reuse directory metadata for browsing, but never resolve a write through stale handles.
        switch operation {
        case .inspect, .read: break
        default: cachedDirectories.removeAll()
        }
        func storageName(_ storage: Storage) -> String {
            let clean = storage.name.replacingOccurrences(of: "/", with: "∕").replacingOccurrences(of: "\\", with: "∖")
            return "\(clean) [\(String(storage.id, radix: 16))]"
        }
        func item(_ path: DAVPath, _ entry: Entry) -> DAVItem {
            DAVItem(path: path, directory: entry.folder, size: UInt64(entry.size), modified: entry.modified,
                    version: "\(session.uuidString)-\(entry.id)-\(entry.size)-\(entry.modified?.timeIntervalSince1970 ?? 0)")
        }
        func resolve(_ path: DAVPath) throws -> (Storage, Entry?) {
            guard let first = path.components.first, let storage = storages.first(where: { storageName($0) == first }) else { throw DAVError(404, "Storage not found") }
            var parent = UInt32.max
            var result: Entry?
            for (index, name) in path.components.dropFirst().enumerated() {
                guard let found = try list(storage: storage.id, parent: parent).first(where: { $0.name == name }) else { throw DAVError(404, "Item not found") }
                guard found.folder || index == path.components.count - 2 else { throw DAVError(409, "Parent is not a folder") }
                result = found; parent = found.id
            }
            return (storage, result)
        }
        func destination(_ path: DAVPath) throws -> (Storage, UInt32, Entry?) {
            guard path.components.count >= 2 else { throw DAVError(403, "Storage roots are protected") }
            let (storage, parent) = try resolve(path.parent)
            guard parent == nil || parent!.folder else { throw DAVError(409, "Parent is not a folder") }
            let parentID = parent?.id ?? .max
            let existing = try list(storage: storage.id, parent: parentID).first(where: { $0.name == path.name })
            return (storage, parentID, existing)
        }
        func check(_ entry: Entry?, path: DAVPath, match: String?) throws {
            guard let match else { return }
            guard let entry, match == "*" || match == item(path, entry).etag else { throw DAVError(412, "The file changed. Refresh Finder before trying again.") }
        }
        func protect(_ path: DAVPath) throws { guard path.components.count >= 2 else { throw DAVError(403, "Storage roots are protected") } }
        switch operation {
        case .inspect(let path, let children):
            if path.components.isEmpty {
                var items = [DAVItem(path: path, directory: true, version: session.uuidString)]
                if children { items += try storages.map { DAVItem(path: try DAVPath([storageName($0)]), directory: true, version: "\(session)-\($0.id)") } }
                return .items(items)
            }
            let (storage, entry) = try resolve(path)
            var items = [entry.map { item(path, $0) } ?? DAVItem(path: path, directory: true, version: "\(session)-\(storage.id)")]
            if children && (entry?.folder ?? true) {
                items += try list(storage: storage.id, parent: entry?.id ?? .max).map { try item(DAVPath(path.components + [$0.name]), $0) }
            }
            return .items(items)
        case .read(let path, let output, let match, let range):
            let (_, cached) = try resolve(path)
            guard let cached, !cached.folder else { throw DAVError(405, "Not a file") }
            let entry = try ObjectMetadata.decode(exchange(0x1008, [cached.id]).0, handle: cached.id, timestamp: timestamp)
            guard entry.name == path.name, !entry.folder else { cachedDirectories.removeAll(); throw DAVError(412, "The item changed. Refresh Finder.") }
            do { try check(entry, path: path, match: match) }
            catch { cachedDirectories.removeAll(); throw error }
            if let range { guard range.upperBound < UInt64(entry.size) else { throw DAVError(416, "Invalid range") } }
            let file = try FileHandle(forWritingTo: output)
            defer { try? file.close() }
            if let range, supportedOperations.contains(0x101B) {
                var position = range.lowerBound
                while position <= range.upperBound {
                    try Task.checkCancellation()
                    let length = min(UInt64(block), range.upperBound - position + 1)
                    let data = try exchange(0x101B, [entry.id, UInt32(position), UInt32(length)]).0
                    guard data.count == Int(length) else { throw DeviceError.malformed }
                    try file.write(contentsOf: data); position += length
                }
            } else if let range {
                // Older phones without partial reads remain compatible, at the cost of staging the full file.
                let full = output.deletingLastPathComponent().appendingPathComponent("full-\(UUID().uuidString)")
                guard FileManager.default.createFile(atPath: full.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                defer { try? FileManager.default.removeItem(at: full) }
                let writer = try FileHandle(forWritingTo: full); defer { try? writer.close() }
                _ = try exchange(0x1009, [entry.id], download: writer)
                guard try writer.offset() == UInt64(entry.size) else { throw DeviceError.malformed }
                let reader = try FileHandle(forReadingFrom: full); defer { try? reader.close() }
                try reader.seek(toOffset: range.lowerBound)
                var remaining = range.upperBound - range.lowerBound + 1
                while remaining > 0 {
                    guard let data = try reader.read(upToCount: Int(min(UInt64(block), remaining))), !data.isEmpty else { throw DeviceError.malformed }
                    try file.write(contentsOf: data); remaining -= UInt64(data.count)
                }
            } else {
                _ = try exchange(0x1009, [entry.id], download: file)
                guard try file.offset() == UInt64(entry.size) else { throw DeviceError.malformed }
            }
            try file.synchronize()
            return .file(item(path, entry))
        case .mkdir(let path):
            let (storage, parent, existing) = try destination(path)
            guard existing == nil else { throw DAVError(405, "Item already exists") }
            try makeFolder(path.name, storage: storage.id, parent: parent)
            return .changed(created: true)
        case .delete(let path, let match):
            try protect(path)
            let (_, entry) = try resolve(path)
            guard let entry else { throw DAVError(403, "Storage roots are protected") }
            try check(entry, path: path, match: match); try remove(entry)
            return .changed(created: false)
        case .put(let path, let source, let match, let absent):
            let (storage, parent, existing) = try destination(path)
            try check(existing, path: path, match: match)
            if absent && existing != nil { throw DAVError(412, "Item already exists") }
            guard existing?.folder != true else { throw DAVError(405, "Cannot replace a folder with a file") }
            let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
            guard size >= 0, size <= Int(UInt32.max) - 12 else { throw DAVError(413, "File exceeds MTP size limit") }
            let stagingName = ".macmtp-upload-\(UUID().uuidString)"
            let handle = try create(stagingName, storage: storage.id, parent: parent, size: UInt32(size), folder: false)
            let staged = Entry(id: handle, name: stagingName, folder: false, size: UInt32(size), modified: nil)
            var handedOff = false
            defer { if !handedOff { try? remove(staged) } }
            let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
            _ = try exchange(0x100D, upload: (input, size))
            try Task.checkCancellation()
            handedOff = true
            try FinderReplacement.commit(staged: staged.id, original: existing?.id, name: path.name,
                rename: { id, name in
                    let entry = id == staged.id ? staged : existing!
                    try self.rename(entry, to: name)
                }, remove: { id in
                    let entry = id == staged.id ? staged : existing!
                    try self.remove(entry)
                })
            return .changed(created: existing == nil)
        case .copy(let path, let target, let overwrite):
            try protect(path); try protect(target)
            guard !path.contains(target) else { throw DAVError(409, "Cannot copy an item into itself") }
            let (sourceStorage, source) = try resolve(path)
            guard let source else { throw DAVError(403, "Storage roots are protected") }
            let (targetStorage, parent, existing) = try destination(target)
            guard existing == nil || overwrite else { throw DAVError(412, "Destination exists") }
            guard existing?.folder != true, !source.folder || existing == nil else { throw DAVError(409, "Destination exists. Choose a new name for the copied folder.") }
            let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("MacMTP-Copy-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: workspace) }
            let stagingName = ".macmtp-copy-\(UUID().uuidString)"
            let local = workspace.appendingPathComponent(stagingName)
            try download(source, storage: sourceStorage.id, into: workspace, filename: stagingName) { _ in }
            if !source.folder {
                return try finderOperation(.put(target, from: local, match: existing.map { item(target, $0).etag }, absent: !overwrite), session: session, storages: storages)
            }
            var staged: Entry?
            var published = false
            defer {
                if !published {
                    if staged == nil { staged = try? readDirectory(storage: targetStorage.id, parent: parent).first(where: { $0.name == stagingName }) }
                    if let staged { try? remove(staged) }
                }
            }
            try upload(local, storage: targetStorage.id, parent: parent) { _ in }
            staged = try readDirectory(storage: targetStorage.id, parent: parent).first(where: { $0.name == stagingName })
            guard let staged else { throw DeviceError.malformed }
            try Task.checkCancellation()
            try rename(staged, to: target.name); published = true
            return .changed(created: true)
        case .move(let path, let target, let overwrite, let match):
            try protect(path); try protect(target)
            if path == target { return .changed(created: false) }
            guard !path.contains(target) else { throw DAVError(409, "Cannot move a folder into itself") }
            let (sourceStorage, source) = try resolve(path)
            guard let source else { throw DAVError(403, "Storage roots are protected") }
            try check(source, path: path, match: match)
            let (targetStorage, parent, existing) = try destination(target)
            guard existing == nil || overwrite else { throw DAVError(412, "Destination exists") }
            // Never recursively destroy a destination tree to satisfy a Finder rename.
            guard existing == nil else { throw DAVError(409, "Destination exists. Remove or rename it before moving this item.") }
            guard sourceStorage.id == targetStorage.id else { throw DAVError(501, "Move between storage volumes by copying, then deleting the original") }
            if path.parent == target.parent { try rename(source, to: target.name) }
            else {
                guard path.name == target.name else { throw DAVError(501, "Move the item first, then rename it") }
                _ = try exchange(0x1019, [source.id, targetStorage.id, parent == .max ? 0 : parent])
                cachedDirectories.removeAll()
            }
            return .changed(created: true)
        }
    }
}
