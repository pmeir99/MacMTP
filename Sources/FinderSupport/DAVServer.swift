import Foundation
import Network

/// A private IPv4-loopback listener. No Bonjour advertisement and no LAN binding.
public final class DAVServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.meir.macmtp.finder.network")
    private let listener: NWListener
    private let backend: any DAVBackend
    private let writable: Bool
    private let token = UUID().uuidString + UUID().uuidString
    private var service: DAVService?
    private var sessions: [UUID: Session] = [:]
    private var started = false
    private var stopped = false
    public init(backend: any DAVBackend, writable: Bool) throws {
        self.backend = backend; self.writable = writable
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    public func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.started else { continuation.resume(throwing: DAVError(500, "Server already started")); return }
                self.started = true
                var pending = true
                self.listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guard pending, let port = self.listener.port else { return }; pending = false
                        let authority = "127.0.0.1:\(port.rawValue)"
                        self.service = DAVService(backend: self.backend, authority: authority, token: self.token, writable: self.writable)
                        continuation.resume(returning: URL(string: "http://\(authority)/\(self.token)/MacMTP/")!)
                    case .failed(let error):
                        if pending { pending = false; continuation.resume(throwing: error) }
                        self.listener.cancel()
                    case .cancelled:
                        if pending { pending = false; continuation.resume(throwing: CancellationError()) }
                    default: break
                    }
                }
                self.listener.newConnectionHandler = { connection in
                    guard !self.stopped, let service = self.service, self.sessions.count < 8 else { connection.cancel(); return }
                    do {
                        let session = try Session(connection: connection, service: service, queue: self.queue) { [weak self] id in self?.sessions.removeValue(forKey: id) }
                        self.sessions[session.id] = session; session.start()
                    } catch { connection.cancel() }
                }
                self.listener.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 10) {
                    if pending { pending = false; self.listener.cancel(); continuation.resume(throwing: DAVError(503, "Local mount server did not start")) }
                }
            }
        }
    }
    public func stop() {
        queue.async {
            self.stopped = true; self.listener.cancel()
            let active = Array(self.sessions.values)
            active.forEach { $0.close() }; self.sessions.removeAll()
        }
    }
    private final class Session: @unchecked Sendable {
        let id = UUID()
        private let connection: NWConnection
        private let service: DAVService
        private let queue: DispatchQueue
        private let done: (UUID) -> Void
        private let workspace: URL
        private let body: URL
        private let input: FileHandle
        private let parser: DAVHTTPParser
        private var output: FileHandle?
        private var sendRemaining: UInt64 = 0
        private var closed = false
        private var requested = false
        private var sentContinue = false
        private var task: Task<Void, Never>?
        private var activity = Date()
        init(connection: NWConnection, service: DAVService, queue: DispatchQueue, done: @escaping (UUID) -> Void) throws {
            self.connection = connection; self.service = service; self.queue = queue; self.done = done
            workspace = FileManager.default.temporaryDirectory.appendingPathComponent("MacMTP-Finder-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            body = workspace.appendingPathComponent("body")
            guard FileManager.default.createFile(atPath: body.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            input = try FileHandle(forWritingTo: body); parser = DAVHTTPParser(file: input)
        }
        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .failed = state { self.close() }
                if case .cancelled = state { self.close() }
            }
            connection.start(queue: queue); receive(); checkIdle()
        }
        private func checkIdle() {
            queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, !self.closed else { return }
                // USB work has its own transport timeout. Don't abort an active commit.
                if !self.requested && Date().timeIntervalSince(self.activity) > 60 { self.close() }
                else { self.checkIdle() }
            }
        }
        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, finished, error in
                guard let self, !self.closed else { return }
                self.activity = Date()
                do {
                    if let data { try self.parser.feed(data) }
                    if let head = self.parser.head, !self.sentContinue, head.headers["expect"]?.lowercased() == "100-continue", !self.parser.complete {
                        self.sentContinue = true
                        self.connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                    }
                    if self.parser.complete, let head = self.parser.head {
                        self.requested = true; try self.input.close()
                        let request = DAVRequest(method: head.method, target: head.target, headers: head.headers, body: self.body)
                        self.task = Task {
                            let response = await self.service.respond(request, workspace: self.workspace)
                            self.queue.async { if !self.closed { self.send(response, headOnly: head.method == "HEAD") } }
                        }
                    } else if finished || error != nil { self.close() }
                    else { self.receive() }
                } catch let error as DAVError { self.send(DAVResponse(error.status, data: Data(error.message.utf8)), headOnly: false) }
                catch { self.send(DAVResponse(507, data: Data("Not enough local space to prepare this transfer".utf8)), headOnly: false) }
            }
        }
        private func send(_ response: DAVResponse, headOnly: Bool) {
            do {
                var headers = response.headers
                let length = response.length ?? UInt64(response.data.count)
                headers["Content-Length"] = String(length); headers["Connection"] = "close"; headers["Cache-Control"] = "no-store"
                if let url = response.file, !headOnly {
                    output = try FileHandle(forReadingFrom: url); try output?.seek(toOffset: response.offset)
                    sendRemaining = length
                }
                let header = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n" + headers.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
                var packet = Data(header.utf8)
                if !headOnly && response.file == nil { packet.append(response.data) }
                connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if error != nil || headOnly || self.output == nil { self.close() } else { self.sendFile() }
                })
            } catch { close() }
        }
        private func sendFile() {
            guard !closed else { return }
            if sendRemaining == 0 { close(); return }
            do {
                guard let bytes = try output?.read(upToCount: Int(min(sendRemaining, 256 * 1024))), !bytes.isEmpty else { close(); return }
                sendRemaining -= UInt64(bytes.count)
                connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.close() } else { self?.sendFile() }
                })
            } catch { close() }
        }
        func close() {
            guard !closed else { return }; closed = true
            connection.cancel(); task?.cancel()
            try? input.close(); try? output?.close()
            // A running USB operation must finish before deleting its staging directory.
            if let task { let workspace = workspace; Task { await task.value; try? FileManager.default.removeItem(at: workspace) } }
            else { try? FileManager.default.removeItem(at: workspace) }
            done(id)
        }
        private static func reason(_ status: Int) -> String {
            switch status {
            case 200: "OK"
            case 201: "Created"
            case 204: "No Content"
            case 206: "Partial Content"
            case 207: "Multi-Status"
            case 304: "Not Modified"
            case 400: "Bad Request"
            case 403: "Forbidden"
            case 404: "Not Found"
            case 405: "Method Not Allowed"
            case 409: "Conflict"
            case 412: "Precondition Failed"
            case 413: "Content Too Large"
            case 416: "Range Not Satisfiable"
            case 423: "Locked"
            case 431: "Request Header Fields Too Large"
            case 501: "Not Implemented"
            case 502: "Bad Gateway"
            case 503: "Service Unavailable"
            case 507: "Insufficient Storage"
            default: "Error"
            }
        }
    }
}
