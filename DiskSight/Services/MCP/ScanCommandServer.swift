import Foundation
import OSLog

/// A small Unix-domain-socket command listener that lets the standalone MCP
/// server ask the running app to start/monitor/cancel scans and probe access.
/// One newline-delimited JSON request per connection, one JSON response, close.
///
/// The socket lives at ~/Library/Application Support/DiskSight/mcp.sock with
/// 0600 permissions (user-only). The app is non-sandboxed, so this path is the
/// real on-disk location shared with the CLI.
final class ScanCommandServer {
    private let logger = Logger(subsystem: "com.disksight.app", category: "ScanCommandServer")
    private let socketURL: URL
    private let registry: ScanJobRegistry
    private let queue = DispatchQueue(label: "com.disksight.mcp.socket")

    private var listenFD: Int32 = -1
    private var running = false

    init(socketURL: URL, registry: ScanJobRegistry) {
        self.socketURL = socketURL
        self.registry = registry
    }

    func start() {
        queue.async { [weak self] in
            self?.bindAndListen()
        }
    }

    func stop() {
        queue.sync {
            running = false
            if listenFD >= 0 {
                close(listenFD)
                listenFD = -1
            }
            try? FileManager.default.removeItem(at: socketURL)
        }
    }

    // MARK: - Socket setup

    private func bindAndListen() {
        // Ignore SIGPIPE so a client disconnecting mid-write can't kill the app.
        signal(SIGPIPE, SIG_IGN)

        let path = socketURL.path
        guard path.utf8.count < 104 else {
            logger.error("Socket path too long: \(path, privacy: .public)")
            return
        }

        // Ensure the parent directory exists, then clear any stale socket.
        try? FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            logger.error("socket() failed: \(String(cString: strerror(errno)), privacy: .public)")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                for (i, byte) in pathBytes.enumerated() {
                    dst[i] = CChar(bitPattern: byte)
                }
                dst[pathBytes.count] = 0
            }
        }

        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, addrSize)
            }
        }
        guard bindResult == 0 else {
            logger.error("bind() failed: \(String(cString: strerror(errno)), privacy: .public)")
            close(fd)
            return
        }

        chmod(path, 0o600)

        guard listen(fd, 4) == 0 else {
            logger.error("listen() failed: \(String(cString: strerror(errno)), privacy: .public)")
            close(fd)
            return
        }

        listenFD = fd
        running = true
        logger.info("Scan command socket listening at \(path, privacy: .public)")

        acceptLoop()
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if running {
                    // Transient error; brief backoff to avoid a hot loop.
                    usleep(50_000)
                    continue
                }
                break
            }
            handleClient(clientFD)
            close(clientFD)
        }
    }

    private func handleClient(_ fd: Int32) {
        // Avoid SIGPIPE on this connection specifically too.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        // Bound how long one client can hold this serial accept loop: a
        // half-open/silent client must not wedge the channel forever. On
        // timeout read() returns -1 and we drop the connection.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard let requestData = readLine(fd: fd) else { return }

        let response: ScanSocketResponse
        if let request = try? JSONDecoder().decode(ScanSocketRequest.self, from: requestData) {
            response = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    registry.handle(request)
                }
            }
        } else {
            response = .failure("Malformed request JSON.")
        }

        if let data = try? JSONEncoder().encode(response) {
            writeAll(fd: fd, data: data)
        }
    }

    // MARK: - Line I/O

    private func readLine(fd: Int32, maxBytes: Int = 64 * 1024) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < maxBytes {
            let n = read(fd, &byte, 1)
            if n <= 0 { return data.isEmpty ? nil : data }
            if byte == 0x0A { break }
            data.append(byte)
        }
        return data
    }

    private func writeAll(fd: Int32, data: Data) {
        var payload = data
        payload.append(0x0A)
        payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var ptr = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, ptr, remaining)
                if n <= 0 { break }
                ptr = ptr.advanced(by: n)
                remaining -= n
            }
        }
    }
}
