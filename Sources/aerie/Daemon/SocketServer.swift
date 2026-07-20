import Foundation

/// Unix-socket listener: one NDJSON request per connection → one response.
/// Handler runs on the core queue; connections are short-lived.
final class SocketServer {
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    /// Core queue: owns the store; handler runs here.
    private let queue: DispatchQueue
    /// Accepts land here; each connection's read is dispatched concurrently
    /// so one slow client can't delay others (or the core queue).
    private let ioQueue = DispatchQueue(
        label: "com.trevor.aerie.socket-io", attributes: .concurrent)
    private let handler: (WireRequest) -> WireResponse

    init(queue: DispatchQueue, handler: @escaping (WireRequest) -> WireResponse) {
        self.queue = queue
        self.handler = handler
    }

    enum ServerError: Error, CustomStringConvertible {
        case alreadyRunning
        case bindFailed(String)

        var description: String {
            switch self {
            case .alreadyRunning: return "another aerie instance is already running"
            case .bindFailed(let s): return "bind failed: \(s)"
            }
        }
    }

    func start() throws {
        ensurePrivateAerieDirectory()
        let path = socketPath()

        if FileManager.default.fileExists(atPath: path) {
            // Live-instance check: if something answers, bail; else it's stale.
            if let resp = try? SocketClient.request(WireRequest(cmd: "ping"), timeoutMS: 300), resp.ok {
                throw ServerError.alreadyRunning
            }
            unlink(path)
        }

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw ServerError.bindFailed("socket() failed") }

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
        guard bound == 0 else {
            throw ServerError.bindFailed(String(cString: strerror(errno)))
        }
        guard listen(listenFD, 16) == 0 else {
            throw ServerError.bindFailed("listen() failed")
        }
        // owner-only socket (0700 dir already blocks others, defense in depth)
        chmod(path, 0o600)

        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: ioQueue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        acceptSource = src
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 { close(listenFD) }
        unlink(socketPath())
    }

    /// Read a full request on the I/O queue; only a decoded request hops to
    /// the core queue. A slow or hostile client can therefore never stall
    /// the store, sweeps, or other clients' commands.
    private func acceptOne() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        ioQueue.async { [weak self] in self?.readAndDispatch(fd) }
    }

    private func readAndDispatch(_ fd: Int32) {
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Hard limits: SO_RCVTIMEO alone is an *inactivity* timeout — a
        // client trickling bytes resets it forever. Enforce a total
        // deadline and a max request size regardless of read cadence.
        let deadline = DispatchTime.now() + .seconds(3)
        let maxRequest = 64 * 1024

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        var complete = false
        while DispatchTime.now() < deadline, data.count < maxRequest {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if buf[0..<n].contains(0x0A) { complete = true; break }
        }

        // decode only the first line
        if let nl = data.firstIndex(of: 0x0A) {
            data = data.prefix(upTo: nl)
            complete = true
        }

        guard complete, let req = try? JSONDecoder().decode(WireRequest.self, from: data) else {
            Self.respond(fd, WireResponse(ok: false, error: "bad request"))
            close(fd)
            return
        }
        // handler (and the store it guards) runs on the core queue
        queue.async { [weak self] in
            let resp = self?.handler(req) ?? WireResponse(ok: false, error: "shutting down")
            Self.respond(fd, resp)
            close(fd)
        }
    }

    private static func respond(_ fd: Int32, _ resp: WireResponse) {
        guard var out = try? JSONEncoder().encode(resp) else { return }
        out.append(0x0A)
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}
