// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "SwiftAcervo",
  platforms: [
    .macOS(.v26),
    .iOS(.v26),
  ],
  products: [
    .library(
      name: "SwiftAcervo",
      targets: ["SwiftAcervo"]
    ),
    .executable(name: "acervo", targets: ["acervo"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
  ],
  targets: [
    .target(
      name: "SwiftAcervo"
    ),
    .executableTarget(
      name: "acervo",
      dependencies: [
        "SwiftAcervo",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      path: "Sources/acervo",
      swiftSettings: [
        .enableUpcomingFeature("StrictConcurrency")
      ]
    ),
    .testTarget(
      name: "SwiftAcervoTests",
      dependencies: ["SwiftAcervo"]
    ),
    .testTarget(
      name: "AcervoToolTests",
      dependencies: ["acervo", "SwiftAcervo"],
      path: "Tests/AcervoToolTests"
    ),
    .testTarget(
      name: "AcervoToolIntegrationTests",
      dependencies: ["acervo", "SwiftAcervo"],
      path: "Tests/AcervoToolIntegrationTests"
    ),
  ],
  swiftLanguageModes: [.v6]
)
