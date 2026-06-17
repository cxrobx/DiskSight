import Foundation
import DiskSightCore

/// Lazily opens and caches the read-only reader. The database may not exist when
/// the server starts (the user may run their first scan later), so we retry
/// opening on each call until it succeeds, then reuse the connection.
actor ReaderProvider {
    private var cached: DiskSightReader?
    private let databaseURL: URL

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    func reader() throws -> DiskSightReader {
        if let cached { return cached }
        let reader = try DiskSightReader(databaseURL: databaseURL)
        cached = reader
        return reader
    }
}

enum JSON {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
