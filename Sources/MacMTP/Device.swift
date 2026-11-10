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
}

enum DeviceError: LocalizedError {
    case unavailable, malformed, tooLarge, unsafeName, transport(Int32), rejected(UInt16)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Unlock your Android device and select USB File Transfer."
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

actor Device {
    private var connection: OpaquePointer?
    private var sequence: UInt32 = 0
    private var received = Data()
    private let block = 256 * 1024
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
        mac_usb_close(connection)
        connection = nil
        received.removeAll()
    }

    func connect() throws -> [Storage] {
        if connection == nil {
            guard let port = mac_usb_open() else { throw DeviceError.unavailable }
            connection = port
            sequence = 0
            do { _ = try exchange(0x1002, [1]) }
            catch { reset(); throw error }
        }
        var list = Reader(data: try exchange(0x1004).0)
        return try list.handles().map { id in
            var info = Reader(data: try exchange(0x1005, [id]).0, offset: 26)
            let label = try info.string()
            return Storage(id: id, name: label.isEmpty ? "Device Storage" : label)
        }
    }

    func list(storage: UInt32, parent: UInt32) throws -> [Entry] {
        var handles = Reader(data: try exchange(0x1007, [storage, 0, parent]).0)
        return try handles.handles().map { handle in
            var info = Reader(data: try exchange(0x1008, [handle]).0, offset: 4)
            let format = try info.take(UInt16.self)
            _ = try info.take(UInt16.self)
            let size = try info.take(UInt32.self)
            info.offset = 52
            return Entry(id: handle, name: try info.string(), folder: format == 0x3001, size: size)
        }
    }

    func remove(_ entry: Entry) throws { _ = try exchange(0x100B, [entry.id, 0]) }

    func rename(_ entry: Entry, to name: String) throws {
        try validate(name)
        var payload = Data()
        try payload.putName(name)
        _ = try exchange(0x9804, [entry.id, 0xDC07], payload: payload)
    }

    func makeFolder(_ name: String, storage: UInt32, parent: UInt32) throws {
        _ = try create(name, storage: storage, parent: parent, size: 0, folder: true)
    }

    func upload(_ url: URL, storage: UInt32, parent: UInt32, progress: @Sendable (Int) -> Void) throws {
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
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let handle = try create(url.lastPathComponent, storage: storage, parent: parent, size: UInt32(size), folder: false)
            do {
                _ = try exchange(0x100D, upload: (file, size), progress: progress)
            } catch {
                if connection != nil { _ = try? exchange(0x100B, [handle, 0]) }
                throw error
            }
        }
    }

    func download(_ entry: Entry, storage: UInt32, into folder: URL, progress: @Sendable (Int) -> Void) throws {
        try validate(entry.name)
        let target = folder.appendingPathComponent(entry.name, isDirectory: entry.folder)
        if entry.folder {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            for child in try list(storage: storage, parent: entry.id) {
                try download(child, storage: storage, into: target, progress: progress)
            }
        } else {
            let temporary = folder.appendingPathComponent(".macmtp-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { try? FileManager.default.removeItem(at: temporary) }
            let file = try FileHandle(forWritingTo: temporary)
            defer { try? file.close() }
            _ = try exchange(0x1009, [entry.id], download: file, progress: progress)
            try file.close()
            try FileManager.default.moveItem(at: temporary, to: target)
        }
    }

    private func validate(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.utf8.contains(0), name.utf16.count < 255 else { throw DeviceError.unsafeName }
    }

    private func create(_ name: String, storage: UInt32, parent: UInt32, size: UInt32, folder: Bool) throws -> UInt32 {
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
                try write(header(payload.count, 2, operation, transaction) + payload, to: port)
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
                    if remaining == 0 || (size - remaining) / block % 16 == 0 { progress(size - remaining) }
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
                        if remaining == 0 || (response.size - remaining) / block % 16 == 0 {
                            progress(response.size - remaining)
                        }
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
