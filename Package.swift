// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CPAQuota",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CPAQuotaKit", targets: ["CPAQuotaKit"]),
        .library(name: "CPAQuotaActivity", targets: ["CPAQuotaActivity"]),
        .library(name: "CPAQuotaChat", targets: ["CPAQuotaChat"]),
        .library(name: "CPAQuotaUI", targets: ["CPAQuotaUI"]),
        .executable(name: "cpa-quota-probe", targets: ["CPAQuotaProbe"]),
        .library(name: "CPAQuotaApp", targets: ["CPAQuotaApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/huggingface/AnyLanguageModel", exact: "1.3.0"),
        // Pinned to the v0.7.0 tag commit: a version pin is rejected because the
        // package itself depends on revision-pinned packages (highlightswift, iosMath).
        .package(url: "https://github.com/microsoft/SwiftStreamingMarkdown",
                 revision: "5f7c04e0558df6146f90d482edb62cb456986bda")
    ],
    targets: [
        .target(name: "CPAQuotaKit"),
        .target(name: "CPAQuotaActivity", dependencies: ["CPAQuotaKit"]),
        .target(name: "CPAQuotaChat", dependencies: [
            "CPAQuotaKit",
            .product(name: "AnyLanguageModel", package: "AnyLanguageModel")
        ]),
        .target(name: "CPAQuotaUI", dependencies: [
            "CPAQuotaKit",
            "CPAQuotaActivity",
            "CPAQuotaChat",
            .product(name: "SwiftStreamingMarkdown", package: "SwiftStreamingMarkdown",
                     condition: .when(platforms: [.iOS]))
        ]),
        .executableTarget(name: "CPAQuotaProbe", dependencies: ["CPAQuotaKit"]),
        .target(name: "CPAQuotaApp", dependencies: ["CPAQuotaKit", "CPAQuotaChat", "CPAQuotaUI"]),
        .testTarget(name: "CPAQuotaKitTests", dependencies: ["CPAQuotaKit", "CPAQuotaChat", "CPAQuotaUI", "CPAQuotaActivity"],
                    path: "Tests", sources: ["CPAQuotaKitTests"],
                    resources: [.copy("ContractFixtures")])
    ],
    swiftLanguageModes: [.v6]
)
