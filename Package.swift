// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DiskSightDeps",
    platforms: [.macOS(.v14)],
    products: [],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
        .package(url: "https://github.com/daisuke-t-jp/xxHash-Swift.git", from: "1.1.1"),
    ],
    targets: []
)
