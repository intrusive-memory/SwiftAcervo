import Foundation
import Testing

@testable import SwiftAcervo

extension SharedStaticStateSuite.MockURLProtocolSuite {

  /// Multi-file rollback / atomicity contract.
  ///
  /// SwiftAcervo's atomicity guarantee is **per file**: every download streams
  /// to a UUID-named file in `FileManager.default.temporaryDirectory`,
  /// verifies size + SHA-256, and only then `moveItem`s into the destination.
  /// On failure the temp file is unlinked. The destination directory therefore
  /// never observes a partial / half-written file at any path the manifest
  /// declares.
  ///
  /// What we do NOT promise: rolling back files 1 and 3 when file 2 fails. The
  /// other files in the same `downloadFiles` call may have already completed
  /// and been moved into place by the time the failing file's error surfaces
  /// to the task group. Those files are valid (they passed their own size +
  /// hash checks) and are kept on disk so a retry can short-circuit them via
  /// the "already-exists with correct size" skip in
  /// `AcervoDownloader.downloadFiles`.
  ///
  /// `isModelAvailable(_:)` keys off `config.json`, so as long as the failing
  /// file is `config.json` itself, the model is reliably reported unavailable
  /// after a partial failure regardless of which other files completed.
  ///
  /// These tests cover the three documented per-file failure modes:
  ///
  ///   (a) HTTP 500 → `AcervoError.downloadFailed`
  ///   (b) right size, wrong bytes → `AcervoError.integrityCheckFailed`
  ///   (c) short body → `AcervoError.downloadSizeMismatch`
  ///
  /// Each test then asserts that:
  ///
  ///   1. The expected error case is thrown.
  ///   2. The failing file (`config.json`) is NOT present in the destination.
  ///   3. `isModelAvailable(_:in:)` returns `false`.
  ///   4. No `*.tmp` or `*.partial` artifacts remain in the destination tree.
  ///   5. A subsequent download with a fixed responder completes cleanly and
  ///      `isModelAvailable(_:in:)` returns `true` (no wedged state blocks
  ///      retry).
  @Suite("Multi-File Rollback Tests")
  struct MultiFileRollbackTests {

    // MARK: - Fixture

    /// Three-file manifest. Hashes are precomputed for `Data(repeating:count:)`
    /// payloads of the matching byte values; see `mockBytes(for:)`.
    private static func makeManifest(modelId: String) -> CDNManifest {
      let files = [
        CDNManifestFile(
          path: "config.json",
          sha256: "cc8cd41cef907c4d216069122c4b89936211361f9050a717a1e37ad1862e952f",
          sizeBytes: 16
        ),
        CDNManifestFile(
          path: "weights.safetensors",
          sha256: "14d6fc848712815bc1b5fe1ced1b8980eea1e0db781a946dac5aded9769d1984",
          sizeBytes: 1024
        ),
        CDNManifestFile(
          path: "tokenizer.model",
          sha256: "4539cc1fbc3c22bb131672c62f20ff87f3f587ba2d3d4c5b161c271c98c07b38",
          sizeBytes: 4096
        ),
      ]
      let slug = modelId.replacingOccurrences(of: "/", with: "_")
      return CDNManifest(
        manifestVersion: CDNManifest.supportedVersion,
        modelId: modelId,
        slug: slug,
        updatedAt: "2026-04-25T00:00:00Z",
        files: files,
        manifestChecksum: CDNManifest.computeChecksum(from: files.map(\.sha256))
      )
    }

    /// Mock body bytes that satisfy the manifest's size + sha256 entries.
    private static func mockBytes(for path: String) -> Data {
      switch path {
      case "config.json": return Data(repeating: 0x01, count: 16)
      case "weights.safetensors": return Data(repeating: 0x02, count: 1024)
      case "tokenizer.model": return Data(repeating: 0x03, count: 4096)
      default: return Data()
      }
    }

    /// Per-failure-mode payload for the `config.json` URL, used on the first
    /// (failing) `downloadFiles` call.
    enum FailureMode {
      case http500
      case wrongBytes
      case shortBody

      func response(for request: URLRequest) -> (HTTPURLResponse, Data) {
        let url = request.url!
        switch self {
        case .http500:
          let response = HTTPURLResponse(
            url: url,
            statusCode: 500,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/octet-stream"]
          )!
          return (response, Data("internal server error".utf8))

        case .wrongBytes:
          // Same length the manifest declares (16) so the size check passes,
          // but the content (all zeros) hashes to something other than the
          // declared sha256 — triggers integrityCheckFailed.
          let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/octet-stream"]
          )!
          return (response, Data(repeating: 0x00, count: 16))

        case .shortBody:
          // Fewer bytes than declared (8 vs. 16) — triggers downloadSizeMismatch.
          let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/octet-stream"]
          )!
          return (response, Data(repeating: 0x01, count: 8))
        }
      }

      func validateError(_ error: AcervoError) {
        switch (self, error) {
        case (.http500, .downloadFailed(let fileName, let statusCode)):
          #expect(fileName == "config.json")
          #expect(statusCode == 500)
        case (.wrongBytes, .integrityCheckFailed(let file, _, _)):
          #expect(file == "config.json")
        case (.shortBody, .downloadSizeMismatch(let fileName, let expected, let actual)):
          #expect(fileName == "config.json")
          #expect(expected == 16)
          #expect(actual == 8)
        default:
          Issue.record("expected error matching mode \(self), got \(error)")
        }
      }
    }

    /// Builds the responder closure used by `MockURLProtocol`. On the first
    /// call (`failureMode != nil`) the `config.json` URL returns the failure
    /// payload; every other URL returns its valid mock body. On subsequent
    /// calls (`failureMode == nil`) every URL returns its valid mock body.
    private static func makeResponder(
      manifestData: Data,
      failureMode: FailureMode?
    ) -> @Sendable (URLRequest) -> (HTTPURLResponse, Data) {
      return { request in
        let urlString = request.url?.absoluteString ?? ""
        if urlString.hasSuffix("/manifest.json") {
          let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
          )!
          return (response, manifestData)
        }
        let path = request.url?.lastPathComponent ?? ""
        if path == "config.json", let mode = failureMode {
          return mode.response(for: request)
        }
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/octet-stream"]
        )!
        return (response, mockBytes(for: path))
      }
    }

    /// Recursively scans `directory` for files ending in `.tmp` or `.partial`.
    /// Returns the list of offending paths (empty when the destination is
    /// clean).
    private static func partialArtifacts(in directory: URL) -> [String] {
      let fm = FileManager.default
      guard
        let enumerator = fm.enumerator(
          at: directory,
          includingPropertiesForKeys: nil,
          options: [.skipsHiddenFiles]
        )
      else {
        return []
      }
      var matches: [String] = []
      for case let url as URL in enumerator {
        let name = url.lastPathComponent
        if name.hasSuffix(".tmp") || name.hasSuffix(".partial") {
          matches.append(url.path)
        }
      }
      return matches
    }

    // MARK: - Shared test body

    /// Runs the full failure → retry round-trip for a given failure mode.
    /// Factored out so each `@Test` is a thin wrapper that names the mode
    /// (giving readable failure output) without duplicating the body.
    private static func runRollbackScenario(_ mode: FailureMode) async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      try await withIsolatedAcervoState {
        let modelId = "rollback-test/repo-\(UUID().uuidString.prefix(8))"
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
          UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        Acervo.customBaseDirectory = tempDir

        let manifest = makeManifest(modelId: modelId)
        let manifestData = try JSONEncoder().encode(manifest)

        let slug = Acervo.slugify(modelId)
        let destination = tempDir.appendingPathComponent(slug)
        try AcervoDownloader.ensureDirectory(at: destination)

        // ---- First attempt: config.json fails per the failure mode. ----
        MockURLProtocol.responder = makeResponder(
          manifestData: manifestData,
          failureMode: mode
        )

        do {
          try await AcervoDownloader.downloadFiles(
            modelId: modelId,
            requestedFiles: [],
            destination: destination,
            session: MockURLProtocol.session()
          )
          Issue.record("expected failure for mode \(mode), got success")
        } catch let error as AcervoError {
          mode.validateError(error)
        } catch {
          Issue.record("expected AcervoError, got \(error)")
        }

        // Post-condition 1: config.json is NOT on disk.
        let configPath = destination.appendingPathComponent("config.json")
        #expect(
          !FileManager.default.fileExists(atPath: configPath.path),
          "config.json must not be present after failed download for mode \(mode)"
        )

        // Post-condition 2: isModelAvailable returns false.
        #expect(
          !Acervo.isModelAvailable(modelId, in: tempDir),
          "isModelAvailable must be false after failed download for mode \(mode)"
        )

        // Post-condition 3: no `.tmp` or `.partial` artifacts in the model dir.
        let artifacts = partialArtifacts(in: destination)
        #expect(
          artifacts.isEmpty,
          "no temp/partial artifacts allowed in destination, found: \(artifacts)"
        )

        // ---- Second attempt: responder fixed; retry must succeed. ----
        MockURLProtocol.responder = makeResponder(
          manifestData: manifestData,
          failureMode: nil
        )

        try await AcervoDownloader.downloadFiles(
          modelId: modelId,
          requestedFiles: [],
          destination: destination,
          session: MockURLProtocol.session()
        )

        // All three files must now be on disk and isModelAvailable true.
        for file in manifest.files {
          let filePath = destination.appendingPathComponent(file.path)
          #expect(
            FileManager.default.fileExists(atPath: filePath.path),
            "\(file.path) must exist after successful retry"
          )
        }
        #expect(
          Acervo.isModelAvailable(modelId, in: tempDir),
          "isModelAvailable must be true after successful retry"
        )

        // Retry must not have left any partial artifacts either.
        let postRetryArtifacts = partialArtifacts(in: destination)
        #expect(
          postRetryArtifacts.isEmpty,
          "no temp/partial artifacts allowed after retry, found: \(postRetryArtifacts)"
        )
      }
    }

    // MARK: - Tests

    @Test("HTTP 500 on one file: failing file absent, retry succeeds")
    func http500RollbackAndRetry() async throws {
      try await Self.runRollbackScenario(.http500)
    }

    @Test("Wrong bytes on one file: failing file absent, retry succeeds")
    func wrongBytesRollbackAndRetry() async throws {
      try await Self.runRollbackScenario(.wrongBytes)
    }

    @Test("Short body on one file: failing file absent, retry succeeds")
    func shortBodyRollbackAndRetry() async throws {
      try await Self.runRollbackScenario(.shortBody)
    }
  }
}
