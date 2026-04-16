#if os(macOS)
import Foundation
import XCTest

@testable import SwiftAcervo
@testable import acervo

/// Integration tests that upload small fixture files to a temporary prefix in
/// the live R2 bucket and then verify them via the CDN (CHECKs 5 and 6).
///
/// All tests skip when `R2_ACCESS_KEY_ID` **or** `HF_TOKEN` is absent so the
/// suite exits 0 in environments without credentials.
final class CDNRoundtripTests: XCTestCase {

  private var tempDir: URL!
  private var testPrefix: String!
  private var bucket: String!
  private var endpoint: String!
  private var publicBaseURL: URL!

  override func setUp() async throws {
    try await super.setUp()

    // Create a unique local staging directory.
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("acervo-cdn-roundtrip-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    tempDir = base

    // Resolve R2 configuration from the environment (same approach as CDNUploader).
    let env = ProcessInfo.processInfo.environment
    bucket = env["R2_BUCKET"] ?? "intrusive-memory-models"
    endpoint = env["R2_ENDPOINT"] ?? "https://\(bucket!).r2.cloudflarestorage.com"

    let publicBaseRaw =
      env["R2_PUBLIC_URL"] ?? "https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev"
    publicBaseURL = URL(string: publicBaseRaw)!

    // Each test run uses its own UUID prefix so concurrent runs never collide.
    testPrefix = "test/\(UUID().uuidString)"
  }

  override func tearDown() async throws {
    // Only run cleanup when credentials are present — otherwise there is nothing
    // to clean up (all tests were skipped before uploading anything).
    let env = ProcessInfo.processInfo.environment
    if env["R2_ACCESS_KEY_ID"] != nil {
      try? removeS3Prefix(testPrefix, bucket: bucket, endpoint: endpoint)
    }
    if let dir = tempDir {
      try? FileManager.default.removeItem(at: dir)
    }
    try await super.tearDown()
  }

  /// Uploads 3 small text files to a unique `test/<uuid>/` prefix in the
  /// bucket and asserts CHECK 5 (`verifyManifestOnCDN`) passes.
  func testCHECK5VerifyManifestOnCDNAfterUpload() async throws {
    guard ProcessInfo.processInfo.environment["R2_ACCESS_KEY_ID"] != nil else {
      throw XCTSkip("R2_ACCESS_KEY_ID not set")
    }
    guard ProcessInfo.processInfo.environment["HF_TOKEN"] != nil else {
      throw XCTSkip("HF_TOKEN not set")
    }

    // Create 3 small fixture files.
    let files = try createFixtureFiles(count: 3, in: tempDir)

    // Generate a manifest for the fixture files.
    let generator = ManifestGenerator(modelId: "test/roundtrip")
    _ = try await generator.generate(directory: tempDir)

    let manifestData = try Data(contentsOf: tempDir.appendingPathComponent("manifest.json"))
    let manifest = try JSONDecoder().decode(CDNManifest.self, from: manifestData)

    // Upload to the test prefix using CDNUploader.
    let uploader = CDNUploader()
    let testSlug = testPrefix.replacingOccurrences(of: "/", with: "_")
    try await uploader.sync(
      localDirectory: tempDir,
      slug: testSlug,
      bucket: bucket,
      endpoint: endpoint,
      dryRun: false,
      force: false
    )
    try await uploader.uploadManifest(
      localURL: tempDir.appendingPathComponent("manifest.json"),
      slug: testSlug,
      bucket: bucket,
      endpoint: endpoint,
      dryRun: false
    )

    // CHECK 5: verify the manifest is fetchable and valid on the CDN.
    let cdnManifest = try await uploader.verifyManifestOnCDN(
      publicBaseURL: publicBaseURL,
      slug: testSlug
    )
    XCTAssertTrue(cdnManifest.verifyChecksum(), "CDN manifest checksum must pass CHECK 5")
    XCTAssertEqual(cdnManifest.files.count, files.count + 1) // files + manifest itself excluded

    _ = manifest  // used above; keep reference
  }

  /// After uploading, runs CHECK 6 (`spotCheckFileOnCDN`) on one of the files.
  func testCHECK6SpotCheckFileOnCDNAfterUpload() async throws {
    guard ProcessInfo.processInfo.environment["R2_ACCESS_KEY_ID"] != nil else {
      throw XCTSkip("R2_ACCESS_KEY_ID not set")
    }
    guard ProcessInfo.processInfo.environment["HF_TOKEN"] != nil else {
      throw XCTSkip("HF_TOKEN not set")
    }

    // Create 3 small fixture files.
    _ = try createFixtureFiles(count: 3, in: tempDir)

    // Generate manifest.
    let generator = ManifestGenerator(modelId: "test/spotcheck")
    _ = try await generator.generate(directory: tempDir)

    let manifestData = try Data(contentsOf: tempDir.appendingPathComponent("manifest.json"))
    let manifest = try JSONDecoder().decode(CDNManifest.self, from: manifestData)

    let uploader = CDNUploader()
    let testSlug = testPrefix.replacingOccurrences(of: "/", with: "_")

    // Upload files and manifest.
    try await uploader.sync(
      localDirectory: tempDir,
      slug: testSlug,
      bucket: bucket,
      endpoint: endpoint,
      dryRun: false,
      force: false
    )
    try await uploader.uploadManifest(
      localURL: tempDir.appendingPathComponent("manifest.json"),
      slug: testSlug,
      bucket: bucket,
      endpoint: endpoint,
      dryRun: false
    )

    // CHECK 6: spot-check the first non-manifest file.
    guard let firstEntry = manifest.files.first else {
      XCTFail("Manifest has no file entries")
      return
    }

    try await uploader.spotCheckFileOnCDN(
      publicBaseURL: publicBaseURL,
      slug: testSlug,
      filename: firstEntry.path,
      expectedSHA256: firstEntry.sha256
    )
  }

  // MARK: - Helpers

  /// Creates `count` small text fixture files in `directory` and returns
  /// their relative paths.
  @discardableResult
  private func createFixtureFiles(count: Int, in directory: URL) throws -> [String] {
    var paths: [String] = []
    for i in 0..<count {
      let filename = "fixture-\(i).txt"
      let content = "fixture file \(i) — \(UUID().uuidString)\n"
      let fileURL = directory.appendingPathComponent(filename)
      try Data(content.utf8).write(to: fileURL, options: [.atomic])
      paths.append(filename)
    }
    return paths
  }

  /// Runs `aws s3 rm --recursive` to clean up the test prefix from the bucket.
  private func removeS3Prefix(_ prefix: String, bucket: String, endpoint: String) throws {
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
      "s3://\(bucket)/models/\(prefix.replacingOccurrences(of: "/", with: "_"))/",
      "--recursive",
      "--endpoint-url", endpoint,
    ]
    process.environment = awsEnv
    process.standardOutput = Pipe()
    process.standardError = Pipe()

    try process.run()
    process.waitUntilExit()
    // Ignore exit code — cleanup is best-effort.
  }
}
#endif
