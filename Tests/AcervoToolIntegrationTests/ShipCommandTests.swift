#if os(macOS)
import Foundation
import XCTest

@testable import SwiftAcervo
@testable import acervo

/// Integration tests that run the full `ship` pipeline against a small public
/// model, then verify the CDN manifest is fetchable and valid.
///
/// All tests skip when `R2_ACCESS_KEY_ID` **or** `HF_TOKEN` is absent so the
/// suite exits 0 in environments without credentials.
final class ShipCommandTests: XCTestCase {

  /// A tiny public model: `hf-internal-testing/tiny-random-GPT2` has only a
  /// handful of small files, making it suitable for integration testing.
  private let testModelId = "hf-internal-testing/tiny-random-GPT2"

  private var stagingDir: URL!
  private var testSlug: String!
  private var bucket: String!
  private var endpoint: String!
  private var publicBaseURL: URL!

  override func setUp() async throws {
    try await super.setUp()

    let env = ProcessInfo.processInfo.environment
    bucket = env["R2_BUCKET"] ?? "intrusive-memory-models"
    endpoint = env["R2_ENDPOINT"] ?? "https://\(bucket!).r2.cloudflarestorage.com"

    let publicBaseRaw =
      env["R2_PUBLIC_URL"] ?? "https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev"
    publicBaseURL = URL(string: publicBaseRaw)!

    // Use a unique test slug so we never collide with production models.
    testSlug = "test_ship_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

    // Create a staging directory for the download phase.
    stagingDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("acervo-ship-integration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    let env = ProcessInfo.processInfo.environment
    if env["R2_ACCESS_KEY_ID"] != nil {
      try? removeS3Slug(testSlug, bucket: bucket, endpoint: endpoint)
    }
    if let dir = stagingDir {
      try? FileManager.default.removeItem(at: dir)
    }
    try await super.tearDown()
  }

  /// Runs the full ship pipeline manually (download → manifest → upload →
  /// verify), targeting a known small public model, and asserts the CDN
  /// manifest is fetchable and passes `CDNManifest.verifyChecksum()`.
  ///
  /// This test exercises the same code path as `ShipCommand.run()` but
  /// drives the components directly (without spawning a subprocess) so the
  /// test remains self-contained and avoids requiring the `acervo` binary to
  /// be installed.
  func testShipPipelineProducesValidCDNManifest() async throws {
    guard ProcessInfo.processInfo.environment["R2_ACCESS_KEY_ID"] != nil else {
      throw XCTSkip("R2_ACCESS_KEY_ID not set")
    }
    guard ProcessInfo.processInfo.environment["HF_TOKEN"] != nil else {
      throw XCTSkip("HF_TOKEN not set")
    }

    let modelStagingDir = stagingDir.appendingPathComponent(testSlug, isDirectory: true)
    try FileManager.default.createDirectory(at: modelStagingDir, withIntermediateDirectories: true)

    // ── DOWNLOAD PHASE ────────────────────────────────────────────────────
    // Download only config.json to keep the test fast.
    try downloadFile(modelId: testModelId, filename: "config.json", into: modelStagingDir)

    let configFileURL = modelStagingDir.appendingPathComponent("config.json")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: configFileURL.path),
      "config.json must exist after download"
    )

    // CHECK 1: verify the downloaded file against the HF LFS API.
    let actualSHA256 = try IntegrityVerification.sha256(of: configFileURL)
    let hfClient = HuggingFaceClient()
    try await hfClient.verifyLFS(
      modelId: testModelId,
      filename: "config.json",
      actualSHA256: actualSHA256,
      stagingURL: configFileURL
    )

    // ── UPLOAD PHASE ──────────────────────────────────────────────────────
    // CHECK 2+3: generate manifest.
    let generator = ManifestGenerator(modelId: testModelId)
    let manifestURL = try await generator.generate(directory: modelStagingDir)

    let manifestData = try Data(contentsOf: manifestURL)
    let manifest = try JSONDecoder().decode(CDNManifest.self, from: manifestData)
    XCTAssertTrue(manifest.verifyChecksum(), "Local manifest must pass verifyChecksum()")

    // CHECK 4: pre-upload verification.
    let uploader = CDNUploader()
    try await uploader.verifyBeforeUpload(directory: modelStagingDir, manifest: manifest)

    // Sync and upload manifest.
    try await uploader.sync(
      localDirectory: modelStagingDir,
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

    // CHECK 5: CDN manifest is fetchable and valid.
    let cdnManifest = try await uploader.verifyManifestOnCDN(
      publicBaseURL: publicBaseURL,
      slug: testSlug
    )
    XCTAssertTrue(cdnManifest.verifyChecksum(), "CDN manifest must pass verifyChecksum() (CHECK 5)")

    // CHECK 6: spot-check config.json on CDN.
    if let configEntry = manifest.files.first(where: { $0.path == "config.json" }) {
      try await uploader.spotCheckFileOnCDN(
        publicBaseURL: publicBaseURL,
        slug: testSlug,
        filename: "config.json",
        expectedSHA256: configEntry.sha256
      )
    }
  }

  // MARK: - Helpers

  private func downloadFile(modelId: String, filename: String, into directory: URL) throws {
    var environment = ProcessInfo.processInfo.environment
    environment["TRANSFORMERS_VERBOSITY"] = "error"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "huggingface-cli",
      "download",
      modelId,
      filename,
      "--local-dir",
      directory.path,
    ]
    process.environment = environment
    process.standardOutput = Pipe()

    let stderrPipe = Pipe()
    process.standardError = stderrPipe

    try process.run()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      let stderr = String(data: stderrData, encoding: .utf8) ?? "<non-utf8>"
      throw NSError(
        domain: "ShipCommandTests",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: "huggingface-cli failed: \(stderr)"]
      )
    }
  }

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
