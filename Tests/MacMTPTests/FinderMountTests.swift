import AppKit
import FinderSupport
import XCTest
@testable import MacMTP

private actor TestPhone: DAVBackend {
    let root: URL
    init(_ root: URL) { self.root = root }
    func perform(_ operation: DAVOperation) throws -> DAVResult {
        func url(_ path: DAVPath) -> URL { path.components.reduce(root) { $0.appendingPathComponent($1) } }
        func item(_ path: DAVPath) throws -> DAVItem {
            let info = try url(path).resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            return DAVItem(path: path, directory: info.isDirectory == true, size: UInt64(info.fileSize ?? 0), modified: info.contentModificationDate, version: "test-\(info.fileSize ?? 0)")
        }
        switch operation {
        case .inspect(let path, let children):
            var result = [try item(path)]
            if children && result[0].directory {
                result += try FileManager.default.contentsOfDirectory(atPath: url(path).path).sorted().map { try item(DAVPath(path.components + [$0])) }
            }
            return .items(result)
        case .read(let path, let target, _):
            try FileManager.default.copyItem(at: url(path), to: target); return .file(try item(path))
        case .put(let path, let source, _, let absent):
            let exists = FileManager.default.fileExists(atPath: url(path).path)
            if absent && exists { throw DAVError(412, "Exists") }
            try Data(contentsOf: source).write(to: url(path), options: .atomic)
            return .changed(created: !exists)
        case .mkdir(let path):
            try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: false); return .changed(created: true)
        case .delete(let path, _):
            try FileManager.default.removeItem(at: url(path)); return .changed(created: false)
        case .move(let path, let target, _, _):
            try FileManager.default.moveItem(at: url(path), to: url(target)); return .changed(created: true)
        }
    }
}

final class FinderMountTests: XCTestCase {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testHTTPStreamingAndAmbiguousFraming() throws {
        let root = try workspace()
        let url = root.appendingPathComponent("body")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        let parser = DAVHTTPParser(file: file)
        let bytes = Data("PUT /secret/MacMTP/file HTTP/1.1\r\nHost: 127.0.0.1:123\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n".utf8)
        for byte in bytes { try parser.feed(Data([byte])) }
        XCTAssertTrue(parser.complete)
        XCTAssertEqual(try Data(contentsOf: url), Data("abcde".utf8))
        let ambiguous = DAVHTTPParser(file: file)
        XCTAssertThrowsError(try ambiguous.feed(Data("PUT /x HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)))
        let duplicate = DAVHTTPParser(file: file)
        XCTAssertThrowsError(try duplicate.feed(Data("GET / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n".utf8)))
        let oversized = DAVHTTPParser(file: file, maximum: 4)
        XCTAssertThrowsError(try oversized.feed(Data("PUT / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\n".utf8)))
    }
    func testPathSecurityAndRanges() async throws {
        let service = DAVService(backend: TestPhone(try workspace()), authority: "127.0.0.1:123", token: "secret", writable: false)
        for path in ["/secret/MacMTP/../outside", "/secret/MacMTP/%2e%2e/outside", "/secret/MacMTP/a%2fb", "/wrong/MacMTP/", "/secret/MacMTP/a//b", "/secret/MacMTP/%00"] {
            do { _ = try await service.path(path); XCTFail(path) } catch {}
        }
        let path = try await service.path("/secret/MacMTP/Photos/%D7%A9%D7%9C%D7%95%D7%9D%20%26.jpg")
        XCTAssertEqual(path.components, ["Photos", "שלום &.jpg"])
        XCTAssertEqual(try DAVService.byteRange("bytes=2-4", size: 10), 2...4)
        XCTAssertEqual(try DAVService.byteRange("bytes=-3", size: 10), 7...9)
        XCTAssertEqual(try DAVService.byteRange("bytes=5-", size: 10), 5...9)
        XCTAssertThrowsError(try DAVService.byteRange("bytes=10-", size: 10))
        XCTAssertThrowsError(try DAVService.byteRange("bytes=0-1,3-4", size: 10))
    }
    func testReadOnlyAndCrossOriginRequestsCannotWrite() async throws {
        let root = try workspace(), work = try workspace()
        let body = work.appendingPathComponent("body"); try Data("payload".utf8).write(to: body)
        let service = DAVService(backend: TestPhone(root), authority: "127.0.0.1:123", token: "secret", writable: false)
        let denied = await service.respond(DAVRequest(method: "PUT", target: "/secret/MacMTP/file", headers: ["host": "127.0.0.1:123"], body: body), workspace: work)
        XCTAssertEqual(denied.status, 403)
        let origin = await service.respond(DAVRequest(method: "PROPFIND", target: "/secret/MacMTP/", headers: ["host": "127.0.0.1:123", "origin": "https://example.com", "depth": "1"], body: body), workspace: work)
        XCTAssertEqual(origin.status, 403)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
    func testRealHTTPRoundTripAndMutationErrors() async throws {
        let root = try workspace()
        let server = try DAVServer(backend: TestPhone(root), writable: true)
        let address = try await server.start(); defer { server.stop() }
        func request(_ method: String, _ name: String, data: Data? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: address.appendingPathComponent(name)); request.httpMethod = method; request.httpBody = data
            headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, try XCTUnwrap(response as? HTTPURLResponse))
        }
        let put = try await request("PUT", "file.txt", data: Data("hello".utf8)); XCTAssertEqual(put.1.statusCode, 201)
        let get = try await request("GET", "file.txt"); XCTAssertEqual(get.0, Data("hello".utf8))
        let range = try await request("GET", "file.txt", headers: ["Range": "bytes=1-3"]); XCTAssertEqual(range.1.statusCode, 206); XCTAssertEqual(range.0, Data("ell".utf8))
        let exists = try await request("PUT", "file.txt", data: Data("bad".utf8), headers: ["If-None-Match": "*"]); XCTAssertEqual(exists.1.statusCode, 412)
        let listing = try await request("PROPFIND", "", headers: ["Depth": "1"]); XCTAssertEqual(listing.1.statusCode, 207); XCTAssertTrue(String(decoding: listing.0, as: UTF8.self).contains("file.txt"))
        let invalid = try await request("PROPFIND", "", headers: ["Depth": "infinity"]); XCTAssertEqual(invalid.1.statusCode, 403)
        let lockXML = Data("<D:lockinfo xmlns:D=\"DAV:\"><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockinfo>".utf8)
        let lock = try await request("LOCK", "file.txt", data: lockXML, headers: ["Depth": "0"])
        XCTAssertEqual(lock.1.statusCode, 200)
        let token = try XCTUnwrap(lock.1.value(forHTTPHeaderField: "Lock-Token"))
        let locked = try await request("DELETE", "file.txt"); XCTAssertEqual(locked.1.statusCode, 423)
        let unlock = try await request("UNLOCK", "file.txt", headers: ["Lock-Token": token]); XCTAssertEqual(unlock.1.statusCode, 204)
        let delete = try await request("DELETE", "file.txt"); XCTAssertEqual(delete.1.statusCode, 204)
    }
    @MainActor
    func testNativeMacOSMountReadsAndEjectsWithoutInstalledDrivers() async throws {
        let root = try workspace(), mount = try workspace()
        try Data("Finder mounting works".utf8).write(to: root.appendingPathComponent("proof.txt"))
        let server = try DAVServer(backend: TestPhone(root), writable: false)
        let address = try await server.start()
        defer { server.stop() }
        try await FinderMountController.command("/sbin/mount_webdav", ["-v", "MacMTP Test", "-o", "rdonly,nosuid,nodev,noexec", address.absoluteString, mount.path])
        do {
            XCTAssertTrue(FinderMountController.isMounted(mount))
            // File APIs can synchronously block waiting for the server; don't block MainActor.
            let data = try await Task.detached { try Data(contentsOf: mount.appendingPathComponent("proof.txt")) }.value
            XCTAssertEqual(data, Data("Finder mounting works".utf8))
        } catch {
            try? await FinderMountController.command("/sbin/umount", [mount.path]); throw error
        }
        try await FinderMountController.command("/sbin/umount", [mount.path])
        XCTAssertFalse(FinderMountController.isMounted(mount))
    }
}
