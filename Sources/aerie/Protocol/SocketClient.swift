import Foundation

/// Minimal blocking unix-socket client used by `aerie hook` and control
/// commands. Short timeouts everywhere: a hook must never hold up Claude Code.
enum SocketClient {
    enum ClientError: Error {
        case connectFailed
        case ioFailed
    }

    static func request(_ req: WireRequest, timeoutMS: Int = 250) throws -> WireResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.connectFailed }
        defer { close(fd) }

        var tv = timeval(tv_sec: timeoutMS / 1000, tv_usec: Int32((timeoutMS % 1000) * 1000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath()
        let ok = path.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst -> Bool in
                let len = strlen(src)
                guard len < dst.count else { return false }
                memcpy(dst.baseAddress!, src, len + 1)
                return true
            }
        }
        guard ok else { throw ClientError.connectFailed }

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw ClientError.connectFailed }

        var data = try JSONEncoder().encode(req)
        data.append(0x0A)
        let sent = data.withUnsafeBytes { buf in
            write(fd, buf.baseAddress, buf.count)
        }
        guard sent == data.count else { throw ClientError.ioFailed }

        var response = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            response.append(contentsOf: buf[0..<n])
            if buf[0..<n].contains(0x0A) { break }
        }
        guard !response.isEmpty else { throw ClientError.ioFailed }
        return try JSONDecoder().decode(WireResponse.self, from: response)
    }
}
