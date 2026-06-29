// ShipReshardTests.swift — `acervo ship` safetensors re-sharding wiring.
//
// Exercises the dry-run path end-to-end with a real over-cap safetensors in
// the staging dir, proving that:
//   - dry-run is NON-destructive: the staged files are left untouched and the
//     manifest reflects the current (pre-reshard) file set,
//   - --no-reshard disables the behavior, and
//   - --max-shard-mib / --no-reshard parse and the cap is range-validated.
//
// The destructive in-place re-shard itself (live ship) is covered at the
// library level in SafetensorsResharderTests.
//
// No live network. No R2 credentials required (dry-run path). Deterministic.

#if os(macOS)
  import ArgumentParser
  import Foundation
  import Testing

  @testable import SwiftAcervo
  @testable import acervo

  extension ProcessEnvironmentSuite {
    @Suite("ShipCommand Re-shard Tests", .serialized)
    final class ShipReshardTests {

      private let fm = FileManager.default

      // MARK: - Fixtures

      private func makeTempDir(_ tag: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
          .appendingPathComponent("acervo-shiprs-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
      }

      private func write(_ s: String, to url: URL) throws {
        try Data(s.utf8).write(to: url, options: [.atomic])
      }

      /// Writes a synthetic safetensors with the given (name, byteLength)
      /// tensors (dtype U8, shape [len]) and name-seeded bytes.
      private func writeSafetensors(at url: URL, tensors: [(String, Int)]) throws {
        var header: [String: Any] = [:]
        var cursor = 0
        var blob = Data()
        for (name, len) in tensors {
          header[name] = ["dtype": "U8", "shape": [len], "data_offsets": [cursor, cursor + len]]
          var seed = UInt8(name.utf8.reduce(0) { $0 &+ $1 })
          var bytes = Data(count: len)
          for i in 0..<len {
            bytes[i] = seed
            seed = seed &+ 7
          }
          blob.append(bytes)
          cursor += len
        }
        var headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        while (8 + headerData.count) % 8 != 0 { headerData.append(0x20) }
        var out = Data()
        var n = UInt64(headerData.count)
        for _ in 0..<8 {
          out.append(UInt8(n & 0xff))
          n >>= 8
        }
        out.append(headerData)
        out.append(blob)
        try out.write(to: url, options: [.atomic])
      }

      /// Builds `stagingRoot/<slug>` with config.json + an over-cap
      /// model.safetensors (~1.5 MiB across several tensors).
      @discardableResult
      private func makeOverCapStaging(in stagingRoot: URL, modelId: String) throws -> URL {
        let slug = modelId.replacingOccurrences(of: "/", with: "_")
        let staging = stagingRoot.appendingPathComponent(slug, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try write(#"{"model_type":"test"}"#, to: staging.appendingPathComponent("config.json"))
        try writeSafetensors(
          at: staging.appendingPathComponent("model.safetensors"),
          tensors: [("a.w", 600_000), ("b.w", 600_000), ("c.w", 400_000)]
        )
        return staging
      }

      private func decodeManifest(inDir dir: URL) throws -> CDNManifest {
        let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
          .filter { $0.pathExtension == "json" }
        let url = try #require(files.first)
        return try JSONDecoder().decode(CDNManifest.self, from: Data(contentsOf: url))
      }

      // MARK: - Tests

      @Test("ship --dry-run is non-destructive: staging is untouched, manifest is pre-reshard")
      func dryRunIsNonDestructive() async throws {
        let stagingRoot = try makeTempDir("reshard-staging")
        let outputDir = try makeTempDir("reshard-out")
        defer {
          try? fm.removeItem(at: stagingRoot)
          try? fm.removeItem(at: outputDir)
        }

        let hfRepo = "org/big-model"
        let staging = try makeOverCapStaging(in: stagingRoot, modelId: hfRepo)
        let weightURL = staging.appendingPathComponent("model.safetensors")
        let weightBefore = try Data(contentsOf: weightURL)

        let parsed = try await AcervoCLI.parseAsRoot([
          "ship", hfRepo,
          "--dry-run",
          "--max-shard-mib", "1",
          "--output-dir", outputDir.path,
          "--output", stagingRoot.path,
        ])
        guard var cmd = parsed as? ShipCommand else {
          Issue.record("Expected ShipCommand")
          return
        }
        try await cmd.run()

        // Staging is UNTOUCHED: original weight present and byte-identical,
        // no shards or index synthesized.
        #expect(fm.fileExists(atPath: weightURL.path))
        #expect(try Data(contentsOf: weightURL) == weightBefore)
        #expect(
          !fm.fileExists(
            atPath: staging.appendingPathComponent("model.safetensors.index.json").path)
        )

        // Manifest reflects the current (pre-reshard) file set.
        let manifest = try decodeManifest(inDir: outputDir)
        let paths = Set(manifest.files.map(\.path))
        #expect(paths.contains("model.safetensors"))
        #expect(!paths.contains("model.safetensors.index.json"))
        #expect(paths.contains("config.json"))
        #expect(manifest.verifyChecksum())
      }

      @Test("--no-reshard leaves the monolithic weight file intact")
      func noReshardDisables() async throws {
        let stagingRoot = try makeTempDir("noreshard-staging")
        let outputDir = try makeTempDir("noreshard-out")
        defer {
          try? fm.removeItem(at: stagingRoot)
          try? fm.removeItem(at: outputDir)
        }

        let hfRepo = "org/big-model"
        let staging = try makeOverCapStaging(in: stagingRoot, modelId: hfRepo)

        let parsed = try await AcervoCLI.parseAsRoot([
          "ship", hfRepo,
          "--dry-run",
          "--no-reshard",
          "--max-shard-mib", "1",
          "--output-dir", outputDir.path,
          "--output", stagingRoot.path,
        ])
        guard var cmd = parsed as? ShipCommand else {
          Issue.record("Expected ShipCommand")
          return
        }
        try await cmd.run()

        // Untouched: original present, no shards or index synthesized.
        #expect(fm.fileExists(atPath: staging.appendingPathComponent("model.safetensors").path))
        let manifest = try decodeManifest(inDir: outputDir)
        let paths = Set(manifest.files.map(\.path))
        #expect(paths.contains("model.safetensors"))
        #expect(!paths.contains("model.safetensors.index.json"))
      }

      @Test("--max-shard-mib and --no-reshard parse")
      func flagsParse() async throws {
        let parsed = try await AcervoCLI.parseAsRoot([
          "ship", "org/repo",
          "--max-shard-mib", "128",
          "--no-reshard",
          "--dry-run",
        ])
        let cmd = try #require(parsed as? ShipCommand)
        #expect(cmd.maxShardMiB == 128)
        #expect(cmd.noReshard == true)
      }

      @Test("--max-shard-mib must be positive")
      func rejectsNonPositiveCap() async throws {
        await #expect(throws: (any Error).self) {
          _ = try await AcervoCLI.parseAsRoot([
            "ship", "org/repo",
            "--max-shard-mib", "0",
            "--dry-run",
          ])
        }
      }
    }
  }
#endif
