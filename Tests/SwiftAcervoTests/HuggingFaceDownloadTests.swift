// HuggingFaceDownloadTests.swift
// SwiftAcervoTests
//
// Coverage for the native refetch-from-source path:
// `HuggingFaceClient.downloadRepo(modelId:into:files:revision:)`.
//
// The download is driven entirely against `MockURLProtocol`, which routes
// the tree-enumeration request and the per-file `resolve` GETs to in-memory
// fixtures — no network. The tests assert the happy path (files materialize
// with the right bytes, including a nested subfolder) and the size-mismatch
// guard that protects against the silent-incomplete (Xet-pointer) failure
// mode.

import Foundation
import Testing

@testable import SwiftAcervo

extension SharedStaticStateSuite.MockURLProtocolSuite {

  @Suite("HuggingFaceClient.downloadRepo")
  struct HuggingFaceDownloadTests {

    private static func tempDir() -> URL {
      let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("hf-download-\(UUID().uuidString)", isDirectory: true)
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    }

    /// Installs a responder that serves a tree listing for `/tree/` requests
    /// and the matching bytes for `/resolve/main/<path>` requests. `treeSizes`
    /// lets a caller advertise a size that differs from the real payload to
    /// exercise the mismatch guard.
    private static func installResponder(
      files: [String: Data],
      treeSizes: [String: Int64]? = nil
    ) {
      let entries = files.map { (path, data) -> String in
        let size = treeSizes?[path] ?? Int64(data.count)
        return "{\"type\":\"file\",\"path\":\"\(path)\",\"size\":\(size)}"
      }
      let treeJSON = "[\(entries.joined(separator: ","))]"
      let treeData = Data(treeJSON.utf8)

      MockURLProtocol.responder = { request in
        let url = request.url!
        let path = url.path
        func http(_ code: Int) -> HTTPURLResponse {
          HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
        }
        if path.contains("/tree/") {
          return (http(200), treeData)
        }
        if let range = path.range(of: "/resolve/main/") {
          let rel = String(path[range.upperBound...])
          if let body = files[rel] {
            return (http(200), body)
          }
          return (http(404), Data())
        }
        return (http(500), Data())
      }
    }

    // MARK: - Happy path

    @Test("downloadRepo materializes every file, including nested subfolders")
    func downloadsAllFiles() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let config = Data("{\"model_type\":\"flux2\"}".utf8)
      let shard = Data(repeating: 0xAB, count: 4096)
      Self.installResponder(files: [
        "config.json": config,
        "transformer/model.safetensors": shard,
      ])

      let dest = Self.tempDir()
      defer { try? FileManager.default.removeItem(at: dest) }

      let client = HuggingFaceClient(session: MockURLProtocol.session())
      try await client.downloadRepo(modelId: "org/flux2", into: dest)

      let configURL = dest.appendingPathComponent("config.json")
      let shardURL = dest.appendingPathComponent("transformer/model.safetensors")
      #expect(try Data(contentsOf: configURL) == config)
      #expect(try Data(contentsOf: shardURL) == shard)
      // No `.part` scratch file should survive a successful promote.
      #expect(!FileManager.default.fileExists(atPath: configURL.path + ".part"))
    }

    // MARK: - Subset selection

    @Test("downloadRepo honors an explicit files subset")
    func downloadsRequestedSubsetOnly() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      Self.installResponder(files: [
        "config.json": Data("{}".utf8),
        "weights.bin": Data(repeating: 0x01, count: 64),
      ])

      let dest = Self.tempDir()
      defer { try? FileManager.default.removeItem(at: dest) }

      let client = HuggingFaceClient(session: MockURLProtocol.session())
      try await client.downloadRepo(modelId: "org/repo", into: dest, files: ["config.json"])

      #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("config.json").path))
      #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("weights.bin").path))
    }

    // MARK: - Size-mismatch guard (silent-incomplete protection)

    @Test("downloadRepo throws sizeMismatch and leaves no file when bytes are short")
    func sizeMismatchThrows() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      // HF advertises 9999 bytes but the resolve endpoint serves only 10 —
      // the native equivalent of a Xet pointer-only download.
      Self.installResponder(
        files: ["model.bin": Data(repeating: 0x02, count: 10)],
        treeSizes: ["model.bin": 9999]
      )

      let dest = Self.tempDir()
      defer { try? FileManager.default.removeItem(at: dest) }

      let client = HuggingFaceClient(session: MockURLProtocol.session())

      var thrown: Error?
      do {
        try await client.downloadRepo(modelId: "org/repo", into: dest)
      } catch {
        thrown = error
      }

      guard case let .some(HFDownloadError.sizeMismatch(path, expected, actual)) = thrown else {
        Issue.record("expected HFDownloadError.sizeMismatch, got \(String(describing: thrown))")
        return
      }
      #expect(path == "model.bin")
      #expect(expected == 9999)
      #expect(actual == 10)
      // Neither the final file nor the .part scratch should survive.
      #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("model.bin").path))
      #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("model.bin.part").path))
    }

    // MARK: - recacheFromHuggingFace error wrapping

    @Test("recacheFromHuggingFace wraps a fetch failure in fetchSourceFailed before any CDN traffic")
    func recacheWrapsFetchFailure() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }
      // Route the internal HuggingFaceClient (built with no explicit session)
      // through the mock via the defaultSessionOverride test seam.
      HuggingFaceClient.defaultSessionOverride = MockURLProtocol.session()
      defer { HuggingFaceClient.defaultSessionOverride = nil }

      // The tree enumeration returns 500 → downloadRepo throws HFTreeError
      // before any byte fetch, and recacheFromHuggingFace must short-circuit
      // before building the S3 client (so no CDN request is ever issued).
      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (response, Data())
      }

      let creds = AcervoCDNCredentials(
        accessKeyId: "AKIAEXAMPLE",
        secretAccessKey: "EXAMPLEKEY",
        region: "auto",
        bucket: "test-bucket",
        endpoint: URL(string: "https://example.r2.cloudflarestorage.invalid")!,
        publicBaseURL: URL(string: "https://cdn.example.invalid")!
      )
      let dest = Self.tempDir()
      defer { try? FileManager.default.removeItem(at: dest) }

      var thrown: Error?
      do {
        _ = try await Acervo.recacheFromHuggingFace(
          modelId: "org/repo", stagingDirectory: dest, credentials: creds)
      } catch {
        thrown = error
      }

      guard case let .some(AcervoError.fetchSourceFailed(modelId, underlying)) = thrown else {
        Issue.record("expected AcervoError.fetchSourceFailed, got \(String(describing: thrown))")
        return
      }
      #expect(modelId == "org/repo")
      #expect(underlying is HFTreeError)
    }

    // MARK: - resolve URL shape

    @Test("buildResolveURL produces the canonical resolve endpoint")
    func buildResolveURLShape() async {
      let client = HuggingFaceClient()
      let url = await client.buildResolveURL(
        modelId: "org/repo",
        revision: "main",
        path: "transformer/model.safetensors"
      )
      #expect(
        url.absoluteString
          == "https://huggingface.co/org/repo/resolve/main/transformer/model.safetensors"
      )
    }
  }
}
