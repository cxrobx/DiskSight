// swift-tools-version: 6.0
import PackageDescription

// DiskSight SPM package.
//
// This package vends two products that live ALONGSIDE the Xcode app
// (DiskSight.xcodeproj). The app itself is NOT built from this package — it
// keeps its own target and SwiftPM package references in the .pbxproj. This
// package exists so the standalone MCP server can reuse the app's verified,
// headless-clean read code without duplicating SQL.
//
//   • DiskSightCore  — a library that compiles the SAME physical source files
//     the app uses (Database, FileRepository, models, analysis read helpers)
//     via an explicit `sources:` list rooted at the existing `DiskSight/`
//     directory. One source of truth; no file moves. Built in Swift 5 language
//     mode to match the app target exactly.
//
//   • DiskSightMCP   — the standalone MCP stdio server executable. Links the
//     official MCP Swift SDK and DiskSightCore. This is the ONLY target that
//     links the SDK; the app never does. Built in Swift 6 language mode.
//
// GRDB is pinned to the same 7.x line the Xcode project resolves (7.8.0), so
// the shared code compiles identically in both build systems.
let package = Package(
    name: "DiskSight",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiskSightCore", targets: ["DiskSightCore"]),
        .executable(name: "DiskSightMCP", targets: ["DiskSightMCP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "7.0.0")),
        // Pinned to 0.10.2: it has the Server/StdioTransport/withMethodHandler
        // API we use, but unlike 0.11.0+ its source does not use the Swift 6.2-only
        // `withThrowingTaskGroup { }` shorthand, so it compiles on Swift 6.0.3.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.10.2"),
    ],
    targets: [
        // Shared read code — compiles the existing app source files in place.
        .target(
            name: "DiskSightCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "DiskSight",
            sources: [
                "Models/FileNode.swift",
                "Models/ScanSession.swift",
                "Models/DuplicateGroup.swift",
                "Models/FileCategory.swift",
                "Models/CleanupRecommendation.swift",
                "Services/Storage/Database.swift",
                "Services/Storage/FileRepository.swift",
                "Services/Analysis/CacheDetector.swift",
                "Services/Analysis/GrowthFinder.swift",
                "Services/Analysis/StaleFinder.swift",
                "Utilities/Extensions.swift",
                "Services/MCP/MCPScanProtocol.swift",
                "Services/MCP/DiskSightReader.swift",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // Standalone MCP stdio server.
        .executableTarget(
            name: "DiskSightMCP",
            dependencies: [
                "DiskSightCore",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/DiskSightMCP"
        ),
        .testTarget(
            name: "DiskSightCoreTests",
            dependencies: ["DiskSightCore"],
            path: "Tests/DiskSightCoreTests"
        ),
    ]
)
