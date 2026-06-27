// SafetensorsResharder.swift
// SwiftAcervo
//
// Losslessly re-packs the `.safetensors` weight files in a staged model
// directory into shards no larger than a configurable cap (default 256 MiB),
// so every published object stays comfortably under Cloudflare's common
// 512 MB max-cacheable-object limit and actually edge-caches.
//
// Re-sharding is a *byte* operation: tensors are regrouped and their
// `data_offsets` recomputed, but the raw bytes and the dtype/shape metadata
// are copied verbatim. int4 / fp16 / bf16 all pass through untouched — the
// resharder never interprets a dtype. This keeps Acervo's zero-dependency
// rule intact (Foundation + CryptoKit only) and guarantees the operation is
// lossless: a SHA-256 round-trip over every tensor's bytes verifies that the
// output is byte-identical to the input before the originals are removed.
//
// Granularity: sharding happens at TENSOR granularity. A single tensor
// larger than the cap cannot be split (that would corrupt loading), so it
// gets its own oversized shard and is surfaced in the report as a warning.
//
// Scope: the resharder walks the directory tree and reshards each
// `(directory, weight-stem)` group of `.safetensors` files independently,
// emitting one HuggingFace-standard `<stem>.safetensors.index.json` per
// group. Grouping by stem (not just directory) keeps distinct weight sets
// that share a folder — e.g. `model.safetensors` beside `vae.safetensors` —
// from being merged into one namespace. This handles both the flat
// single-weight layout (mlx-community, T5, PixArt DiT) and the diffusers
// sub-folder layout (FLUX.2-style repos with `transformer/`, `vae/`, … each
// holding their own weights). The shard file stem is preserved from the
// existing files (`model`, `diffusion_pytorch_model`, …) so framework
// loaders keep working.

import CryptoKit
import Foundation

/// Re-shards staged safetensors weights into CDN-edge-cacheable files.
///
/// `SafetensorsResharder` is a stateless utility. Call
/// ``reshard(directory:maxShardBytes:verify:)`` on a populated staging
/// directory *before* generating a manifest — re-sharding changes file
/// boundaries (and therefore SHA-256s), so the manifest must always be
/// produced from the post-reshard file set.
///
/// The operation is in-place: original `.safetensors` files and any stale
/// `*.safetensors.index.json` in a resharded group are removed and replaced
/// with the new shards, after the lossless round-trip verification passes.
/// Sibling files (`config.json`, `tokenizer.json`, …) are never touched.
public enum SafetensorsResharder {

  /// Default per-shard byte cap: 256 MiB. A safe margin under Cloudflare's
  /// common 512 MB (decimal) max-cacheable-object limit.
  public static let defaultMaxShardBytes = 256 * 1024 * 1024

  // MARK: - Reporting

  /// A tensor whose own byte length exceeds the shard cap and therefore had
  /// to be placed in an oversized shard of its own (it cannot be split
  /// without corrupting the weights).
  public struct OversizedTensor: Sendable, Equatable {
    /// The tensor's name (its key in the safetensors header).
    public let name: String
    /// The tensor's byte length.
    public let byteLength: Int
    /// The group-relative directory the tensor lives in (`""` for the
    /// top-level group), for disambiguation across sub-folder groups.
    public let relativeDirectory: String
  }

  /// Per-group outcome (one group == one directory's `.safetensors` set).
  public struct GroupReport: Sendable {
    /// Directory containing this group, relative to the resharded root
    /// (`""` for the top level, e.g. `"transformer"` for a sub-folder).
    public let relativeDirectory: String
    /// The weight-file stem the shards were written under (`model`,
    /// `diffusion_pytorch_model`, …).
    public let stem: String
    /// Number of `.safetensors` files that existed before resharding.
    public let inputFileCount: Int
    /// Total number of tensors repacked across the group.
    public let tensorCount: Int
    /// Number of shards written.
    public let shardCount: Int
    /// Size in bytes of the largest shard written.
    public let largestShardBytes: Int
    /// Tensors that exceeded the cap and got their own oversized shard.
    public let oversizedTensors: [OversizedTensor]
    /// Names of the original files removed during the in-place swap.
    public let removedFileNames: [String]
    /// Names of the shard files written (excludes the index).
    public let shardFileNames: [String]
  }

  /// Aggregate outcome of a ``reshard(directory:maxShardBytes:verify:)`` call.
  public struct Report: Sendable {
    /// The per-shard byte cap that was applied.
    public let maxShardBytes: Int
    /// `true` when at least one `.safetensors` file was found anywhere in
    /// the tree (whether or not it needed resharding).
    public let safetensorsFound: Bool
    /// One entry per group that was actually resharded. Groups already
    /// entirely under the cap are a no-op and do not appear here.
    public let groups: [GroupReport]

    /// `true` when any group was resharded (any file was rewritten).
    public var didReshard: Bool { !groups.isEmpty }
    /// Total number of shards written across all resharded groups.
    public var shardCount: Int { groups.reduce(0) { $0 + $1.shardCount } }
    /// Largest shard written across all resharded groups, in bytes.
    public var largestShardBytes: Int { groups.map(\.largestShardBytes).max() ?? 0 }
    /// Every tensor that exceeded the cap, across all groups.
    public var oversizedTensors: [OversizedTensor] { groups.flatMap(\.oversizedTensors) }
  }

  // MARK: - Public entry point

  /// Re-shards every `.safetensors` group under `directory` in place.
  ///
  /// For each directory in the tree that directly contains `.safetensors`
  /// files, the resharder merges all tensors in that directory and re-splits
  /// them into shards no larger than `maxShardBytes`. A group whose existing
  /// files are *all* already at or under the cap is left untouched.
  ///
  /// - Parameters:
  ///   - directory: The staging directory to reshard. Must exist.
  ///   - maxShardBytes: Per-shard byte cap. Defaults to
  ///     ``defaultMaxShardBytes`` (256 MiB). Must be positive.
  ///   - verify: When `true` (default), every tensor's bytes are SHA-256
  ///     round-trip-verified against the source before the originals are
  ///     removed. Disable only for trusted bulk operations where the extra
  ///     read pass is unwanted.
  /// - Returns: A ``Report`` describing what (if anything) was resharded.
  /// - Throws: ``AcervoError/reshardInvalidCap``,
  ///   ``AcervoError/reshardMalformedSafetensors(path:detail:)``,
  ///   ``AcervoError/reshardDuplicateTensor(name:)``,
  ///   ``AcervoError/reshardVerificationFailed(detail:)``, plus any
  ///   underlying `FileManager` / `FileHandle` error.
  @discardableResult
  public static func reshard(
    directory: URL,
    maxShardBytes: Int = defaultMaxShardBytes,
    verify: Bool = true
  ) throws -> Report {
    guard maxShardBytes > 0 else {
      throw AcervoError.reshardInvalidCap(maxShardBytes)
    }

    let root = directory.resolvingSymlinksInPath()
    let groups = try discoverGroups(root: root)
    let safetensorsFound = !groups.isEmpty

    var groupReports: [GroupReport] = []
    for group in groups {
      if let report = try reshardGroup(
        group,
        root: root,
        maxShardBytes: maxShardBytes,
        verify: verify
      ) {
        groupReports.append(report)
      }
    }

    return Report(
      maxShardBytes: maxShardBytes,
      safetensorsFound: safetensorsFound,
      groups: groupReports
    )
  }

  /// Returns the directory-relative paths of every `.safetensors` file under
  /// `directory` larger than `maxShardBytes`, **without modifying anything**.
  ///
  /// A non-destructive probe: it answers "which weights would a live ship
  /// re-split?" so callers (e.g. `acervo ship --dry-run`) can warn without
  /// rewriting the user's staged files. Returns an empty array when nothing
  /// exceeds the cap.
  public static func oversizedSafetensors(
    in directory: URL,
    maxShardBytes: Int = defaultMaxShardBytes
  ) throws -> [String] {
    guard maxShardBytes > 0 else {
      throw AcervoError.reshardInvalidCap(maxShardBytes)
    }
    let root = directory.resolvingSymlinksInPath()
    var result: [String] = []
    for group in try discoverGroups(root: root) {
      for file in group.files where try fileSize(of: file) > maxShardBytes {
        let relDir = relativeDirectory(of: file.deletingLastPathComponent(), under: root)
        let name = file.lastPathComponent
        result.append(relDir.isEmpty ? name : "\(relDir)/\(name)")
      }
    }
    return result.sorted()
  }

  // MARK: - Group discovery

  /// A `(directory, stem)` pair and the `.safetensors` files that share it.
  ///
  /// Grouping by stem as well as directory is what keeps distinct logical
  /// weight sets in the same folder (e.g. `model.safetensors` next to
  /// `vae.safetensors`) from being merged into one namespace: each stem is
  /// re-sharded independently under its own name and its own index.
  private struct Group {
    let directory: URL
    let stem: String
    let files: [URL]
  }

  /// Walks the tree and buckets every `.safetensors` file by its parent
  /// directory AND weight stem. Hidden directories (including our own
  /// transient work dirs) and package descendants are skipped, as are
  /// symbolic links.
  private static func discoverGroups(root: URL) throws -> [Group] {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
      throw CocoaError(.fileReadNoSuchFile)
    }

    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
    guard
      let enumerator = fm.enumerator(
        at: root,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else {
      return []
    }

    var buckets: [String: (dir: URL, stem: String, files: [URL])] = [:]
    for case let fileURL as URL in enumerator {
      guard fileURL.pathExtension == "safetensors" else { continue }
      let values = try fileURL.resourceValues(forKeys: Set(keys))
      guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }

      let parent = fileURL.deletingLastPathComponent().resolvingSymlinksInPath()
      let stem = Self.stem(forFileName: fileURL.lastPathComponent)
      // NUL separates the two key parts so a directory path that happens to
      // end in the stem text cannot collide with a different bucket.
      let key = parent.path + "\u{0}" + stem
      buckets[key, default: (parent, stem, [])].files.append(fileURL)
    }

    // Deterministic group ordering (by directory path, then stem).
    return
      buckets.values
      .map { Group(directory: $0.dir, stem: $0.stem, files: $0.files.sorted { $0.path < $1.path }) }
      .sorted { ($0.directory.path, $0.stem) < ($1.directory.path, $1.stem) }
  }

  /// Recovers a weight file's logical stem by stripping the `.safetensors`
  /// extension and any `-NNNNN-of-NNNNN` shard suffix (`model`,
  /// `diffusion_pytorch_model`, …). A name with neither yields itself; an
  /// empty result falls back to `"model"`.
  private static func stem(forFileName name: String) -> String {
    var s = name
    if s.hasSuffix(".safetensors") {
      s = String(s.dropLast(".safetensors".count))
    }
    if let range = s.range(of: "-[0-9]{5}-of-[0-9]{5}$", options: .regularExpression) {
      s = String(s[..<range.lowerBound])
    }
    return s.isEmpty ? "model" : s
  }

  // MARK: - Per-group resharding

  /// Reshards a single group in place. Returns `nil` when the group is
  /// already entirely under the cap (no-op).
  private static func reshardGroup(
    _ group: Group,
    root: URL,
    maxShardBytes: Int,
    verify: Bool
  ) throws -> GroupReport? {
    let fm = FileManager.default

    // No-op gate: if every existing file is already at/under the cap, the
    // group is already edge-cacheable — leave it exactly as it is.
    let existingSizes = try group.files.map { try fileSize(of: $0) }
    if existingSizes.allSatisfy({ $0 <= maxShardBytes }) {
      return nil
    }

    // Parse every input file and merge their tensors + metadata.
    var allTensors: [TensorRef] = []
    var mergedMetadata: [String: String] = [:]
    for fileURL in group.files {
      let parsed = try parseSafetensors(at: fileURL)
      allTensors.append(contentsOf: parsed.tensors)
      for (k, v) in parsed.metadata { mergedMetadata[k] = v }
    }

    var byName: [String: TensorRef] = [:]
    for t in allTensors {
      if byName[t.name] != nil {
        throw AcervoError.reshardDuplicateTensor(name: t.name)
      }
      byName[t.name] = t
    }

    let relativeDirectory = Self.relativeDirectory(of: group.directory, under: root)
    let stem = group.stem
    let totalBytes = allTensors.reduce(0) { $0 + $1.byteLength }

    let (plan, oversized) = planShards(allTensors, capBytes: maxShardBytes)

    // Write the new shards into a hidden work dir first so a mid-operation
    // failure never leaves the staging directory in a half-swapped state.
    let workDir = group.directory.appendingPathComponent(
      ".acervo-reshard-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: workDir) }

    var sourceHandles: [String: FileHandle] = [:]
    defer { sourceHandles.values.forEach { try? $0.close() } }

    var weightMap: [String: String] = [:]
    var shardNames: [String] = []
    var largestShardBytes = 0
    // Per-tensor SHA-256 of the SOURCE bytes, computed while we stream them
    // into the new shards — so verification only has to read the shards
    // back, not re-read the originals (one fewer full pass over the model).
    var sourceDigests: [String: SHA256.Digest] = [:]

    for (index, shard) in plan.enumerated() {
      let name = shardFileName(stem: stem, index: index + 1, total: plan.count)
      let outURL = workDir.appendingPathComponent(name)
      let digests = try writeShard(
        shard,
        metadata: mergedMetadata,
        to: outURL,
        sourceHandles: &sourceHandles
      )
      sourceDigests.merge(digests) { current, _ in current }
      let size = try fileSize(of: outURL)
      largestShardBytes = max(largestShardBytes, size)
      for t in shard { weightMap[t.name] = name }
      shardNames.append(name)
    }

    // HuggingFace-standard index (`weight_map` + `metadata.total_size`).
    let indexName = "\(stem).safetensors.index.json"
    let indexURL = workDir.appendingPathComponent(indexName)
    let index: [String: Any] = [
      "metadata": ["total_size": totalBytes],
      "weight_map": weightMap,
    ]
    let indexData = try JSONSerialization.data(
      withJSONObject: index, options: [.sortedKeys, .prettyPrinted])
    try indexData.write(to: indexURL, options: [.atomic])

    // Lossless round-trip: prove every tensor's bytes survived before we
    // touch the originals.
    if verify {
      try verifyRoundTrip(
        sourceDigests: sourceDigests,
        expected: byName,
        workDir: workDir,
        shardNames: shardNames
      )
    }

    // ── Fail-safe in-place swap ──────────────────────────────────────────
    // Move the originals (and any pre-existing index for THIS stem) into a
    // backup dir, then move the new shards into place. If any move fails we
    // roll back from the backup, so the group is always either fully old or
    // fully new — never a partial mix that would corrupt the staging tree.
    let backupDir = workDir.appendingPathComponent("original", isDirectory: true)
    try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

    var toBackup = group.files
    let staleIndex = group.directory.appendingPathComponent(indexName)
    if fm.fileExists(atPath: staleIndex.path) {
      toBackup.append(staleIndex)
    }

    // Step 1 — move originals out of the group dir into the backup.
    var backedUp: [(original: URL, backup: URL)] = []
    for url in toBackup {
      let dest = backupDir.appendingPathComponent(url.lastPathComponent)
      try fm.moveItem(at: url, to: dest)
      backedUp.append((url, dest))
    }

    // Step 2 — move the new shards + index into the group dir, restoring
    // from backup if any single move fails.
    var placed: [URL] = []
    do {
      for name in shardNames + [indexName] {
        let dest = group.directory.appendingPathComponent(name)
        try fm.moveItem(at: workDir.appendingPathComponent(name), to: dest)
        placed.append(dest)
      }
    } catch {
      for url in placed { try? fm.removeItem(at: url) }
      for (original, backup) in backedUp { try? fm.moveItem(at: backup, to: original) }
      throw error
    }
    // Success — the backup (inside workDir) is discarded by the defer.

    let removedNames = group.files.map(\.lastPathComponent)

    return GroupReport(
      relativeDirectory: relativeDirectory,
      stem: stem,
      inputFileCount: group.files.count,
      tensorCount: allTensors.count,
      shardCount: plan.count,
      largestShardBytes: largestShardBytes,
      oversizedTensors: oversized.map {
        OversizedTensor(
          name: $0.name, byteLength: $0.byteLength, relativeDirectory: relativeDirectory)
      },
      removedFileNames: removedNames.sorted(),
      shardFileNames: shardNames
    )
  }

  // MARK: - Safetensors header parsing

  /// One tensor's metadata plus a pointer back to where its bytes live.
  private struct TensorRef {
    let name: String
    let dtype: String
    let shape: [Int]
    let byteLength: Int
    let sourceFile: String
    let sourceAbsOffset: Int
  }

  private struct ParsedSafetensors {
    let tensors: [TensorRef]
    let metadata: [String: String]
  }

  /// Reads the 8-byte little-endian header length, then the JSON header, and
  /// returns each tensor's dtype/shape/offsets plus the `__metadata__` block.
  private static func parseSafetensors(at url: URL) throws -> ParsedSafetensors {
    let path = url.path
    guard let fh = FileHandle(forReadingAtPath: path) else {
      throw AcervoError.reshardMalformedSafetensors(path: path, detail: "cannot open file")
    }
    defer { try? fh.close() }

    let headerLen = try readHeaderLength(fh, path: path)
    guard let headerData = try fh.read(upToCount: headerLen), headerData.count == headerLen else {
      throw AcervoError.reshardMalformedSafetensors(path: path, detail: "truncated header")
    }
    let dataBase = 8 + headerLen

    guard let obj = try JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
      throw AcervoError.reshardMalformedSafetensors(
        path: path, detail: "header is not a JSON object")
    }

    var metadata: [String: String] = [:]
    var tensors: [TensorRef] = []
    for (key, value) in obj {
      if key == "__metadata__" {
        if let m = value as? [String: String] { metadata = m }
        continue
      }
      guard
        let entry = value as? [String: Any],
        let dtype = entry["dtype"] as? String,
        let shapeRaw = entry["shape"] as? [Any],
        let offsets = entry["data_offsets"] as? [Any],
        offsets.count == 2,
        let begin = (offsets[0] as? NSNumber)?.intValue,
        let end = (offsets[1] as? NSNumber)?.intValue,
        end >= begin
      else {
        throw AcervoError.reshardMalformedSafetensors(
          path: path, detail: "malformed tensor entry '\(key)'")
      }
      let shape = shapeRaw.compactMap { ($0 as? NSNumber)?.intValue }
      tensors.append(
        TensorRef(
          name: key,
          dtype: dtype,
          shape: shape,
          byteLength: end - begin,
          sourceFile: path,
          sourceAbsOffset: dataBase + begin
        )
      )
    }
    return ParsedSafetensors(tensors: tensors, metadata: metadata)
  }

  private static func readHeaderLength(_ fh: FileHandle, path: String) throws -> Int {
    let lenData = try fh.read(upToCount: 8) ?? Data()
    guard lenData.count == 8 else {
      throw AcervoError.reshardMalformedSafetensors(
        path: path, detail: "file too short for 8-byte header length")
    }
    var n: UInt64 = 0
    for i in 0..<8 { n |= UInt64(lenData[lenData.startIndex + i]) << (8 * i) }
    // Guard against a corrupt or hostile length: a real safetensors header is
    // kilobytes-scale, so anything beyond a generous 256 MiB ceiling is
    // rejected. This also keeps `Int(n)` from trapping on a value > Int.max
    // and avoids attempting an absurd `read(upToCount:)` allocation.
    let maxHeaderBytes: UInt64 = 256 * 1024 * 1024
    guard n <= maxHeaderBytes else {
      throw AcervoError.reshardMalformedSafetensors(
        path: path, detail: "implausible header length \(n) bytes")
    }
    return Int(n)
  }

  // MARK: - Shard planning

  /// First-fit grouping of tensors (sorted by name for determinism) into
  /// shards under `capBytes`. A tensor larger than the cap is isolated into
  /// its own oversized shard and reported.
  private static func planShards(
    _ tensors: [TensorRef],
    capBytes: Int
  ) -> (plan: [[TensorRef]], oversized: [TensorRef]) {
    let sorted = tensors.sorted { $0.name < $1.name }
    var shards: [[TensorRef]] = []
    var current: [TensorRef] = []
    var currentSize = 0
    var oversized: [TensorRef] = []

    for t in sorted {
      if !current.isEmpty && currentSize + t.byteLength > capBytes {
        shards.append(current)
        current = []
        currentSize = 0
      }
      if t.byteLength > capBytes {
        oversized.append(t)
      }
      current.append(t)
      currentSize += t.byteLength
    }
    if !current.isEmpty { shards.append(current) }
    return (shards, oversized)
  }

  private static func shardFileName(stem: String, index: Int, total: Int) -> String {
    String(format: "%@-%05d-of-%05d.safetensors", stem, index, total)
  }

  // MARK: - Shard writing

  /// Writes one shard: rebuilds the header with recomputed contiguous
  /// `data_offsets`, space-pads it to 8-byte alignment, then streams each
  /// tensor's raw bytes from its source file in 4 MiB chunks.
  ///
  /// `tensors` is expected in ascending-name order (which `planShards`
  /// produces); the header offsets and the copy order follow that order.
  /// Returns the SHA-256 digest of each tensor's source bytes, captured for
  /// free during the copy so verification need not re-read the originals.
  @discardableResult
  private static func writeShard(
    _ tensors: [TensorRef],
    metadata: [String: String],
    to outURL: URL,
    sourceHandles: inout [String: FileHandle]
  ) throws -> [String: SHA256.Digest] {
    let ordered = tensors

    var header: [String: Any] = [:]
    var cursor = 0
    for t in ordered {
      header[t.name] = [
        "dtype": t.dtype,
        "shape": t.shape,
        "data_offsets": [cursor, cursor + t.byteLength],
      ]
      cursor += t.byteLength
    }
    if !metadata.isEmpty { header["__metadata__"] = metadata }

    var headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
    // Pad with trailing spaces (valid JSON whitespace) so (8 + headerLen) is
    // 8-byte aligned, matching the reference safetensors writer.
    while (8 + headerData.count) % 8 != 0 { headerData.append(0x20) }

    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    guard let out = FileHandle(forWritingAtPath: outURL.path) else {
      throw AcervoError.reshardMalformedSafetensors(
        path: outURL.path, detail: "cannot create output shard")
    }
    defer { try? out.close() }

    var lenLE = Data(count: 8)
    var n = UInt64(headerData.count)
    for i in 0..<8 {
      lenLE[i] = UInt8(n & 0xff)
      n >>= 8
    }
    // Use the throwing `write(contentsOf:)` so an I/O failure (e.g. a full
    // volume mid-shard) surfaces as a catchable Swift error that unwinds
    // BEFORE the destructive swap, instead of the legacy non-throwing
    // `write(_:)` which raises an uncatchable Obj-C exception (SIGABRT).
    try out.write(contentsOf: lenLE)
    try out.write(contentsOf: headerData)

    var digests: [String: SHA256.Digest] = [:]
    for t in ordered {
      let src = try sourceHandle(for: t.sourceFile, cache: &sourceHandles)
      digests[t.name] = try copyRange(
        from: src, at: t.sourceAbsOffset, length: t.byteLength, to: out)
    }
    try out.close()
    return digests
  }

  private static func sourceHandle(
    for path: String,
    cache: inout [String: FileHandle]
  ) throws -> FileHandle {
    if let existing = cache[path] { return existing }
    guard let handle = FileHandle(forReadingAtPath: path) else {
      throw AcervoError.reshardMalformedSafetensors(
        path: path, detail: "cannot reopen source file")
    }
    cache[path] = handle
    return handle
  }

  // MARK: - Byte plumbing

  /// Streams `length` bytes from `src` at absolute `srcOffset` into `dst`,
  /// returning the SHA-256 digest of the bytes copied so the caller can
  /// verify the round trip without re-reading the source.
  @discardableResult
  private static func copyRange(
    from src: FileHandle,
    at srcOffset: Int,
    length: Int,
    to dst: FileHandle
  ) throws -> SHA256.Digest {
    try src.seek(toOffset: UInt64(srcOffset))
    var hasher = SHA256()
    var remaining = length
    while remaining > 0 {
      let want = min(IntegrityVerification.chunkSize, remaining)
      guard let chunk = try src.read(upToCount: want), !chunk.isEmpty else {
        throw AcervoError.reshardVerificationFailed(detail: "unexpected EOF copying tensor bytes")
      }
      try dst.write(contentsOf: chunk)
      hasher.update(data: chunk)
      remaining -= chunk.count
    }
    return hasher.finalize()
  }

  // MARK: - Verification

  /// Re-parses every output shard and confirms each tensor reads back
  /// byte-identical to its source (by comparing the shard's bytes against
  /// the source digest captured during the copy) and that no tensor was
  /// lost. Only the shards are read here — the source digests came for free
  /// during `writeShard`.
  private static func verifyRoundTrip(
    sourceDigests: [String: SHA256.Digest],
    expected: [String: TensorRef],
    workDir: URL,
    shardNames: [String]
  ) throws {
    var seen = Set<String>()
    for name in shardNames {
      let shardURL = workDir.appendingPathComponent(name)
      let parsed = try parseSafetensors(at: shardURL)
      guard let handle = FileHandle(forReadingAtPath: shardURL.path) else {
        throw AcervoError.reshardVerificationFailed(detail: "cannot open shard \(name) for verify")
      }
      defer { try? handle.close() }
      for t in parsed.tensors {
        guard let orig = expected[t.name] else {
          throw AcervoError.reshardVerificationFailed(
            detail: "tensor '\(t.name)' not present in source")
        }
        guard orig.byteLength == t.byteLength, orig.dtype == t.dtype, orig.shape == t.shape else {
          throw AcervoError.reshardVerificationFailed(
            detail: "metadata mismatch for tensor '\(t.name)'")
        }
        let shardDigest = try sha256OfRange(
          handle: handle, offset: t.sourceAbsOffset, length: t.byteLength)
        guard let sourceDigest = sourceDigests[t.name], shardDigest == sourceDigest else {
          throw AcervoError.reshardVerificationFailed(
            detail: "byte mismatch for tensor '\(t.name)'")
        }
        seen.insert(t.name)
      }
    }
    guard seen == Set(expected.keys) else {
      let missing = Set(expected.keys).subtracting(seen).sorted().prefix(5)
      throw AcervoError.reshardVerificationFailed(
        detail: "tensors missing from output: \(missing.joined(separator: ", "))…")
    }
  }

  /// SHA-256 of a byte range read from an already-open file handle, streamed
  /// in 4 MiB chunks. Reusing the handle avoids an open/close per tensor.
  private static func sha256OfRange(
    handle: FileHandle, offset: Int, length: Int
  ) throws -> SHA256.Digest {
    try handle.seek(toOffset: UInt64(offset))
    var hasher = SHA256()
    var remaining = length
    while remaining > 0 {
      let want = min(IntegrityVerification.chunkSize, remaining)
      guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else {
        throw AcervoError.reshardVerificationFailed(detail: "EOF verifying shard")
      }
      hasher.update(data: chunk)
      remaining -= chunk.count
    }
    return hasher.finalize()
  }

  // MARK: - Small helpers

  private static func fileSize(of url: URL) throws -> Int {
    Int(try IntegrityVerification.fileSize(at: url))
  }

  /// Path of `directory` relative to `root`, `""` when they are the same.
  private static func relativeDirectory(of directory: URL, under root: URL) -> String {
    let rootComponents = root.resolvingSymlinksInPath().pathComponents
    let dirComponents = directory.resolvingSymlinksInPath().pathComponents
    guard dirComponents.count >= rootComponents.count,
      Array(dirComponents.prefix(rootComponents.count)) == rootComponents
    else {
      return directory.lastPathComponent
    }
    return dirComponents.dropFirst(rootComponents.count).joined(separator: "/")
  }
}
