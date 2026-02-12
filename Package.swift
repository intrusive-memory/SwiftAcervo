// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SwiftAcervo",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
    ],
    products: [
        .library(
            name: "SwiftAcervo",
            targets: ["SwiftAcervo"]
        )
    ],
    targets: [
        .target(
            name: "SwiftAcervo"
        ),
        .testTarget(
            name: "SwiftAcervoTests",
            dependencies: ["SwiftAcervo"]
        )
    ],
    swiftLanguageModes: [.v6]
)
