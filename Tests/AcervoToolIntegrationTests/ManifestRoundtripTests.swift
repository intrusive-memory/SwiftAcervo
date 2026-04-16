#if os(macOS)
import Foundation
import XCTest

@testable import SwiftAcervo
@testable import acervo

/// Integration tests that generate a manifest locally, upload it to the live
/// R2 bucket, fetch it back via the CDN, and assert the bytes are identical.
///
/// All tests skip when `R2_ACCESS_KEY_ID` **or** `HF_TOKEN` is absent so the
/// suite exits 0 in environments without credentials.
final class ManifestRoundtripTests: XCTestCase {

  private var tempDir: URL!
  private var testSlug: String!
  private var bucket: String!
  private var endpoint: String!
  private var publicBaseURL: URL!

  override func setUp() async throws {
    try await super.setUp()

    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("acervo-manifest-roundtrip-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    tempDir = base

    let env = ProcessInfo.processInfo.environment
    bucket = env["R2_BUCKET"] ?? "intrusive-memory-models"
    endpoint = env["R2_ENDPOINT"] ?? "https://\(bucket!).r2.cloudflarestorage.com"

    let publicBaseRaw =
      env["R2_PUBLIC_URL"] ?? "https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev"
    publicBaseURL = URL(string: publicBaseRaw)!

    // Unique slug per test run.
    testSlug = "test_manifest_roundtrip_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
  }

  override func tearDown() async throws {
    let env = ProcessInfo.processInfo.environment
    if env["R2_ACCESS_KEY_ID"] != nil {
      try? removeS3Slug(testSlug, bucket: bucket, endpoint: endpoint)
    }
    if let dir = tempDir {
      try? FileManager.default.removeItem(at: dir)
    }
    try await super.tearDown()
  }

  /// Generates a manifest locally for 3 fixture files, uploads it to the CDN,
  /// fetches it back, and asserts the local and CDN manifest JSON bytes are
  /// identical.
  func testManifestRoundtripBytesAreIdentical() async throws {
    guard ProcessInfo.processInfo.environment["R2_ACCESS_KEY_ID"] != nil else {
      throw XCTSkip("R2_ACCESS_KEY_ID not set")
    }
    guard ProcessInfo.processInfo.environment["HF_TOKEN"] != nil else {
      throw XCTSkip("HF_TOKEN not set")
    }

    // Create 3 small fixture files.
    for i in 0..<3 {
      let content = "manifest roundtrip fixture \(i) — \(UUID().uuidString)\n"
      let fileURL = tempDir.appendingPathComponent("fixture-\(i).txt")
      try Data(content.utf8).write(to: fileURL, options: [.atomic])
    }

    // Generate manifest locally.
    let generator = ManifestGenerator(modelId: "test/manifest-roundtrip")
    let manifestURL = try await generator.generate(directory: tempDir)

    // Read the local manifest bytes before uploading.
    let localManifestData = try Data(contentsOf: manifestURL)

    // Upload the fixture files and the manifest to the CDN.
    let uploader = CDNUploader()
    try await uploader.sync(
      localDirectory: tempDir,
      slug: testSlug,
      bucket: bucket,
      endpoint: endpoint,
      dryRun: false,
      force: false
    )
    try await uploader.uploadManifest(
      localURL: manifestURL,
      slug: testSlug,
      bucket: bucket,
      endpoint: endpoint,
      dryRun: false
    )

    // Fetch the manifest JSON from the CDN.
    let cdnManifestURL = publicBaseURL
      .appendingPathComponent("models", isDirectory: true)
      .appendingPathComponent(testSlug, isDirectory: true)
      .appendingPathComponent("manifest.json")

    let (cdnData, response) = try await URLSession.shared.data(from: cdnManifestURL)
    guard let http = response as? HTTPURLResponse else {
      XCTFail("No HTTP response fetching CDN manifest")
      return
    }
    XCTAssertEqual(http.statusCode, 200, "CDN manifest must return HTTP 200")

    // The CDN manifest must decode and pass verifyChecksum().
    let cdnManifest = try JSONDecoder().decode(CDNManifest.self, from: cdnData)
    XCTAssertTrue(cdnManifest.verifyChecksum(), "CDN manifest must pass verifyChecksum()")

    // The raw JSON bytes must be identical (same encoder, same sort order).
    XCTAssertEqual(
      localManifestData, cdnData,
      "Local and CDN manifest JSON bytes must be identical"
    )
  }

  // MARK: - Helpers

  private func removeS3Slug(_ slug: String, bucket: String, endpoint: String) throws {
    let env = ProcessInfo.processInfo.environment
    guard let accessKey = env["R2_ACCESS_KEY_ID"],
      let secretKey = env["R2_SECRET_ACCESS_KEY"]
    else {
      return
    }

    var awsEnv = env
    awsEnv["AWS_ACCESS_KEY_ID"] = accessKey
    awsEnv["AWS_SECRET_ACCESS_KEY"] = secretKey

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "aws", "s3", "rm",
      "s3://\(bucket)/models/\(slug)/",
      "--recursive",
      "--endpoint-url", endpoint,
    ]
    process.environment = awsEnv
    process.standardOutput = Pipe()
    process.standardError = Pipe()

    try process.run()
    process.waitUntilExit()
  }
}
#endif
