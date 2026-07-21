import Foundation

/// One accepted connection's reply channel. Most commands reply immediately;
/// approvals PARK the reply until the user decides (or timeout / hangup).
/// One-shot: exactly one send ever writes; later sends are no-ops. If the
/// client disconnects while parked, `onHangup` fires on the handler queue.
final class ConnectionReply {
    private let fd: Int32
    private let lock = NSLock()
    private var sent = false
    private var eofSource: DispatchSourceRead?
    /// Set before calling park(); invoked (once) on `queue` if the peer
    /// disconnects before a reply is sent.
    var onHangup: (() -> Void)?
    private let queue: DispatchQueue

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    /// Send the reply and close. Safe to call from any thread, any number of
    /// times — only the first call writes.
    func send(_ resp: WireResponse) {
        lock.lock()
        guard !sent else { lock.unlock(); return }
        sent = true
        let src = eofSource
        eofSource = nil
        lock.unlock()

        src?.cancel()   // cancel handler closes the fd
        if src == nil {
            Self.write(fd, resp)
            close(fd)
        } else {
            Self.write(fd, resp)
            // fd is closed by the cancel handler
        }
    }

    /// Arm an EOF watcher for a parked connection: a readable event with zero
    /// bytes means the client gave up (its own timeout) or died.
    func park() {
        lock.lock()
        guard !sent, eofSource == nil else { lock.unlock(); return }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        eofSource = src
        lock.unlock()

        src.setEventHandler { [weak self] in
            guard let self else { return }
            var probe = [UInt8](repeating: 0, count: 1)
            let n = recv(self.fd, &probe, 1, MSG_PEEK)
            if n <= 0 { self.hangup() }
        }
        src.setCancelHandler { [fd] in close(fd) }
        src.resume()
    }

    private func hangup() {
        lock.lock()
        guard !sent else { lock.unlock(); return }
        sent = true
        let src = eofSource
        eofSource = nil
        lock.unlock()
        src?.cancel()
        onHangup?()
    }

    private static func write(_ fd: Int32, _ resp: WireResponse) {
        guard var out = try? JSONEncoder().encode(resp) else { return }
        out.append(0x0A)
        _ = out.withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) }
    }
}

/// Unix-socket listener: one NDJSON request per connection → one response
/// (possibly deferred, for approvals). Handler runs on the core queue.
final class SocketServer {
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    /// Core queue: owns the store; handler runs here.
    private let queue: DispatchQueue
    /// Accepts land here; each connection's read is dispatched concurrently
    /// so one slow client can't delay others (or the core queue).
    private let ioQueue = DispatchQueue(
        label: "com.trevor.aerie.socket-io", attributes: .concurrent)
    private let handler: (WireRequest, ConnectionReply) -> Void

    init(queue: DispatchQueue, handler: @escaping (WireRequest, ConnectionReply) -> Void) {
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

        let reply = ConnectionReply(fd: fd, queue: queue)
        guard complete, let req = try? JSONDecoder().decode(WireRequest.self, from: data) else {
            reply.send(WireResponse(ok: false, error: "bad request"))
            return
        }
        // handler (and the store it guards) runs on the core queue
        queue.async { [weak self] in
            guard let self else {
                reply.send(WireResponse(ok: false, error: "shutting down"))
                return
            }
            self.handler(req, reply)
        }
    }
}
