import Foundation
import DiskSightCore

/// Talks to the running DiskSight app over its Unix-domain command socket.
/// If the app isn't running, optionally auto-launches it and retries.
struct AppSocketClient: Sendable {
    let socketURL: URL

    enum ClientError: Error, CustomStringConvertible {
        case unreachable(String)

        var description: String {
            switch self {
            case .unreachable(let message): return message
            }
        }
    }

    /// Send a request. If `autoLaunch` and the app is unreachable, launch it and
    /// retry for a few seconds before giving up with an actionable error.
    func send(_ request: ScanSocketRequest, autoLaunch: Bool) async throws -> ScanSocketResponse {
        if let response = roundTrip(request) { return response }

        guard autoLaunch else {
            throw ClientError.unreachable(
                "The DiskSight app isn't running, so this scan command can't be served. Open DiskSight and try again."
            )
        }

        Log.line("app unreachable; launching DiskSight")
        launchApp()

        // Poll for the socket to come up (~12s).
        for _ in 0..<48 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let response = roundTrip(request) { return response }
        }

        throw ClientError.unreachable(
            "Could not reach the DiskSight app at \(socketURL.path) after launching it. Open DiskSight, grant Full Disk Access if prompted, then retry."
        )
    }

    // MARK: - Launch

    private func launchApp() {
        // Try by bundle id first, then by name. `-g` keeps it from stealing focus.
        for args in [["-g", "-b", "com.disksight.app"], ["-g", "-a", "DiskSight"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = args
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 { return }
            } catch {
                continue
            }
        }
    }

    // MARK: - One request/response round trip

    private func roundTrip(_ request: ScanSocketRequest) -> ScanSocketResponse? {
        let path = socketURL.path
        guard path.utf8.count < 104 else { return nil }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

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
        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, addrSize)
            }
        }
        guard connectResult == 0 else { return nil }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        // Never block forever on a wedged/half-open app. On timeout read()/write()
        // return -1 and roundTrip returns nil (the caller then retries or surfaces
        // an actionable error).
        var rcv = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rcv, socklen_t(MemoryLayout<timeval>.size))
        var snd = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &snd, socklen_t(MemoryLayout<timeval>.size))

        guard let requestData = try? JSONEncoder().encode(request) else { return nil }
        writeAll(fd: fd, data: requestData)

        guard let responseData = readLine(fd: fd) else { return nil }
        return try? JSONDecoder().decode(ScanSocketResponse.self, from: responseData)
    }

    private func readLine(fd: Int32, maxBytes: Int = 256 * 1024) -> Data? {
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
