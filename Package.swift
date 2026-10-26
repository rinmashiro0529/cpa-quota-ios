// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CPAQuota",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CPAQuotaKit", targets: ["CPAQuotaKit"]),
        .library(name: "CPAQuotaUI", targets: ["CPAQuotaUI"]),
        .executable(name: "cpa-quota-probe", targets: ["CPAQuotaProbe"]),
        .library(name: "CPAQuotaApp", targets: ["CPAQuotaApp"])
    ],
    targets: [
        .target(name: "CPAQuotaKit"),
        .target(name: "CPAQuotaUI", dependencies: ["CPAQuotaKit"]),
        .executableTarget(name: "CPAQuotaProbe", dependencies: ["CPAQuotaKit"]),
        .target(name: "CPAQuotaApp", dependencies: ["CPAQuotaKit", "CPAQuotaUI"]),
        .testTarget(name: "CPAQuotaKitTests", dependencies: ["CPAQuotaKit", "CPAQuotaUI"])
    ],
    swiftLanguageModes: [.v6]
)
