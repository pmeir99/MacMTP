import Foundation

/// Incremental HTTP/1.1 framing. Bodies go directly to disk, never into an unbounded Data.
public final class DAVHTTPParser {
    public struct Head: Sendable {
        public let method: String
        public let target: String
        public let headers: [String: String]
    }
    public private(set) var head: Head?
    public private(set) var complete = false
    public private(set) var count: UInt64 = 0
    private var buffer = Data()
    private var remaining: UInt64 = 0
    private var chunked = false
    private var chunkRemaining: Int?
    private var chunkTerminator = false
    private var finalChunk = false
    private let file: FileHandle
    private let validateHead: (Head) throws -> Void
    private var bodyMaximum: UInt64 = 0
    public let maximum: UInt64
    public init(file: FileHandle, maximum: UInt64 = UInt64(UInt32.max) - 12,
                validateHead: @escaping (Head) throws -> Void = { _ in }) {
        self.file = file; self.maximum = maximum; self.validateHead = validateHead
    }
    public func feed(_ data: Data) throws {
        guard !complete else { throw DAVError(400, "Pipelining is unsupported") }
        buffer.append(data)
        if head == nil {
            guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                guard buffer.count <= 16 * 1024 else { throw DAVError(431, "Headers too large") }; return
            }
            guard range.lowerBound <= 16 * 1024,
                  let text = String(data: buffer.prefix(upTo: range.lowerBound), encoding: .utf8) else { throw DAVError(400, "Invalid headers") }
            let lines = text.components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
            guard first.count == 3, first[2] == "HTTP/1.1", first[1].hasPrefix("/"), first[1].utf8.count <= 8192,
                  first[0].allSatisfy({ $0.isASCII && $0.isUppercase }) else { throw DAVError(400, "Invalid request") }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw DAVError(400, "Invalid header") }
                let key = String(line[..<colon]).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard key.utf8.allSatisfy({ ($0 >= 97 && $0 <= 122) || $0 == 45 || ($0 >= 48 && $0 <= 57) }),
                      !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }), headers[key] == nil else { throw DAVError(400, "Invalid or duplicate header") }
                headers[key] = value
            }
            guard headers["host"] != nil else { throw DAVError(400, "Missing host") }
            let parsedHead = Head(method: String(first[0]), target: String(first[1]), headers: headers)
            try validateHead(parsedHead)
            bodyMaximum = parsedHead.method == "PUT" ? maximum : min(maximum, 64 * 1024)
            if let encoding = headers["transfer-encoding"] {
                guard encoding.lowercased() == "chunked", headers["content-length"] == nil else { throw DAVError(400, "Ambiguous framing") }
                chunked = true
            } else if let length = headers["content-length"] {
                guard !length.isEmpty, length.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let parsed = UInt64(length) else { throw DAVError(400, "Invalid content length") }
                guard parsed <= bodyMaximum else { throw DAVError(413, "File exceeds MTP size limit") }
                remaining = parsed
            }
            head = parsedHead
            buffer.removeSubrange(..<range.upperBound)
        }
        if chunked { try consumeChunks() }
        else {
            let length = min(UInt64(buffer.count), remaining)
            if length > 0 { try append(Data(buffer.prefix(Int(length)))); buffer.removeFirst(Int(length)); remaining -= length }
            if remaining == 0 { guard buffer.isEmpty else { throw DAVError(400, "Unexpected body bytes") }; complete = true }
        }
        if complete { try file.synchronize() }
    }
    private func append(_ bytes: Data) throws {
        guard UInt64(bytes.count) <= bodyMaximum - count else { throw DAVError(413, "File exceeds MTP size limit") }
        try file.write(contentsOf: bytes); count += UInt64(bytes.count)
    }
    private func consumeChunks() throws {
        while true {
            if finalChunk {
                guard buffer.count >= 2 else { return }
                guard buffer == Data("\r\n".utf8) else { throw DAVError(400, "Trailers are unsupported") }
                buffer.removeAll(); complete = true; return
            }
            if chunkTerminator {
                guard buffer.count >= 2 else { return }
                guard buffer.prefix(2) == Data("\r\n".utf8) else { throw DAVError(400, "Invalid chunk terminator") }
                buffer.removeFirst(2); chunkTerminator = false
            }
            if chunkRemaining == nil {
                guard let range = buffer.range(of: Data("\r\n".utf8)) else {
                    guard buffer.count <= 128 else { throw DAVError(400, "Invalid chunk header") }; return
                }
                guard buffer.distance(from: buffer.startIndex, to: range.lowerBound) <= 128, let line = String(data: buffer.prefix(upTo: range.lowerBound), encoding: .ascii),
                      !line.isEmpty, line.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }),
                      let size = UInt64(line, radix: 16), size <= bodyMaximum - count else { throw DAVError(413, "Invalid or oversized chunk") }
                buffer.removeSubrange(..<range.upperBound)
                if size == 0 { finalChunk = true; continue }
                chunkRemaining = Int(size)
            }
            guard let remaining = chunkRemaining else { return }
            let length = min(remaining, buffer.count)
            if length == 0 { return }
            try append(Data(buffer.prefix(length))); buffer.removeFirst(length)
            if length == remaining { chunkRemaining = nil; chunkTerminator = true }
            else { chunkRemaining = remaining - length; return }
        }
    }
}
