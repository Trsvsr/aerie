import XCTest
@testable import aerie

/// Minimal fake AF_UNIX server for exercising SocketClient's failure paths
/// against a real socket, not just mocked-away behavior. Binds and listens
/// synchronously so a client can connect immediately after `accept(handler:)`
/// returns; the actual accept + handler runs on a background queue.
private final class FakeUnixServer {
    let path: String
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "fake-unix-server")

    init(path: String) {
        self.path = path
        unlink(path)
    }

    func start(handler: @escaping (Int32) -> Void) {
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(listenFD >= 0, "socket() failed")
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                memcpy(dst.baseAddress!, src, strlen(src) + 1)
            }
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(listenFD, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(bound == 0, "bind() failed")
        precondition(listen(listenFD, 1) == 0, "listen() failed")

        let fd = listenFD
        queue.async {
            let clientFD = accept(fd, nil, nil)
            guard clientFD >= 0 else { return }
            handler(clientFD)
            close(clientFD)
        }
    }

    func stop() {
        if listenFD >= 0 { close(listenFD) }
        unlink(path)
    }
}

final class SocketClientTests: XCTestCase {
    var tmp: URL!

    override func setUp() {
        // sockaddr_un.sun_path is ~104 bytes on macOS — FileManager's real
        // temporaryDirectory (/var/folders/.../T/...) plus a UUID
        // subdirectory blows past that. /tmp itself is short and stable.
        tmp = URL(fileURLWithPath: "/tmp/aerie-sock-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func drain(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        _ = read(fd, &buf, buf.count)
    }

    private func write(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { p in _ = Foundation.write(fd, p.baseAddress, p.count) }
    }

    /// Daemon-absent: nothing listening at the path at all. This is the
    /// everyday "app isn't running" case the approval hook must fail open on.
    func testDaemonAbsentThrowsConnectFailed() {
        let path = tmp.appendingPathComponent("nobody-home.sock").path
        XCTAssertThrowsError(
            try SocketClient.request(WireRequest(cmd: "ping"),
                                      sendTimeoutMS: 200, readTimeoutMS: 200, path: path)
        ) { error in
            XCTAssertEqual(error as? SocketClient.ClientError, .connectFailed)
        }
    }

    func testValidResponseDecodesCorrectly() throws {
        let path = tmp.appendingPathComponent("valid.sock").path
        let server = FakeUnixServer(path: path)
        defer { server.stop() }
        server.start { [self] fd in
            drain(fd)
            var data = try! JSONEncoder().encode(
                WireResponse(ok: true, decision: "allow", approvalID: "abc123"))
            data.append(0x0A)
            write(fd, data)
        }

        let resp = try SocketClient.request(
            WireRequest(cmd: "approval", sessionID: "s1"),
            sendTimeoutMS: 500, readTimeoutMS: 500, path: path)
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.decision, "allow")
        XCTAssertEqual(resp.approvalID, "abc123")
    }

    /// A malformed reply (truncated, corrupt, wrong shape) must fail the
    /// decode rather than hand back a garbage-but-successful response —
    /// ApprovalHook maps any thrown error here to decision "none" (fail open).
    func testMalformedResponseThrows() {
        let path = tmp.appendingPathComponent("malformed.sock").path
        let server = FakeUnixServer(path: path)
        defer { server.stop() }
        server.start { [self] fd in
            drain(fd)
            write(fd, Data("{ not valid json\n".utf8))
        }

        XCTAssertThrowsError(
            try SocketClient.request(WireRequest(cmd: "approval", sessionID: "s1"),
                                      sendTimeoutMS: 500, readTimeoutMS: 500, path: path))
    }

    /// Server accepts but never replies (e.g. daemon wedged mid-decision) —
    /// the read timeout must fire and throw, not hang forever.
    func testServerNeverRespondsTimesOut() {
        let path = tmp.appendingPathComponent("silent.sock").path
        let server = FakeUnixServer(path: path)
        defer { server.stop() }
        server.start { [self] fd in
            drain(fd)
            // deliberately never writes back; connection stays open until
            // the client's own read timeout fires
            Thread.sleep(forTimeInterval: 1.0)
        }

        XCTAssertThrowsError(
            try SocketClient.request(WireRequest(cmd: "approval", sessionID: "s1"),
                                      sendTimeoutMS: 200, readTimeoutMS: 200, path: path)
        ) { error in
            XCTAssertEqual(error as? SocketClient.ClientError, .ioFailed)
        }
    }
}
