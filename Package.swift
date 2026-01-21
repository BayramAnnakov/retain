// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Retain",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Retain", targets: ["Retain"])
    ],
    dependencies: [
        // SQLite wrapper with FTS5 support
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
        // SwiftUI view testing
        .package(url: "https://github.com/nalexn/ViewInspector.git", from: "0.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Retain",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/Retain"
        ),
        .testTarget(
            name: "RetainTests",
            dependencies: [
                "Retain",
                "ViewInspector",
            ],
            path: "Tests/RetainTests"
        )
    ]
)
