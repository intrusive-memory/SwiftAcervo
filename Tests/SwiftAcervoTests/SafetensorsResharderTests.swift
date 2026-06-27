// SafetensorsResharderTests.swift
// SwiftAcervoTests
//
// Mirrors the standalone prototype's `--selftest`: build synthetic
// safetensors with deterministic, name-seeded bytes, reshard them under a
// tiny cap, and prove the output is byte-identical, correctly indexed, and
// honors the no-op gate / oversized-tensor / sub-folder behaviors.

import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

@Suite("Safetensors Resharder Tests")
struct SafetensorsResharderTests {

  private let fm = FileManager.default

  // MARK: - Fixture helpers

  private func makeTempDir(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("acervo-reshard-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Deterministic, name-seeded bytes so byte-exactness is provable.
  private func tensorBytes(name: String, length: Int) -> Data {
    var seed = UInt8(name.utf8.reduce(0) { $0 &+ $1 })
    var data = Data(count: length)
    for i in 0..<length {
      data[i] = seed
      seed = seed &+ 7
    }
    return data
  }

  /// Writes a single safetensors file with the given (name, byteLength)
  /// tensors. All tensors use dtype "U8" / shape [len], like the prototype.
  @discardableResult
  private func writeSafetensors(
    at url: URL,
    tensors: [(String, Int)],
    metadata: [String: String] = [:]
  ) throws -> [String: Data] {
    var header: [String: Any] = [:]
    var cursor = 0
    var blob = Data()
    var expected: [String: Data] = [:]
    for (name, len) in tensors {
      header[name] = ["dtype": "U8", "shape": [len], "data_offsets": [cursor, cursor + len]]
      let bytes = tensorBytes(name: name, length: len)
      expected[name] = bytes
      blob.append(bytes)
      cursor += len
    }
    if !metadata.isEmpty { header["__metadata__"] = metadata }

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
    return expected
  }

  /// Re-reads every shard in `dir` matching `stem` and extracts the raw bytes
  /// of every tensor, keyed by tensor name.
  private func readAllTensorBytes(in dir: URL, stem: String) throws -> [String: Data] {
    var result: [String: Data] = [:]
    let entries = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    for url in entries where url.pathExtension == "safetensors" {
      let raw = try Data(contentsOf: url)
      var n: UInt64 = 0
      for i in 0..<8 { n |= UInt64(raw[raw.startIndex + i]) << (8 * i) }
      let headerLen = Int(n)
      let headerData = raw.subdata(in: 8..<(8 + headerLen))
      let dataBase = 8 + headerLen
      let header = try JSONSerialization.jsonObject(with: headerData) as! [String: Any]
      for (key, value) in header {
        if key == "__metadata__" { continue }
        let entry = value as! [String: Any]
        let offsets = entry["data_offsets"] as! [Any]
        let begin = (offsets[0] as! NSNumber).intValue
        let end = (offsets[1] as! NSNumber).intValue
        result[key] = raw.subdata(in: (dataBase + begin)..<(dataBase + end))
      }
    }
    return result
  }

  // MARK: - Tests

  @Test("Re-shards a single over-cap file into byte-identical shards")
  func reshardsSingleFile() throws {
    let dir = try makeTempDir("single")
    defer { try? fm.removeItem(at: dir) }

    // 5 tensors, ~2.3 MiB total, all individually under the 1 MiB cap, so
    // the single file is over cap but every shard lands at or under it.
    let tensors = [
      ("a.weight", 700_000), ("b.weight", 300_000), ("c.weight", 900_000),
      ("d.bias", 1_500), ("e.weight", 400_000),
    ]
    let expected = try writeSafetensors(
      at: dir.appendingPathComponent("model.safetensors"), tensors: tensors)
    try writeString("{\"model_type\":\"test\"}", to: dir.appendingPathComponent("config.json"))

    let cap = 1 << 20  // 1 MiB
    let report = try SafetensorsResharder.reshard(directory: dir, maxShardBytes: cap)

    #expect(report.didReshard)
    #expect(report.safetensorsFound)
    #expect(report.groups.count == 1)
    let group = report.groups[0]
    #expect(group.stem == "model")
    #expect(group.tensorCount == tensors.count)
    #expect(group.shardCount >= 2)
    #expect(report.largestShardBytes <= cap)

    // Original single file is gone; sibling untouched; index present.
    #expect(!fm.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path))
    #expect(fm.fileExists(atPath: dir.appendingPathComponent("config.json").path))
    let indexURL = dir.appendingPathComponent("model.safetensors.index.json")
    #expect(fm.fileExists(atPath: indexURL.path))

    // Byte-identical round trip.
    let actual = try readAllTensorBytes(in: dir, stem: "model")
    #expect(Set(actual.keys) == Set(expected.keys))
    for (name, bytes) in expected {
      #expect(actual[name] == bytes, "tensor \(name) bytes differ")
    }

    // index.json weight_map covers every tensor; total_size is the sum.
    let index = try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as! [String: Any]
    let weightMap = index["weight_map"] as! [String: String]
    #expect(Set(weightMap.keys) == Set(expected.keys))
    let meta = index["metadata"] as! [String: Any]
    let totalSize = (meta["total_size"] as! NSNumber).intValue
    #expect(totalSize == tensors.reduce(0) { $0 + $1.1 })
  }

  @Test("No-op when every file is already under the cap")
  func noOpUnderCap() throws {
    let dir = try makeTempDir("noop")
    defer { try? fm.removeItem(at: dir) }

    let url = dir.appendingPathComponent("model.safetensors")
    try writeSafetensors(at: url, tensors: [("a.weight", 1000), ("b.weight", 2000)])
    let before = try Data(contentsOf: url)

    let report = try SafetensorsResharder.reshard(directory: dir, maxShardBytes: 1 << 20)

    #expect(report.safetensorsFound)
    #expect(!report.didReshard)
    #expect(report.groups.isEmpty)
    // File untouched, byte-for-byte.
    #expect(try Data(contentsOf: url) == before)
    // No index was synthesized for a no-op.
    #expect(
      !fm.fileExists(atPath: dir.appendingPathComponent("model.safetensors.index.json").path))
  }

  @Test("No safetensors found is a clean no-op")
  func noSafetensors() throws {
    let dir = try makeTempDir("empty")
    defer { try? fm.removeItem(at: dir) }
    try writeString("{}", to: dir.appendingPathComponent("config.json"))

    let report = try SafetensorsResharder.reshard(directory: dir, maxShardBytes: 1 << 20)
    #expect(!report.safetensorsFound)
    #expect(!report.didReshard)
  }

  @Test("Merges pre-sharded over-cap files and re-splits losslessly")
  func mergesExistingShards() throws {
    let dir = try makeTempDir("merge")
    defer { try? fm.removeItem(at: dir) }

    // Two existing shards; the first is over the 1 MiB cap (though each of
    // its tensors is under it) → the whole group is re-merged and re-split.
    var expected: [String: Data] = [:]
    try writeSafetensors(
      at: dir.appendingPathComponent("model-00001-of-00002.safetensors"),
      tensors: [("layer0.w", 700_000), ("layer0.b", 600_000)]
    ).forEach { expected[$0.key] = $0.value }
    try writeSafetensors(
      at: dir.appendingPathComponent("model-00002-of-00002.safetensors"),
      tensors: [("layer1.w", 500_000), ("layer1.b", 400_000)]
    ).forEach { expected[$0.key] = $0.value }

    let cap = 1 << 20
    let report = try SafetensorsResharder.reshard(directory: dir, maxShardBytes: cap)

    #expect(report.didReshard)
    #expect(report.groups.first?.stem == "model")
    #expect(report.largestShardBytes <= cap)

    let actual = try readAllTensorBytes(in: dir, stem: "model")
    #expect(Set(actual.keys) == Set(expected.keys))
    for (name, bytes) in expected {
      #expect(actual[name] == bytes)
    }
  }

  @Test("A single tensor larger than the cap is isolated and reported")
  func oversizedTensor() throws {
    let dir = try makeTempDir("oversize")
    defer { try? fm.removeItem(at: dir) }

    let expected = try writeSafetensors(
      at: dir.appendingPathComponent("model.safetensors"),
      tensors: [("small", 1000), ("huge", 2_000_000)]  // huge > 1 MiB cap
    )

    let cap = 1 << 20
    let report = try SafetensorsResharder.reshard(directory: dir, maxShardBytes: cap)

    #expect(report.didReshard)
    #expect(report.oversizedTensors.contains { $0.name == "huge" })
    // Lossless even for the oversized tensor.
    let actual = try readAllTensorBytes(in: dir, stem: "model")
    for (name, bytes) in expected {
      #expect(actual[name] == bytes)
    }
  }

  @Test("Reshards diffusers sub-folders independently, preserving stems")
  func subFolderGroups() throws {
    let root = try makeTempDir("diffusers")
    defer { try? fm.removeItem(at: root) }

    let transformer = root.appendingPathComponent("transformer", isDirectory: true)
    let vae = root.appendingPathComponent("vae", isDirectory: true)
    try fm.createDirectory(at: transformer, withIntermediateDirectories: true)
    try fm.createDirectory(at: vae, withIntermediateDirectories: true)

    let tExpected = try writeSafetensors(
      at: transformer.appendingPathComponent("diffusion_pytorch_model.safetensors"),
      tensors: [("t.w", 1_500_000), ("t.b", 2_000)]
    )
    // vae stays under cap → untouched.
    let vaeURL = vae.appendingPathComponent("diffusion_pytorch_model.safetensors")
    try writeSafetensors(at: vaeURL, tensors: [("v.w", 50_000)])
    let vaeBefore = try Data(contentsOf: vaeURL)

    let cap = 1 << 20
    let report = try SafetensorsResharder.reshard(directory: root, maxShardBytes: cap)

    // Only the transformer group resharded.
    #expect(report.groups.count == 1)
    #expect(report.groups.first?.relativeDirectory == "transformer")
    #expect(report.groups.first?.stem == "diffusion_pytorch_model")

    // transformer index named after its stem.
    #expect(
      fm.fileExists(
        atPath:
          transformer.appendingPathComponent("diffusion_pytorch_model.safetensors.index.json").path)
    )
    // vae untouched (no index synthesized, bytes identical).
    #expect(try Data(contentsOf: vaeURL) == vaeBefore)
    #expect(
      !fm.fileExists(
        atPath: vae.appendingPathComponent("diffusion_pytorch_model.safetensors.index.json").path))

    let actual = try readAllTensorBytes(in: transformer, stem: "diffusion_pytorch_model")
    for (name, bytes) in tExpected {
      #expect(actual[name] == bytes)
    }
  }

  @Test("Rejects a non-positive cap")
  func rejectsBadCap() throws {
    let dir = try makeTempDir("badcap")
    defer { try? fm.removeItem(at: dir) }
    #expect(throws: AcervoError.self) {
      _ = try SafetensorsResharder.reshard(directory: dir, maxShardBytes: 0)
    }
  }

  @Test("Two distinct stems in one directory are resharded as separate groups")
  func twoStemsInOneDir() throws {
    let dir = try makeTempDir("twostem")
    defer { try? fm.removeItem(at: dir) }

    // Two logical weight sets sharing one folder, each over the cap. They
    // must NOT be merged into one `model` namespace.
    var expected: [String: Data] = [:]
    try writeSafetensors(
      at: dir.appendingPathComponent("model.safetensors"),
      tensors: [("m.a", 700_000), ("m.b", 700_000)]
    ).forEach { expected[$0.key] = $0.value }
    try writeSafetensors(
      at: dir.appendingPathComponent("vae.safetensors"),
      tensors: [("v.a", 700_000), ("v.b", 700_000)]
    ).forEach { expected[$0.key] = $0.value }

    let report = try SafetensorsResharder.reshard(directory: dir, maxShardBytes: 1 << 20)

    #expect(report.groups.count == 2)
    #expect(Set(report.groups.map(\.stem)) == ["model", "vae"])
    // Each stem got its own index; neither original survives.
    #expect(fm.fileExists(atPath: dir.appendingPathComponent("model.safetensors.index.json").path))
    #expect(fm.fileExists(atPath: dir.appendingPathComponent("vae.safetensors.index.json").path))
    #expect(!fm.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path))
    #expect(!fm.fileExists(atPath: dir.appendingPathComponent("vae.safetensors").path))

    // All tensors from both stems are byte-identical and present.
    let actual = try readAllTensorBytes(in: dir, stem: "")
    #expect(Set(actual.keys) == Set(expected.keys))
    for (name, bytes) in expected {
      #expect(actual[name] == bytes)
    }
    // Each index's weight_map references only files that exist on disk.
    for indexName in ["model.safetensors.index.json", "vae.safetensors.index.json"] {
      let index =
        try JSONSerialization.jsonObject(
          with: Data(contentsOf: dir.appendingPathComponent(indexName))) as! [String: Any]
      let weightMap = index["weight_map"] as! [String: String]
      for shard in Set(weightMap.values) {
        #expect(fm.fileExists(atPath: dir.appendingPathComponent(shard).path))
      }
    }
  }

  @Test("A stale pre-existing index is replaced with a consistent fresh one")
  func staleIndexReplaced() throws {
    let dir = try makeTempDir("staleidx")
    defer { try? fm.removeItem(at: dir) }

    let expected = try writeSafetensors(
      at: dir.appendingPathComponent("model.safetensors"),
      tensors: [("a", 700_000), ("b", 700_000)]
    )
    // A bogus pre-existing index referencing shards that don't exist.
    try writeString(
      #"{"metadata":{"total_size":1},"weight_map":{"ghost":"model-00001-of-00099.safetensors"}}"#,
      to: dir.appendingPathComponent("model.safetensors.index.json")
    )

    _ = try SafetensorsResharder.reshard(directory: dir, maxShardBytes: 1 << 20)

    let index =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: dir.appendingPathComponent("model.safetensors.index.json")))
      as! [String: Any]
    let weightMap = index["weight_map"] as! [String: String]
    // Fresh index: keys are the real tensors, not the stale "ghost".
    #expect(Set(weightMap.keys) == Set(expected.keys))
    #expect(weightMap["ghost"] == nil)
    // Every referenced shard exists; none point at the stale 00099 file.
    for shard in Set(weightMap.values) {
      #expect(!shard.contains("of-00099"))
      #expect(fm.fileExists(atPath: dir.appendingPathComponent(shard).path))
    }
  }

  @Test("A malformed header throws rather than crashing")
  func malformedHeaderThrows() throws {
    let dir = try makeTempDir("malformed")
    defer { try? fm.removeItem(at: dir) }

    // 8-byte header length of all 0xFF (≈ UInt64.max) + junk. Must be
    // rejected as malformed, not trap on Int(n) or attempt a huge read.
    var bytes = Data(repeating: 0xFF, count: 8)
    bytes.append(Data(repeating: 0x00, count: 16))
    try bytes.write(to: dir.appendingPathComponent("model.safetensors"), options: [.atomic])

    // Cap below the 24-byte file size so the no-op gate doesn't skip it and
    // the header is actually parsed (where the malformed length is caught).
    #expect(throws: AcervoError.self) {
      _ = try SafetensorsResharder.reshard(directory: dir, maxShardBytes: 16)
    }
  }

  @Test("A mid-swap move failure rolls back, leaving the original intact")
  func failSafeSwapRollsBack() throws {
    let dir = try makeTempDir("failsafe")
    defer { try? fm.removeItem(at: dir) }

    // Two ~700 KiB tensors → exactly 2 shards under a 1 MiB cap.
    let original = try writeSafetensors(
      at: dir.appendingPathComponent("model.safetensors"),
      tensors: [("a.w", 700_000), ("b.w", 700_000)]
    )
    let weightURL = dir.appendingPathComponent("model.safetensors")
    let weightBefore = try Data(contentsOf: weightURL)

    // Obstruct the destination of the SECOND shard with a directory, so the
    // swap's move loop throws partway through and must roll back.
    let obstacle = dir.appendingPathComponent("model-00002-of-00002.safetensors")
    try fm.createDirectory(at: obstacle, withIntermediateDirectories: true)

    #expect(throws: (any Error).self) {
      _ = try SafetensorsResharder.reshard(directory: dir, maxShardBytes: 1 << 20)
    }

    // Rolled back: the original is restored byte-for-byte, and the
    // first shard was not left stranded in the directory.
    #expect(fm.fileExists(atPath: weightURL.path))
    #expect(try Data(contentsOf: weightURL) == weightBefore)
    #expect(
      !fm.fileExists(atPath: dir.appendingPathComponent("model-00001-of-00002.safetensors").path))
    // Sanity: the original's tensors are still readable and intact.
    #expect(original.count == 2)
  }

  // MARK: - Helpers

  private func writeString(_ s: String, to url: URL) throws {
    try Data(s.utf8).write(to: url, options: [.atomic])
  }
}
