// swift-tools-version: 5.9
import PackageDescription

// BillCore holds all of the pure, Foundation-only logic (parsing, merchant
// normalisation, rule-based categorisation and analytics) so it can be unit
// tested with `swift test` without a simulator.
let package = Package(
    name: "BillCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BillCore", targets: ["BillCore"])
    ],
    targets: [
        .target(name: "BillCore"),
        .testTarget(name: "BillCoreTests", dependencies: ["BillCore"])
    ]
)
