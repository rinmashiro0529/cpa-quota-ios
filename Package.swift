// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CPAQuota",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CPAQuotaKit", targets: ["CPAQuotaKit"]),
        .executable(name: "cpa-quota-probe", targets: ["CPAQuotaProbe"])
    ],
    targets: [
        .target(name: "CPAQuotaKit"),
        .executableTarget(name: "CPAQuotaProbe", dependencies: ["CPAQuotaKit"]),
        .testTarget(name: "CPAQuotaKitTests", dependencies: ["CPAQuotaKit"])
    ],
    swiftLanguageModes: [.v6]
)
