// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Ledger",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Ledger", targets: ["Ledger"])
    ],
    targets: [
        .executableTarget(
            name: "Ledger",
            path: "Sources/Ledger",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
