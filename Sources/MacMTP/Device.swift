import Foundation
import USB

struct Storage: Identifiable, Sendable {
    let id: UInt32
    let name: String
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
    case unavailable, interfaceBusy, usbAccessDenied, malformed, tooLarge, unsafeName
    case transport(Int32), rejected(UInt16)

    static func openingUSB(_ status: Int32) -> DeviceError {
        switch status {
        case -6: .interfaceBusy
        case -3: .usbAccessDenied
        case -4: .unavailable
        default: .transport(status)
        }
    }

    var errorDescription: String? {
        switch self {
        case .unavailable: "Unlock your Android device and select USB File Transfer."
        case .interfaceBusy:
            "Another app is using the Android USB interface. Use Recover USB Connection, or close Android transfer and debugging apps, then reconnect the phone."
        case .usbAccessDenied:
            "macOS denied access to the USB device. Unlock this Mac, reconnect the phone, and approve any accessory connection prompt. Check Privacy & Security in System Settings."
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
        cachedDirectories.removeAll()
    }

    func connect() throws -> [Storage] {
        if connection == nil {
            var status: Int32 = 0
            guard let port = mac_usb_open(&status) else { throw DeviceError.openingUSB(status) }
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
                sequence = 0
                _ = try exchange(0x1002, [1])
            }
            catch { reset(); throw error }
        }
        var list = Reader(data: try exchange(0x1004).0)
        return try list.handles().map { id in
            var info = Reader(data: try exchange(0x1005, [id]).0, offset: 26)
            let label = try info.string()
            return Storage(id: id, name: label.isEmpty ? "Device Storage" : label)
        }
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
        guard entry.size <= 8 * 1024 * 1024 else { return Data() }
        return try exchange(0x1009, [entry.id]).0
    }

    func download(_ entry: Entry, storage: UInt32, into folder: URL,
                  filename: String? = nil, progress: @Sendable (TransferEvent) -> Void) throws {
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
