// swift-tools-version:5.9
// Nod ID iOS SDK: the member flow (intro, passport scan, NFC read, proof, result) as a Swift package.
// The Rust proving core comes as a prebuilt xcframework in Frameworks/ (made by scripts/sdk-package.sh; not in git, 146 MB).
import PackageDescription

let package = Package(
    name: "NodIDKit",
    platforms: [.iOS(.v17)],
    products: [.library(name: "NodIDKit", targets: ["NodIDKit"])],
    dependencies: [
        // Pinned exactly (CLAUDE.md rule 10). Its OpenSSL dependency is pinned by this package's Package.resolved.
        .package(url: "https://github.com/AndyQ/NFCPassportReader", exact: "2.3.3"),
    ],
    targets: [
        .binaryTarget(name: "MoproBindings", url: "https://github.com/Nod-ID/nodid-ios/releases/download/0.2.0/MoproBindings.xcframework.zip", checksum: "71b8daf1bb8bf6fc7e319141e13daabc39f9a139155fcad28198546c025d76df"),
        .target(
            name: "NodIDKit",
            dependencies: ["MoproBindings", .product(name: "NFCPassportReader", package: "NFCPassportReader")],
            path: "Sources/NodIDKit",
            resources: [.process("PrivacyInfo.xcprivacy")]
        ),
    ]
)
