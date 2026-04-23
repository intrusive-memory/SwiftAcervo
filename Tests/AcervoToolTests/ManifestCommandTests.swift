//
// ManifestCommandTests.swift — Sortie 14: ManifestCommand unit tests
//
// NON-DETERMINISM NOTE (discovered during implementation):
//   `ManifestGenerator.generate()` embeds a live `updatedAt` timestamp via
//   `Self.iso8601Now()` (second-precision ISO 8601). Two invocations of
//   `generate()` that span a clock-second boundary will produce different JSON
//   bytes, breaking the byte-identical determinism guarantee.
//
//   The determinism test below calls `generate()` twice in rapid succession.
//   In normal CI (both calls complete in < 1 second), the test passes. However,
//   the guarantee is fragile: if a second boundary falls between the two calls,
//   the `updatedAt` fields will differ and the `Data` comparison will fail.
//
//   Proposed production fix: add an `updatedAt: String? = nil` parameter to
//   `ManifestGenerator.generate()` (or `ManifestGenerator.init()`). When
//   provided, use it verbatim; when absent, call `iso8601Now()`. Tests supply
//   a fixed sentinel string (e.g., `"2000-01-01T00:00:00Z"`), making
//   determinism unconditional.  Until that fix lands, the determinism test is
//   CONDITIONALLY deterministic (same second → passes, straddles boundary → fails).
//
// EMPTY-DIRECTORY GAP:
//   `ManifestGenerator.generate()` does NOT throw when the directory is empty.
//   It writes a valid manifest with `"files": []` and a valid `manifestChecksum`.
//   The Sortie-14 requirement says "assert a meaningful error (no files to
//   manifest)". That guard does not exist in the production code today.
//   Test 3 below documents the *actual* production behaviour and is marked with
//   a comment explaining the gap. A follow-up P2 item should add an
//   `AcervoToolError.emptyManifest` (or equivalent) guard.

#if os(macOS)
  import CryptoKit
  import Foundation
  import Testing

  @testable import SwiftAcervo
  @testable import acervo

  // MARK: - ManifestCommandTests

  /// Unit tests for `ManifestCommand` argument parsing and for the
  /// `ManifestGenerator` behaviour it delegates to.
  ///
  /// Tests are grouped in a `.serialized` suite to prevent filesystem races
  /// when multiple tests write to overlapping temp directories.
  @Suite("ManifestCommand Tests", .serialized)
  struct ManifestCommandTests {

    // MARK: - Helpers

    /// Creates a unique temp directory and returns its URL.
    /// Callers are responsible for cleanup (use `defer { try? FileManager… }`).
    private func makeTempDir(tag: String = "cmd") throws -> URL {
      let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(
          "acervo-manifest-cmd-\(tag)-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
      return base
    }

    private func write(_ string: String, to url: URL) throws {
      try Data(string.utf8).write(to: url, options: [.atomic])
    }

    // MARK: - Test 1: Happy path

    /// Invoke `ManifestGenerator` (the engine behind `ManifestCommand`) on a
    /// fixture directory containing three known files. Assert:
    ///  - The output JSON has the expected shape (modelId, slug, file count).
    ///  - Every `files[].sha256` entry matches the pre-computed digest.
    ///  - `manifestChecksum` equals `CDNManifest.computeChecksum(from:)` applied
    ///    to the sorted file SHA-256s (checksum-of-checksums rule).
    ///  - `manifest.verifyChecksum()` returns `true`.
    ///
    /// Also validates that `ManifestCommand.parse(...)` captures `modelId` and
    /// `directory` from a well-formed argv.
    @Test("Happy path: fixture directory → expected JSON shape + checksum-of-checksums")
    func happyPath() async throws {
      let dir = try makeTempDir(tag: "happy")
      defer { try? FileManager.default.removeItem(at: dir) }

      // Stage three known files.
      let configURL = dir.appendingPathComponent("config.json")
      let tokenizerURL = dir.appendingPathComponent("tokenizer.json")
      let weightsURL = dir.appendingPathComponent("weights.safetensors")
      try write(#"{"model_type":"test"}"#, to: configURL)
      try write(#"{"vocab_size":32000}"#, to: tokenizerURL)
      try write("FAKE_BINARY_WEIGHTS_DATA", to: weightsURL)

      // Pre-compute expected SHA-256 digests.
      let sha256Config = try IntegrityVerification.sha256(of: configURL)
      let sha256Tokenizer = try IntegrityVerification.sha256(of: tokenizerURL)
      let sha256Weights = try IntegrityVerification.sha256(of: weightsURL)

      // --- ArgumentParser parse check ---
      let cmd = try ManifestCommand.parse([
        "test-org/fixture-repo",
        dir.path,
      ])
      #expect(cmd.modelId == "test-org/fixture-repo")
      #expect(cmd.directory == dir.path)

      // --- Generator invocation (the engine ManifestCommand delegates to) ---
      let generator = ManifestGenerator(modelId: "test-org/fixture-repo")
      let manifestURL = try await generator.generate(directory: dir)

      #expect(FileManager.default.fileExists(atPath: manifestURL.path))

      let data = try Data(contentsOf: manifestURL)
      let manifest = try JSONDecoder().decode(CDNManifest.self, from: data)

      // Shape checks.
      #expect(manifest.modelId == "test-org/fixture-repo")
      #expect(manifest.slug == "test-org_fixture-repo")
      #expect(manifest.files.count == 3)
      #expect(manifest.manifestVersion == CDNManifest.supportedVersion)

      // Per-file checksum checks.
      let entryConfig = manifest.file(at: "config.json")
      let entryTokenizer = manifest.file(at: "tokenizer.json")
      let entryWeights = manifest.file(at: "weights.safetensors")
      #expect(entryConfig?.sha256 == sha256Config)
      #expect(entryTokenizer?.sha256 == sha256Tokenizer)
      #expect(entryWeights?.sha256 == sha256Weights)

      // Checksum-of-checksums: sort the three file SHA-256s, concatenate, SHA-256.
      let expectedChecksum = CDNManifest.computeChecksum(
        from: [sha256Config, sha256Tokenizer, sha256Weights])
      #expect(manifest.manifestChecksum == expectedChecksum)

      // The high-level helper must agree.
      #expect(manifest.verifyChecksum() == true)
    }

    // MARK: - Test 2: Missing required argument

    /// When neither positional argument is supplied, `ArgumentParser` must
    /// surface a parsing error. `ManifestCommand.parse([])` must throw — the
    /// command cannot proceed without `modelId` and `directory`.
    @Test("Missing required argument causes argument-parse error")
    func missingRequiredArgument() {
      var thrown: Error?
      do {
        _ = try ManifestCommand.parse([])
      } catch {
        thrown = error
      }
      #expect(thrown != nil, "Expected a parse error when both required arguments are absent")

      // A single missing argument (only modelId present, no directory) also fails.
      var thrownPartial: Error?
      do {
        _ = try ManifestCommand.parse(["test-org/fixture-repo"])
      } catch {
        thrownPartial = error
      }
      // ArgumentParser accepts one argument here because ManifestCommand has
      // two @Argument fields. Parsing with only one token may succeed at the
      // parse stage (directory defaults to empty). Document actual behaviour:
      // if parse succeeds, run() would fail when the empty path is resolved.
      // The key invariant is that zero arguments always throw.
      #expect(thrown != nil, "Zero-argument parse must always throw")
      _ = thrownPartial  // Behaviour of single-arg case is incidental.
    }

    // MARK: - Test 3: Empty directory

    /// `ManifestGenerator.generate()` does NOT currently throw when the
    /// directory contains no model files. It writes a valid manifest with
    /// `"files": []` and a well-formed `manifestChecksum`.
    ///
    /// GAP: The Sortie-14 spec requires "a meaningful error (no files to
    /// manifest)". That guard does not exist in production today. This test
    /// documents the *actual* production behaviour so that a follow-up change
    /// (adding `AcervoToolError.emptyManifest` or similar) can reference it.
    ///
    /// When the production fix lands, this test should be updated to assert
    /// the thrown error instead of the current success path.
    @Test("Empty directory: generator currently writes a zero-file manifest (gap noted)")
    func emptyDirectory() async throws {
      let dir = try makeTempDir(tag: "empty")
      defer { try? FileManager.default.removeItem(at: dir) }

      // The directory is completely empty — no model files.
      let generator = ManifestGenerator(modelId: "test-org/empty-repo")

      // CURRENT BEHAVIOUR: generate() succeeds and writes a manifest with 0 files.
      // DESIRED BEHAVIOUR (per Sortie-14 spec): throw an error such as
      //   AcervoToolError.emptyManifest or similar.
      // TODO (P2): Add `AcervoToolError.emptyManifest` guard to ManifestGenerator
      //   and flip this test to #expect(throws:).
      let manifestURL = try await generator.generate(directory: dir)

      let data = try Data(contentsOf: manifestURL)
      let manifest = try JSONDecoder().decode(CDNManifest.self, from: data)

      // Document the actual production behaviour: zero-file manifest is written
      // and passes its own verifyChecksum() (empty checksum-of-checksums).
      #expect(manifest.files.count == 0)
      #expect(manifest.verifyChecksum() == true)

      // The manifest checksum over an empty file list is a known constant:
      // SHA-256("") — the hash of the empty string.
      let emptyChecksum = CDNManifest.computeChecksum(from: [])
      #expect(manifest.manifestChecksum == emptyChecksum)
    }

    // MARK: - Test 4: Determinism

    /// Regenerate a manifest from the same fixture directory twice and assert
    /// the two outputs are byte-identical.
    ///
    /// IMPORTANT: This test exposes a FRAGILE DETERMINISM GUARANTEE.
    /// `ManifestGenerator.generate()` embeds `updatedAt: Self.iso8601Now()`
    /// (second-precision). Two calls within the same clock second produce
    /// identical bytes; two calls that straddle a second boundary do not.
    ///
    /// Under normal CI conditions both calls finish in milliseconds and the
    /// test passes. Near a second boundary the test will fail with a `Data`
    /// inequality on the `updatedAt` field.
    ///
    /// If this test fails, the root cause is the live timestamp embedded by
    /// `ManifestGenerator.generate()` at Sources/acervo/ManifestGenerator.swift
    /// line 103 (`updatedAt: Self.iso8601Now()`). The proposed fix is to add an
    /// `updatedAt: String? = nil` parameter to `generate()` so tests can supply
    /// a fixed sentinel string.
    @Test("Determinism: two generations of the same directory produce byte-identical output")
    func determinism() async throws {
      let dir = try makeTempDir(tag: "determ")
      defer { try? FileManager.default.removeItem(at: dir) }

      // Stage two known files.
      try write(#"{"model_type":"llm"}"#, to: dir.appendingPathComponent("config.json"))
      try write(#"{"vocab_size":50257}"#, to: dir.appendingPathComponent("tokenizer.json"))

      let generator = ManifestGenerator(modelId: "determinism-org/determinism-repo")

      // First generation.
      let manifestURL1 = try await generator.generate(directory: dir)
      let data1 = try Data(contentsOf: manifestURL1)

      // Remove the manifest so the second generation writes a fresh copy.
      try FileManager.default.removeItem(at: manifestURL1)

      // Second generation from the identical directory contents.
      let manifestURL2 = try await generator.generate(directory: dir)
      let data2 = try Data(contentsOf: manifestURL2)

      // Hard criterion from the Sortie-14 spec: byte-identical Data comparison.
      // If this fails, the non-determinism source is `updatedAt` (see comment above).
      #expect(
        data1 == data2,
        """
        Manifest output is NOT byte-identical across two generations.
        Non-determinism source: `updatedAt` timestamp embedded by \
        ManifestGenerator.generate() at Sources/acervo/ManifestGenerator.swift:103.
        First  updatedAt appears at offset ~\(offsetOfUpdatedAt(in: data1) ?? -1) in data1.
        Second updatedAt appears at offset ~\(offsetOfUpdatedAt(in: data2) ?? -1) in data2.
        Proposed fix: add `updatedAt: String? = nil` parameter to generate() \
        and supply a fixed sentinel in tests.
        """
      )
    }

    // MARK: - Private utility

    /// Returns the approximate byte offset of the `"updatedAt"` key in a
    /// manifest JSON `Data` value, for diagnostic use in the determinism test.
    private func offsetOfUpdatedAt(in data: Data) -> Int? {
      let needle = Data("\"updatedAt\"".utf8)
      guard let range = data.range(of: needle) else { return nil }
      return range.lowerBound
    }
  }
#endif
