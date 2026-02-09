import Foundation
import xxHash_Swift

enum FileHasher {
    private static let partialChunkSize = 8192 // 8KB

    /// Compute xxHash of first 8KB + last 8KB of a file (partial hash for quick comparison)
    static func partialHash(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        handle.seek(toFileOffset: 0)

        var data = Data()

        if fileSize <= UInt64(partialChunkSize * 2) {
            // Small file — hash entire content
            handle.seek(toFileOffset: 0)
            data = handle.readData(ofLength: Int(fileSize))
        } else {
            // Read first 8KB
            handle.seek(toFileOffset: 0)
            data.append(handle.readData(ofLength: partialChunkSize))

            // Read last 8KB
            handle.seek(toFileOffset: fileSize - UInt64(partialChunkSize))
            data.append(handle.readData(ofLength: partialChunkSize))
        }

        let hash = XXH64.digest(data)
        return String(format: "%016llx", hash)
    }

    /// Compute xxHash of entire file content
    static func fullHash(of url: URL, progressHandler: ((Int64) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let bufferSize = 1024 * 1024 // 1MB chunks
        var totalRead: Int64 = 0

        // Use streaming hash
        var hasher = XXH64()

        while true {
            let chunk = handle.readData(ofLength: bufferSize)
            if chunk.isEmpty { break }
            hasher.update(chunk)
            totalRead += Int64(chunk.count)
            progressHandler?(totalRead)
        }

        let hash = hasher.digest()
        return String(format: "%016llx", hash)
    }
}
