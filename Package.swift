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
        .binaryTarget(name: "MoproBindings", url: "https://github.com/Nod-ID/nodid-ios/releases/download/0.1.0/MoproBindings.xcframework.zip", checksum: "8634dd36ff282b4255d1c4b926c04cfc7e11daec371f378c66384d9735773c7c"),
        .target(
            name: "NodIDKit",
            dependencies: ["MoproBindings", .product(name: "NFCPassportReader", package: "NFCPassportReader")],
            path: "Sources/NodIDKit",
            resources: [.process("PrivacyInfo.xcprivacy")]
        ),
    ]
)
