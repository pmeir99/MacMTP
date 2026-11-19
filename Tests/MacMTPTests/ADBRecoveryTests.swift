import Darwin
import XCTest
import USB

final class ADBRecoveryTests: XCTestCase {
    func testADBHandshakePrecedesShutdown() throws {
        try checkMockServer(valid: true)
    }

    func testNonADBServiceIsNotSentShutdown() throws {
        try checkMockServer(valid: false)
    }

    private func checkMockServer(valid: Bool) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        defer { close(listener) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        guard bound == 0, listen(listener, 2) == 0 else { throw POSIXError(.EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &length)
            }
        }
        guard named == 0 else { throw POSIXError(.EIO) }
        let port = UInt16(bigEndian: address.sin_port)
        let completed = expectation(description: "Mock ADB protocol completed")
        DispatchQueue.global().async {
            defer { completed.fulfill() }
            let first = Self.acceptReady(listener)
            guard first >= 0 else { return }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = setsockopt(first, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                           socklen_t(MemoryLayout<timeval>.size))
            XCTAssertEqual(Self.read(first, count: 16), "000chost:version")
            let reply = valid ? "OKAY00040029" : "HTTP"
            reply.withCString { pointer in
                _ = send(first, pointer, reply.utf8.count, 0)
            }
            close(first)
            guard valid else {
                var pending = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                XCTAssertEqual(poll(&pending, 1, 1200), 0,
                               "A non-ADB service must never receive a second shutdown connection")
                return
            }
            let second = Self.acceptReady(listener)
            guard second >= 0 else { return }
            _ = setsockopt(second, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                           socklen_t(MemoryLayout<timeval>.size))
            XCTAssertEqual(Self.read(second, count: 13), "0009host:kill")
            "OKAY".withCString { pointer in _ = send(second, pointer, 4, 0) }
            close(second)
        }
        let result = mac_adb_stop_server_on_port(port)
        XCTAssertEqual(result, valid ? 1 : -1)
        wait(for: [completed], timeout: 5)
    }

    private static func acceptReady(_ listener: Int32) -> Int32 {
        var pending = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&pending, 1, 3000) > 0 else {
            XCTFail("Expected an ADB client connection")
            return -1
        }
        return accept(listener, nil, nil)
    }

    private static func read(_ fd: Int32, count: Int) -> String {
        var data = [UInt8](repeating: 0, count: count)
        let read = data.withUnsafeMutableBytes { recv(fd, $0.baseAddress, count, MSG_WAITALL) }
        guard read > 0 else { return "" }
        return String(decoding: data.prefix(read), as: UTF8.self)
    }
}
