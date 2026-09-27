// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CowryKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "LedgerCore", targets: ["LedgerCore"]),
        .library(name: "Ledger", targets: ["Ledger"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.9.0"),
    ],
    targets: [
        .target(name: "LedgerCore"),
        .target(
            name: "Ledger",
            dependencies: [
                "LedgerCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(name: "LedgerCoreTests", dependencies: ["LedgerCore"]),
        .testTarget(
            name: "LedgerTests",
            dependencies: ["Ledger", "LedgerCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
    ]
)
