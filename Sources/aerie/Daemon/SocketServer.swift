import Foundation

/// Unix-socket listener: one NDJSON request per connection → one response.
/// Handler runs on the core queue; connections are short-lived.
final class SocketServer {
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue: DispatchQueue
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
        let dir = aerieDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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

        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
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

    private func acceptOne() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while !buf.isEmpty {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if buf[0..<n].contains(0x0A) { break }
        }

        var resp: WireResponse
        if let req = try? JSONDecoder().decode(WireRequest.self, from: data) {
            resp = handler(req)
        } else {
            resp = WireResponse(ok: false, error: "bad request")
        }
        if var out = try? JSONEncoder().encode(resp) {
            out.append(0x0A)
            _ = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        }
    }
}
