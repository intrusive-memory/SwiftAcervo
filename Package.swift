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
    .package(url: "https://github.com/apple/swift-argument-parser", .upToNextMajor(from: "1.7.1")),
    .package(url: "https://github.com/jkandzi/Progress.swift", .upToNextMajor(from: "0.4.0")),
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
        .product(name: "Progress", package: "Progress.swift"),
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
