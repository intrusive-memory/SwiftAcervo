// VerifiedMarkerTests.swift
// SwiftAcervo
//
// Sortie A2 of OPERATION INTEGRITY CHECKPOINT (C3 · R2 · R3).
//
// Covers, per the A2 exit criteria:
//
//   1. A marker whose `manifestChecksum` matches the local manifest
//      causes `availability(_:verifyHashes:)` to SKIP re-hashing — proven
//      via an injected oracle seam that records whether the full-hash
//      evaluation path was entered (NOT by timing).
//   2. A mismatched marker forces a re-audit — the same seam shows the
//      full-hash path WAS entered.
//   3. `verifyIntegrity(_:)` on a model with a hash-mismatched file
//      returns `.partial`, and writes NO marker.
//   4. `verifyIntegrity(_:)` on a clean model returns `.available` and
//      writes `.acervo-verified.json` stamped with the local
//      `manifestChecksum`.
//   5. `VerifiedMarker` read/write round-trips.
//
// All fixtures are tempdir-backed — no network, no live disk dependency.

import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

// MARK: - Shared helpers

private func makeTempBase(_ tag: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("A2-\(tag)-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func cleanup(_ url: URL) {
  try? FileManager.default.removeItem(at: url)
}

private func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func writeFile(_ data: Data, to url: URL) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try data.write(to: url)
}

private func manifestFile(path: String, body: Data) -> CDNManifestFile {
  CDNManifestFile(path: path, sha256: sha256Hex(body), sizeBytes: Int64(body.count))
}

private func makeManifest(modelId: String, files: [CDNManifestFile]) -> CDNManifest {
  CDNManifest(
    manifestVersion: CDNManifest.supportedVersion,
    modelId: modelId,
    slug: Acervo.slugify(modelId),
    updatedAt: "2026-06-28T00:00:00Z",
    files: files,
    manifestChecksum: CDNManifest.computeChecksum(from: files.map(\.sha256))
  )
}

/// Materializes a `<modelDir>/manifest.json` via the canonical persist
/// path so the oracle loads it through the production decoder.
private func writeLocalManifest(_ manifest: CDNManifest, baseDirectory: URL) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
  let data = try encoder.encode(manifest)
  try AcervoDownloader.persistManifestBytes(
    data, slug: manifest.slug, in: baseDirectory)
}

/// Records whether — and with which `verifyHashes` flag — the injected
/// oracle evaluation seam was invoked. The actor makes it safe to mutate
/// from the `@Sendable` seam closure without timing or data races.
private actor HashInvocationSpy {
  private(set) var totalCalls = 0
  private(set) var fullHashCalls = 0
  func record(verifyHashes: Bool) {
    totalCalls += 1
    if verifyHashes { fullHashCalls += 1 }
  }
}

// MARK: - Marker model round-trip

@Suite("A2: VerifiedMarker model")
struct VerifiedMarkerModelTests {

  @Test("write then read round-trips manifestChecksum")
  func roundTrips() throws {
    let base = try makeTempBase("Marker-RT")
    defer { cleanup(base) }
    let modelDir = base.appendingPathComponent("org_repo")

    let marker = VerifiedMarker(manifestChecksum: "abc123")
    try marker.write(in: modelDir)

    let onDisk = modelDir.appendingPathComponent(VerifiedMarker.filename)
    #expect(FileManager.default.fileExists(atPath: onDisk.path))

    let decoded = VerifiedMarker.read(in: modelDir)
    #expect(decoded?.manifestChecksum == "abc123")
  }

  @Test("read returns nil when marker absent")
  func absentIsNil() throws {
    let base = try makeTempBase("Marker-Absent")
    defer { cleanup(base) }
    #expect(VerifiedMarker.read(in: base.appendingPathComponent("nope")) == nil)
  }
}

// MARK: - Availability fast-path (spy seam)

@Suite("A2: Availability verified-marker fast-path")
struct VerifiedMarkerFastPathTests {

  /// EXIT CRITERION: a matching-checksum marker makes availability skip
  /// re-hashing. The injected seam returns a `.partial` sentinel; if the
  /// marker fast-path short-circuits as designed, the seam is never
  /// consulted and availability returns `.available`.
  @Test("matching marker → availability skips the full-hash path")
  func matchingMarker_skipsRehash() async throws {
    let modelId = "test-org/marker-match"
    let base = try makeTempBase("Match")
    defer { cleanup(base) }
    let modelDir = base.appendingPathComponent(Acervo.slugify(modelId))

    let body = Data("config".utf8)
    let manifest = makeManifest(
      modelId: modelId, files: [manifestFile(path: "config.json", body: body)])
    try writeLocalManifest(manifest, baseDirectory: base)
    // Marker stamped with the SAME checksum as the local manifest.
    try VerifiedMarker(manifestChecksum: manifest.manifestChecksum).write(in: modelDir)
    // Deliberately do NOT write config.json on disk: if the fast-path
    // fails to fire, the oracle would NOT return .available, exposing it.

    let spy = HashInvocationSpy()
    let result = await Acervo.$availabilityEvaluatorOverride.withValue(
      { _, _, verifyHashes in
        await spy.record(verifyHashes: verifyHashes)
        return .partial(missing: ["sentinel-should-not-appear"])
      }
    ) {
      await Acervo.availability(modelId, verifyHashes: true, in: base)
    }

    #expect(result == .available, "marker fast-path must short-circuit to .available")
    #expect(await spy.totalCalls == 0, "oracle seam must not be invoked at all")
    #expect(await spy.fullHashCalls == 0, "full-hash path must not be entered")
  }

  /// EXIT CRITERION: a mismatched-checksum marker forces a re-audit. The
  /// seam is invoked with `verifyHashes == true`.
  @Test("mismatched marker → availability re-enters the full-hash path")
  func mismatchedMarker_forcesReaudit() async throws {
    let modelId = "test-org/marker-mismatch"
    let base = try makeTempBase("Mismatch")
    defer { cleanup(base) }
    let modelDir = base.appendingPathComponent(Acervo.slugify(modelId))

    let body = Data("config".utf8)
    let manifest = makeManifest(
      modelId: modelId, files: [manifestFile(path: "config.json", body: body)])
    try writeLocalManifest(manifest, baseDirectory: base)
    // Marker stamped with a STALE / wrong checksum.
    try VerifiedMarker(manifestChecksum: "stale-checksum-does-not-match")
      .write(in: modelDir)

    let spy = HashInvocationSpy()
    let result = await Acervo.$availabilityEvaluatorOverride.withValue(
      { _, _, verifyHashes in
        await spy.record(verifyHashes: verifyHashes)
        return .partial(missing: ["forced-reaudit"])
      }
    ) {
      await Acervo.availability(modelId, verifyHashes: true, in: base)
    }

    #expect(await spy.totalCalls == 1, "oracle seam must be invoked exactly once")
    #expect(await spy.fullHashCalls == 1, "full-hash path must be entered on mismatch")
    #expect(result == .partial(missing: ["forced-reaudit"]))
  }

  /// No marker at all → re-audit (same as a mismatch).
  @Test("no marker → availability enters the full-hash path")
  func noMarker_forcesReaudit() async throws {
    let modelId = "test-org/marker-absent"
    let base = try makeTempBase("NoMarker")
    defer { cleanup(base) }

    let body = Data("config".utf8)
    let manifest = makeManifest(
      modelId: modelId, files: [manifestFile(path: "config.json", body: body)])
    try writeLocalManifest(manifest, baseDirectory: base)

    let spy = HashInvocationSpy()
    _ = await Acervo.$availabilityEvaluatorOverride.withValue(
      { _, _, verifyHashes in
        await spy.record(verifyHashes: verifyHashes)
        return .available
      }
    ) {
      await Acervo.availability(modelId, verifyHashes: true, in: base)
    }

    #expect(await spy.fullHashCalls == 1)
  }
}

// MARK: - verifyIntegrity

@Suite("A2: Acervo.verifyIntegrity")
struct VerifyIntegrityTests {

  /// EXIT CRITERION: a hash-mismatched file surfaces as `.partial`, and
  /// no marker is written.
  @Test("hash-mismatched file → .partial, no marker written")
  func corruptedFile_isPartial() async throws {
    let modelId = "test-org/verify-corrupt"
    let base = try makeTempBase("Corrupt")
    defer { cleanup(base) }
    let modelDir = base.appendingPathComponent(Acervo.slugify(modelId))

    // Manifest declares the GOOD bytes; disk holds same-size BAD bytes so
    // presence/size passes but the SHA-256 audit fails.
    let goodBody = Data(repeating: 0xAA, count: 256)
    let badBody = Data(repeating: 0xBB, count: 256)
    let manifest = makeManifest(
      modelId: modelId, files: [manifestFile(path: "weights.bin", body: goodBody)])
    try writeLocalManifest(manifest, baseDirectory: base)
    try writeFile(badBody, to: modelDir.appendingPathComponent("weights.bin"))

    let result = await Acervo.verifyIntegrity(modelId, in: base)

    #expect(result == .partial(missing: ["weights.bin"]))
    #expect(
      VerifiedMarker.read(in: modelDir) == nil,
      "a failing audit must not write a verified marker")
  }

  /// EXIT CRITERION: a clean model returns `.available` and writes
  /// `.acervo-verified.json` stamped with the local `manifestChecksum`.
  @Test("clean model → .available, writes marker with local checksum")
  func cleanModel_writesMarker() async throws {
    let modelId = "test-org/verify-clean"
    let base = try makeTempBase("Clean")
    defer { cleanup(base) }
    let modelDir = base.appendingPathComponent(Acervo.slugify(modelId))

    let body = Data(repeating: 0x42, count: 256)
    let manifest = makeManifest(
      modelId: modelId, files: [manifestFile(path: "weights.bin", body: body)])
    try writeLocalManifest(manifest, baseDirectory: base)
    try writeFile(body, to: modelDir.appendingPathComponent("weights.bin"))

    let result = await Acervo.verifyIntegrity(modelId, in: base)
    #expect(result == .available)

    let marker = VerifiedMarker.read(in: modelDir)
    #expect(
      marker?.manifestChecksum == manifest.manifestChecksum,
      "marker must be stamped with the local manifest checksum")

    // And the freshly-written marker now drives the availability
    // fast-path (no oracle invocation on a subsequent verify-hashes call).
    let spy = HashInvocationSpy()
    let followup = await Acervo.$availabilityEvaluatorOverride.withValue(
      { _, _, verifyHashes in
        await spy.record(verifyHashes: verifyHashes)
        return .partial(missing: ["should-not-run"])
      }
    ) {
      await Acervo.availability(modelId, verifyHashes: true, in: base)
    }
    #expect(followup == .available)
    #expect(await spy.totalCalls == 0)
  }
}
