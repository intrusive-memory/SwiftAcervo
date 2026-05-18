import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

/// Tests for the resumable-download path in `streamDownloadFile`.
///
/// These tests cover the five branches introduced by WU1 Sortie 1:
///
///   1. Genuine partial → resume via HTTP `Range` header (206 response).
///   2. Server ignores `Range` and returns 200 with full body → truncate and
///      restart, hasher reset.
///   3. Oversized pre-existing part file → delete and start fresh, no range
///      header sent.
///   4. Already-complete part file with matching SHA → atomic rename, NO
///      network request issued.
///   5. Already-complete part file with mismatched SHA → delete, re-download
///      from scratch.
///
/// One additional test exercises the parent-directory-creation move in task
/// #3 by using a manifest entry with a `/` in its path. All tests nest under
/// `SharedStaticStateSuite.MockURLProtocolSuite` because they mutate
/// `MockURLProtocol`'s process-global responder + request counter.
extension SharedStaticStateSuite.MockURLProtocolSuite {

  @Suite("Resumable Download Tests")
  struct ResumableDownloadTests {

    // MARK: - Fixture helpers

    /// Synthetic 16 MiB body. Deterministic bytes so SHA-256 is stable.
    private static let totalSize: Int = 16 * 1024 * 1024
    private static let halfSize: Int = 8 * 1024 * 1024

    /// Builds the synthetic test body. Deterministic so the test's expected
    /// SHA matches across runs.
    private static func makeBody() -> Data {
      Data(bytes: (0..<totalSize).map { UInt8($0 % 256) }, count: totalSize)
    }

    /// Pre-computed SHA-256 of `makeBody()`. Verified inline by the
    /// `complete_correctHashSkipsNetwork` test before it asserts the request
    /// count — so if this constant drifts, the test catches it.
    private static func makeManifestFile(path: String) -> CDNManifestFile {
      let body = makeBody()
      let digest = SHA256.hash(data: body)
      let sha = digest.map { String(format: "%02x", $0) }.joined()
      return CDNManifestFile(
        path: path,
        sha256: sha,
        sizeBytes: Int64(body.count)
      )
    }

    /// Builds a fresh isolated working directory.
    private static func makeTempDir() throws -> URL {
      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ResumableDownloadTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      return dir
    }

    private static func cleanupTempDir(_ dir: URL) {
      try? FileManager.default.removeItem(at: dir)
    }

    /// Pre-populates `partURL` with the given bytes.
    private static func seedPartFile(_ partURL: URL, with data: Data) throws {
      try data.write(to: partURL)
    }

    private static func makeSourceURL(path: String = "test_repo/payload.bin") -> URL {
      URL(
        string: "https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/\(path)"
      )!
    }

    // MARK: - Test 1: Resume via Range header

    @Test("Genuine partial sends Range header and resumes from offset")
    func partial_resumeViaRangeHeader() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let tempDir = try Self.makeTempDir()
      defer { Self.cleanupTempDir(tempDir) }

      let body = Self.makeBody()
      let manifestFile = Self.makeManifestFile(path: "payload.bin")
      let destination = tempDir.appendingPathComponent("payload.bin")
      let partURL = destination.appendingPathExtension("part")

      // Pre-populate the part file with the first half of the body. This is
      // the "genuine partial" scenario: 0 < partSize < manifest.sizeBytes.
      try Self.seedPartFile(partURL, with: body.prefix(Self.halfSize))

      // Responder asserts that the incoming request carries the expected
      // Range header and returns 206 with the second half of the body.
      MockURLProtocol.responder = { request in
        let rangeHeader = request.value(forHTTPHeaderField: "Range")
        #expect(rangeHeader == "bytes=\(Self.halfSize)-")
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 206,
          httpVersion: "HTTP/1.1",
          headerFields: [
            "Content-Type": "application/octet-stream",
            "Content-Range": "bytes \(Self.halfSize)-\(Self.totalSize - 1)/\(Self.totalSize)",
          ]
        )!
        return (response, body.suffix(from: Self.halfSize))
      }

      try await AcervoDownloader.downloadFile(
        from: Self.makeSourceURL(),
        to: destination,
        manifestFile: manifestFile,
        session: MockURLProtocol.session()
      )

      // Final file matches the synthetic body byte-for-byte.
      #expect(FileManager.default.fileExists(atPath: destination.path))
      let written = try Data(contentsOf: destination)
      #expect(written == body)
      // Part file has been atomic-renamed away.
      #expect(!FileManager.default.fileExists(atPath: partURL.path))
      #expect(MockURLProtocol.requestCount == 1)
    }

    // MARK: - Test 2: Server ignores Range → 200 OK fallback

    @Test("Server returns 200 instead of 206: hasher resets, full body consumed")
    func partial_serverIgnoresRangeReturns200() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let tempDir = try Self.makeTempDir()
      defer { Self.cleanupTempDir(tempDir) }

      let body = Self.makeBody()
      let manifestFile = Self.makeManifestFile(path: "payload.bin")
      let destination = tempDir.appendingPathComponent("payload.bin")
      let partURL = destination.appendingPathExtension("part")

      // Pre-populate `.part` with 8 MiB of the body (same bytes as a real
      // partial would contain, so this exercises the "we sent Range, server
      // ignored it" path rather than any byte-level mismatch path).
      try Self.seedPartFile(partURL, with: body.prefix(Self.halfSize))

      // Responder ignores the Range header and returns the full body at 200.
      MockURLProtocol.responder = { request in
        // We DID send the Range header, but the responder pretends the
        // server doesn't support range requests.
        _ = request.value(forHTTPHeaderField: "Range")
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/octet-stream"]
        )!
        return (response, body)
      }

      try await AcervoDownloader.downloadFile(
        from: Self.makeSourceURL(),
        to: destination,
        manifestFile: manifestFile,
        session: MockURLProtocol.session()
      )

      #expect(FileManager.default.fileExists(atPath: destination.path))
      let written = try Data(contentsOf: destination)
      #expect(written == body)
      #expect(!FileManager.default.fileExists(atPath: partURL.path))
      #expect(MockURLProtocol.requestCount == 1)
    }

    // MARK: - Test 3: Oversized part file → delete and restart

    @Test("Oversized part file is deleted; no Range header sent on retry")
    func partial_oversizedTriggersFullRedownload() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let tempDir = try Self.makeTempDir()
      defer { Self.cleanupTempDir(tempDir) }

      let body = Self.makeBody()
      let manifestFile = Self.makeManifestFile(path: "payload.bin")
      let destination = tempDir.appendingPathComponent("payload.bin")
      let partURL = destination.appendingPathExtension("part")

      // Pre-populate `.part` with 32 MiB of garbage (manifest says 16 MiB).
      let oversized = Data(repeating: 0xFF, count: 2 * Self.totalSize)
      try Self.seedPartFile(partURL, with: oversized)

      // Responder asserts NO Range header was sent and returns the full body
      // at 200. (Oversized part file triggers a delete-and-restart, which
      // means the eventual request goes out as a normal full-body GET.)
      MockURLProtocol.responder = { request in
        #expect(request.value(forHTTPHeaderField: "Range") == nil)
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/octet-stream"]
        )!
        return (response, body)
      }

      try await AcervoDownloader.downloadFile(
        from: Self.makeSourceURL(),
        to: destination,
        manifestFile: manifestFile,
        session: MockURLProtocol.session()
      )

      #expect(FileManager.default.fileExists(atPath: destination.path))
      let written = try Data(contentsOf: destination)
      #expect(written == body)
      // 32 MiB garbage was deleted and replaced by the verified body.
      #expect(!FileManager.default.fileExists(atPath: partURL.path))
      #expect(MockURLProtocol.requestCount == 1)
    }

    // MARK: - Test 4: Complete part file with matching SHA skips network

    @Test("Complete part file with correct SHA short-circuits the network")
    func complete_correctHashSkipsNetwork() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let tempDir = try Self.makeTempDir()
      defer { Self.cleanupTempDir(tempDir) }

      let body = Self.makeBody()
      let manifestFile = Self.makeManifestFile(path: "payload.bin")
      let destination = tempDir.appendingPathComponent("payload.bin")
      let partURL = destination.appendingPathExtension("part")

      // Sanity: the manifest's SHA matches the body. If this drifts, the
      // test catches the constant rot.
      let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
      #expect(bodyHash == manifestFile.sha256)

      // Pre-populate `.part` with the EXACT manifest body.
      try Self.seedPartFile(partURL, with: body)

      // Responder is a tripwire — if any network call slips through, the
      // request count will register and the assertion below will fail.
      MockURLProtocol.responder = { _ in
        Issue.record("network should not be called when part file is already complete")
        let response = HTTPURLResponse(
          url: URL(string: "https://example.invalid")!,
          statusCode: 500,
          httpVersion: "HTTP/1.1",
          headerFields: nil
        )!
        return (response, Data())
      }

      try await AcervoDownloader.downloadFile(
        from: Self.makeSourceURL(),
        to: destination,
        manifestFile: manifestFile,
        session: MockURLProtocol.session()
      )

      #expect(MockURLProtocol.requestCount == 0)
      #expect(FileManager.default.fileExists(atPath: destination.path))
      #expect(!FileManager.default.fileExists(atPath: partURL.path))
      let written = try Data(contentsOf: destination)
      #expect(written == body)
    }

    // MARK: - Test 5: Complete part file with wrong SHA → delete + redownload

    @Test("Complete part file with wrong SHA is deleted and re-downloaded")
    func complete_wrongHashDeletesAndRedownloads() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let tempDir = try Self.makeTempDir()
      defer { Self.cleanupTempDir(tempDir) }

      let body = Self.makeBody()
      let manifestFile = Self.makeManifestFile(path: "payload.bin")
      let destination = tempDir.appendingPathComponent("payload.bin")
      let partURL = destination.appendingPathExtension("part")

      // 16 MiB of garbage (size matches manifest, SHA does not).
      let garbage = Data(repeating: 0xAA, count: Self.totalSize)
      #expect(garbage.count == Int(manifestFile.sizeBytes))
      let garbageHash = SHA256.hash(data: garbage).map { String(format: "%02x", $0) }.joined()
      #expect(garbageHash != manifestFile.sha256)
      try Self.seedPartFile(partURL, with: garbage)

      // Responder returns the correct body at 200; no Range header expected
      // (the wrong-SHA branch deletes the part file before sending the
      // request).
      MockURLProtocol.responder = { request in
        #expect(request.value(forHTTPHeaderField: "Range") == nil)
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/octet-stream"]
        )!
        return (response, body)
      }

      try await AcervoDownloader.downloadFile(
        from: Self.makeSourceURL(),
        to: destination,
        manifestFile: manifestFile,
        session: MockURLProtocol.session()
      )

      #expect(MockURLProtocol.requestCount == 1)
      #expect(FileManager.default.fileExists(atPath: destination.path))
      let written = try Data(contentsOf: destination)
      #expect(written == body)
      #expect(!FileManager.default.fileExists(atPath: partURL.path))
    }

    // MARK: - Test 6: Subdirectory path exercises parent-dir creation

    @Test("Subdirectory manifest path creates parent dirs before opening part")
    func subdirectory_parentDirectoryIsCreatedBeforePartFile() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let tempDir = try Self.makeTempDir()
      defer { Self.cleanupTempDir(tempDir) }

      let body = Self.makeBody()
      let manifestFile = Self.makeManifestFile(path: "speech_tokenizer/config.json")
      // Destination uses a sub-path the test does NOT pre-create.
      let destination = tempDir.appendingPathComponent("speech_tokenizer/config.json")

      // Sanity: the parent dir doesn't exist yet. The function must create it.
      let parentDir = destination.deletingLastPathComponent()
      #expect(!FileManager.default.fileExists(atPath: parentDir.path))

      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/octet-stream"]
        )!
        return (response, body)
      }

      try await AcervoDownloader.downloadFile(
        from: Self.makeSourceURL(path: "test_repo/speech_tokenizer/config.json"),
        to: destination,
        manifestFile: manifestFile,
        session: MockURLProtocol.session()
      )

      #expect(FileManager.default.fileExists(atPath: parentDir.path))
      #expect(FileManager.default.fileExists(atPath: destination.path))
      let written = try Data(contentsOf: destination)
      #expect(written == body)
      let partURL = destination.appendingPathExtension("part")
      #expect(!FileManager.default.fileExists(atPath: partURL.path))
    }
  }
}
