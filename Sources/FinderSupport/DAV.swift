import Foundation

public struct DAVPath: Hashable, Sendable {
    public let components: [String]
    public init(_ components: [String]) throws {
        guard components.count <= 128, components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\") &&
            !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) && $0.utf16.count < 255
        }) else { throw DAVError(400, "Invalid path") }
        self.components = components
    }
    public var parent: DAVPath { try! DAVPath(Array(components.dropLast())) }
    public var name: String { components.last ?? "MacMTP" }
    public func contains(_ other: DAVPath) -> Bool { other.components.starts(with: components) }
}

public struct DAVItem: Sendable {
    public let path: DAVPath
    public let directory: Bool
    public let size: UInt64
    public let modified: Date?
    public let version: String
    public init(path: DAVPath, directory: Bool, size: UInt64 = 0, modified: Date? = nil, version: String) {
        self.path = path; self.directory = directory; self.size = size; self.modified = modified; self.version = version
    }
    public var etag: String { "\"\(version)\"" }
}

public enum DAVOperation: Sendable {
    case inspect(DAVPath, children: Bool)
    case read(DAVPath, to: URL, match: String?, range: ClosedRange<UInt64>? = nil)
    case put(DAVPath, from: URL, match: String?, absent: Bool)
    case copy(DAVPath, DAVPath, overwrite: Bool)
    case mkdir(DAVPath)
    case delete(DAVPath, match: String?)
    case move(DAVPath, DAVPath, overwrite: Bool, match: String?)
}

public enum DAVResult: Sendable {
    case items([DAVItem])
    case file(DAVItem)
    case changed(created: Bool)
}

public protocol DAVBackend: Sendable {
    func perform(_ operation: DAVOperation) async throws -> DAVResult
}

public struct DAVError: Error, LocalizedError, Sendable {
    public let status: Int
    public let message: String
    public init(_ status: Int, _ message: String) { self.status = status; self.message = message }
    public var errorDescription: String? { message }
}

public struct DAVRequest: Sendable {
    public let method: String
    public let target: String
    public let headers: [String: String]
    public let body: URL
    public init(method: String, target: String, headers: [String: String], body: URL) {
        self.method = method; self.target = target; self.headers = headers; self.body = body
    }
}

/// Streams a private staging file while the phone fills it. The last byte is
/// withheld until MTP reports success, so a failed USB transaction cannot look complete.
public final class DAVDownload: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var failed = false
    private var task: Task<Void, Never>?
    public init(operation: @escaping @Sendable () async throws -> Void) {
        task = Task {
            var failed = false
            do { try Task.checkCancellation(); try await operation() } catch { failed = true }
            self.complete(failed: failed)
        }
    }
    private func complete(failed: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.failed = failed; finished = true
    }
    public func state() -> (finished: Bool, failed: Bool) {
        lock.lock(); defer { lock.unlock() }; return (finished, failed)
    }
    public func cancel() { task?.cancel() }
}

public struct DAVResponse: Sendable {
    public var status: Int
    public var headers: [String: String] = [:]
    public var data = Data()
    public var download: DAVDownload?
    public var file: URL?
    public var offset: UInt64 = 0
    public var length: UInt64?
    public init(_ status: Int, headers: [String: String] = [:], data: Data = Data()) {
        self.status = status; self.headers = headers; self.data = data
    }
}

/// Serializes complete DAV operations, including lock checks and USB commits.
public actor DAVService {
    public let prefix: String
    private let backend: any DAVBackend
    private let authority: String
    private let writable: Bool
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private struct Lock { let path: DAVPath; let token: String; var expires: Date; let recursive: Bool }
    private var locks: [Lock] = []
    public init(backend: any DAVBackend, authority: String, token: String, writable: Bool) {
        self.backend = backend; self.authority = authority; self.writable = writable
        prefix = "/\(token)/MacMTP"
    }
    private func acquire() async {
        if !occupied { occupied = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { occupied = false } else { waiters.removeFirst().resume() }
    }
    public func respond(_ request: DAVRequest, workspace: URL) async -> DAVResponse {
        await acquire()
        defer { release() }
        do { try Task.checkCancellation(); return try await execute(request, workspace: workspace) }
        catch let error as DAVError { return DAVResponse(error.status, data: Data(error.message.utf8)) }
        catch { return DAVResponse(503, data: Data("The phone is unavailable. Eject, reconnect, and mount again. \(error.localizedDescription)".utf8)) }
    }
    public nonisolated func path(_ target: String) throws -> DAVPath {
        guard !target.contains("?"), !target.contains("#"), target.hasPrefix(prefix + "/") || target == prefix,
              let decoded = String(target.dropFirst(prefix.count)).removingPercentEncoding else { throw DAVError(404, "Not found") }
        // Decode once, and reject encoded separators before splitting into components.
        let lower = target.lowercased()
        guard !lower.contains("%2f"), !lower.contains("%5c") else { throw DAVError(400, "Invalid path") }
        let trimmed = decoded.hasSuffix("/") ? String(decoded.dropLast()) : decoded
        return try DAVPath(trimmed.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init))
    }
    public nonisolated func validateHead(_ head: DAVHTTPParser.Head) throws {
        guard head.headers["host"] == authority, head.headers["origin"] == nil else { throw DAVError(403, "Local Finder access only") }
        _ = try path(head.target)
        if let encoding = head.headers["content-encoding"], encoding.lowercased() != "identity" { throw DAVError(415, "Compressed request bodies are unsupported") }
        if let expect = head.headers["expect"], expect.lowercased() != "100-continue" { throw DAVError(417, "Unsupported expectation") }
    }
    private func href(_ path: DAVPath, directory: Bool) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let suffix = path.components.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        return prefix + "/" + suffix + (directory && !suffix.isEmpty ? "/" : "")
    }
    private func execute(_ r: DAVRequest, workspace: URL) async throws -> DAVResponse {
        guard r.headers["host"] == authority, r.headers["origin"] == nil else { throw DAVError(403, "Local Finder access only") }
        let path = try path(r.target)
        locks.removeAll { $0.expires <= Date() }
        let methods = writable ? "OPTIONS, PROPFIND, GET, HEAD, PUT, MKCOL, DELETE, MOVE, COPY, LOCK, UNLOCK" : "OPTIONS, PROPFIND, GET, HEAD"
        if r.method == "OPTIONS" {
            return DAVResponse(200, headers: ["DAV": writable ? "1, 2" : "1", "Allow": methods, "MS-Author-Via": "DAV"])
        }
        if !["GET", "HEAD", "PROPFIND"].contains(r.method) {
            guard writable else { throw DAVError(403, "Finder changes are disabled") }
            let provided = (r.headers["if"] ?? "") + (r.headers["lock-token"] ?? "")
            for lock in locks where r.method != "COPY" && (lock.path == path || (lock.recursive && lock.path.contains(path)) ||
                (["DELETE", "MOVE"].contains(r.method) && path.contains(lock.path))) {
                guard provided.contains("<\(lock.token)>") else { throw DAVError(423, "Item is locked") }
            }
        }
        switch r.method {
        case "PROPFIND":
            let depth = r.headers["depth"] ?? "infinity"
            guard depth == "0" || depth == "1" else { throw DAVError(403, "Only Depth 0 and 1 are supported") }
            guard case .items(let items) = try await backend.perform(.inspect(path, children: depth == "1")) else { throw DAVError(500, "Invalid listing") }
            // Finder requests allprop or named properties. Unsupported properties are omitted.
            let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:multistatus xmlns:D=\"DAV:\">" + items.map { item in
                let kind = item.directory ? "<D:collection/>" : ""
                let supported = writable ? "<D:lockentry><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockentry>" : ""
                let date = item.modified.map(Self.httpDate) ?? Self.httpDate(Date(timeIntervalSince1970: 0))
                return "<D:response><D:href>\(Self.escape(href(item.path, directory: item.directory)))</D:href><D:propstat><D:prop><D:displayname>\(Self.escape(item.path.name))</D:displayname><D:resourcetype>\(kind)</D:resourcetype><D:getcontentlength>\(item.size)</D:getcontentlength><D:getlastmodified>\(date)</D:getlastmodified><D:getetag>\(Self.escape(item.etag))</D:getetag><D:getcontenttype>\(item.directory ? "httpd/unix-directory" : "application/octet-stream")</D:getcontenttype><D:supportedlock>\(supported)</D:supportedlock><D:lockdiscovery/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
            }.joined() + "</D:multistatus>"
            return DAVResponse(207, headers: ["Content-Type": "application/xml; charset=utf-8"], data: Data(xml.utf8))
        case "GET", "HEAD":
            let output = workspace.appendingPathComponent("download")
            guard case .items(let items) = try await backend.perform(.inspect(path, children: false)), let item = items.first else { throw DAVError(404, "Not found") }
            guard !item.directory || r.method == "HEAD" else { throw DAVError(405, "Open folders in Finder") }
            if let match = r.headers["if-match"], match != "*", match != item.etag { throw DAVError(412, "The file changed") }
            if r.headers["if-none-match"] == item.etag || r.headers["if-none-match"] == "*" { return DAVResponse(304, headers: ["ETag": item.etag]) }
            var response = DAVResponse(200, headers: ["ETag": item.etag, "Accept-Ranges": "bytes", "Content-Type": "application/octet-stream"])
            response.length = item.size
            var requestedRange: ClosedRange<UInt64>?
            if let range = r.headers["range"], r.method == "GET" {
                let bounds = try Self.byteRange(range, size: item.size)
                requestedRange = bounds
                response.status = 206; response.offset = 0; response.length = bounds.upperBound - bounds.lowerBound + 1
                response.headers["Content-Range"] = "bytes \(bounds.lowerBound)-\(bounds.upperBound)/\(item.size)"
            }
            if r.method == "GET" {
                guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw DAVError(507, "Cannot stage this download") }
                response.file = output
                let backend = backend
                let range = requestedRange
                if item.size == 0 { _ = try await backend.perform(.read(path, to: output, match: item.etag, range: range)) }
                else { response.download = DAVDownload { _ = try await backend.perform(.read(path, to: output, match: item.etag, range: range)) } }
            }
            return response
        case "PUT":
            guard !path.components.isEmpty else { throw DAVError(403, "Storage roots are protected") }
            guard r.headers["content-range"] == nil else { throw DAVError(501, "Partial writes are unsupported") }
            return try await mutation(.put(path, from: r.body, match: r.headers["if-match"], absent: r.headers["if-none-match"] == "*"))
        case "MKCOL":
            let size = try r.body.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size == 0 else { throw DAVError(415, "MKCOL bodies are unsupported") }
            return try await mutation(.mkdir(path))
        case "DELETE": return try await mutation(.delete(path, match: r.headers["if-match"]))
        case "MOVE", "COPY":
            guard let destination = r.headers["destination"], let url = URLComponents(string: destination),
                  url.scheme == "http", url.host == "127.0.0.1", "127.0.0.1:\(url.port ?? 80)" == authority,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw DAVError(502, "Destination must be on this phone mount") }
            let target = try self.path(url.percentEncodedPath)
            for lock in locks where lock.path.contains(target) || target.contains(lock.path) {
                guard (r.headers["if"] ?? "").contains("<\(lock.token)>") else { throw DAVError(423, "Destination is locked") }
            }
            if r.method == "COPY" {
                guard r.headers["depth"] == nil || r.headers["depth"] == "infinity" else { throw DAVError(501, "Only complete copies are supported") }
                return try await mutation(.copy(path, target, overwrite: r.headers["overwrite"] != "F"))
            }
            return try await mutation(.move(path, target, overwrite: r.headers["overwrite"] != "F", match: r.headers["if-match"]))
        case "LOCK":
            guard r.headers["depth"] == nil || ["0", "infinity"].contains(r.headers["depth"]!) else { throw DAVError(400, "Invalid lock depth") }
            let token: String
            if let index = locks.firstIndex(where: { $0.path == path }), (r.headers["if"] ?? "").contains("<\(locks[index].token)>") {
                locks[index].expires = Date().addingTimeInterval(300); token = locks[index].token
            } else {
                guard !locks.contains(where: { $0.path.contains(path) || path.contains($0.path) }) else { throw DAVError(423, "Item is locked") }
                let data = try Data(contentsOf: r.body)
                guard data.count <= 64 * 1024, let xml = String(data: data, encoding: .utf8), xml.contains("exclusive"), xml.contains("write"), !xml.contains("<!") else { throw DAVError(400, "Only exclusive write locks are supported") }
                token = "opaquelocktoken:\(UUID().uuidString)"
                locks.append(Lock(path: path, token: token, expires: Date().addingTimeInterval(300), recursive: r.headers["depth"] != "0"))
            }
            let xml = "<?xml version=\"1.0\"?><D:prop xmlns:D=\"DAV:\"><D:lockdiscovery><D:activelock><D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope><D:depth>\(r.headers["depth"] == "0" ? "0" : "infinity")</D:depth><D:timeout>Second-300</D:timeout><D:locktoken><D:href>\(token)</D:href></D:locktoken><D:lockroot><D:href>\(Self.escape(href(path, directory: false)))</D:href></D:lockroot></D:activelock></D:lockdiscovery></D:prop>"
            return DAVResponse(200, headers: ["Lock-Token": "<\(token)>", "Content-Type": "application/xml"], data: Data(xml.utf8))
        case "UNLOCK":
            guard let index = locks.firstIndex(where: { $0.path == path && "<\($0.token)>" == r.headers["lock-token"] }) else { throw DAVError(409, "Lock not found") }
            locks.remove(at: index); return DAVResponse(204)
        default: return DAVResponse(405, headers: ["Allow": methods])
        }
    }
    private func mutation(_ operation: DAVOperation) async throws -> DAVResponse {
        guard case .changed(let created) = try await backend.perform(operation) else { throw DAVError(500, "Invalid mutation result") }
        return DAVResponse(created ? 201 : 204)
    }
    public static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static func httpDate(_ date: Date) -> String {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT: 0); format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return format.string(from: date)
    }
    public static func byteRange(_ value: String, size: UInt64) throws -> ClosedRange<UInt64> {
        guard size > 0, value.hasPrefix("bytes="), !value.contains(",") else { throw DAVError(416, "Invalid range") }
        let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw DAVError(416, "Invalid range") }
        if parts[0].isEmpty, let suffix = UInt64(parts[1]), suffix > 0 { return (size - min(suffix, size))...(size - 1) }
        guard let start = UInt64(parts[0]), start < size else { throw DAVError(416, "Invalid range") }
        let end: UInt64
        if parts[1].isEmpty { end = size - 1 } else if let number = UInt64(parts[1]) { end = min(number, size - 1) } else { throw DAVError(416, "Invalid range") }
        guard end >= start else { throw DAVError(416, "Invalid range") }
        return start...end
    }
}
