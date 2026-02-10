import Foundation

// MARK: - File Category Types

enum FileCategoryType: String, Codable, CaseIterable, Identifiable {
    case buildArtifact = "Build Artifact"
    case cache = "Cache"
    case log = "Log"
    case temp = "Temporary"
    case download = "Download"
    case media = "Media"
    case document = "Document"
    case sourceCode = "Source Code"
    case packageManager = "Package Manager"
    case backup = "Backup"
    case systemData = "System Data"
    case unknown = "Unknown"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .buildArtifact: return "hammer"
        case .cache: return "internaldrive"
        case .log: return "doc.text"
        case .temp: return "clock.badge.xmark"
        case .download: return "arrow.down.circle"
        case .media: return "photo"
        case .document: return "doc.richtext"
        case .sourceCode: return "chevron.left.forwardslash.chevron.right"
        case .packageManager: return "shippingbox"
        case .backup: return "externaldrive.badge.timemachine"
        case .systemData: return "gearshape"
        case .unknown: return "questionmark.folder"
        }
    }
}

// MARK: - Deletion Confidence

enum DeletionConfidence: String, Codable, CaseIterable, Comparable {
    case safe = "safe"       // Green — auto-regenerates, no user data
    case caution = "caution" // Yellow — likely safe but review recommended
    case risky = "risky"     // Red — may cause issues if deleted
    case keep = "keep"       // Blue — should not be deleted

    var label: String {
        switch self {
        case .safe: return "Safe"
        case .caution: return "Caution"
        case .risky: return "Risky"
        case .keep: return "Keep"
        }
    }

    var sortOrder: Int {
        switch self {
        case .safe: return 0
        case .caution: return 1
        case .risky: return 2
        case .keep: return 3
        }
    }

    static func < (lhs: DeletionConfidence, rhs: DeletionConfidence) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

// MARK: - Cleanup Signal

enum CleanupSignal: String, Codable {
    case stale = "Stale"
    case duplicate = "Duplicate"
    case knownCache = "Cache"
    case buildArtifact = "Build"
    case logFile = "Log"
    case tempFile = "Temp"
    case largeFile = "Large"
    case oldDownload = "Old Download"
    case packageCache = "Packages"
}
