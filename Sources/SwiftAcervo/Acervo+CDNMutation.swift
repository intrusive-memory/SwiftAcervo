// Acervo+CDNMutation.swift
// SwiftAcervo
//
// Layer 3 of the CDN-mutation surface (per requirements §6.4): orchestration
// APIs that compose `S3CDNClient` (Layer 2) and `SigV4Signer` (Layer 1) into
// the high-level operations consumers actually want — `publishModel`,
// `deleteFromCDN`, and `recache`.
//
// The publish pipeline is the workhorse. It is **atomic from the consumer's
// perspective**: the manifest swaps last, so partial failure leaves the
// prior version's complete file set live. Orphan prune runs only after the
// full readback verification (CHECKs 5 + 6) passes.
//
// 11-step execution order (frozen, see requirements §7):
//   1. Generate manifest from `directory` (via `ManifestGenerator`).
//   2. CHECK 2 — refuse zero-byte files (enforced inside `ManifestGenerator`).
//   3. CHECK 3 — re-read manifest, verify checksum-of-checksums (enforced
//      inside `ManifestGenerator`).
//   4. CHECK 4 — re-hash every staged file against the manifest.
//   5. List existing keys under `models/<slug>/`.
//   6. PUT every manifest file.
//   7. PUT `manifest.json` LAST.
//   8. CHECK 5 — fetch `manifest.json` from `credentials.publicBaseURL` and
//      verify checksum.
//   9. CHECK 6 — fetch one file (`config.json` if present, else first
//      manifest entry) and verify SHA-256.
//  10. Compute orphans = `existing_keys - new_manifest_keys - {manifest.json}`.
//  11. If `keepOrphans == false`, delete orphans via `deleteObjects` in
//      batches of 1000 (the actor itself batches at the 1000-key limit; we
//      call it once per logical orphan set).
//
// Failure semantics:
//   - Steps 1–4 fail → nothing on the CDN changed.
//   - Steps 5–7 fail → some new files may be on the CDN, but the old
//     `manifest.json` still points at the old (complete) file set.
//   - Steps 8–9 fail → `AcervoError.publishVerificationFailed(stage:)`.
//     The new manifest is live but its post-upload check did not match the
//     staged content; investigation required before retrying.
//   - Steps 10–11 fail → the new version is already serving traffic
//     correctly. Orphans are storage waste, not a correctness bug.
//     `AcervoError.publishOrphanPruneFailed(failedKeys:publishedManifest:)`
//     surfaces the unswept keys so the caller can retry the prune.

import CryptoKit
import Foundation

extension Acervo {

  // MARK: - publishModel

  /// Atomically publishes a locally-staged model directory to the CDN.
  ///
  /// Every file in `directory` is uploaded under `models/<slug>/`, with
  /// `manifest.json` swapped LAST so the CDN never serves an internally
  /// inconsistent view. Existing keys at the prefix that are no longer
  /// referenced by the new manifest are deleted as a final, non-fatal
  /// orphan-prune step (unless `keepOrphans` is `true`).
  ///
  /// - Parameters:
  ///   - modelId: `org/repo` identifier for the model. Used to compute
  ///     the CDN slug (`org_repo`) and embedded into `manifest.json`.
  ///   - directory: Local staging directory containing the model files.
  ///     Must already be populated; the library does not fetch from
  ///     HuggingFace (use `Acervo.recache(...)` for that pipeline).
  ///   - credentials: S3 credentials and addressing for the CDN bucket
  ///     plus the public base URL used by CHECK 5 / CHECK 6.
  ///   - keepOrphans: When `true`, the orphan-prune step (10–11) is
  ///     skipped. Default `false` (prune by default).
  ///   - progress: Optional callback invoked at each step boundary and
  ///     once per file during step 6.
  /// - Returns: The `CDNManifest` that was just published.
  /// - Throws: `AcervoError.publishVerificationFailed(stage:)` on CHECK
  ///   failures, `AcervoError.publishOrphanPruneFailed(...)` if step 11
  ///   leaves orphans on the CDN, and any underlying error from
  ///   `ManifestGenerator` / `S3CDNClient`.
  @discardableResult
  public static func publishModel(
    modelId: String,
    directory: URL,
    credentials: AcervoCDNCredentials,
    keepOrphans: Bool = false,
    progress: (@Sendable (AcervoPublishProgress) -> Void)? = nil
  ) async throws -> CDNManifest {
    let client = S3CDNClient(credentials: credentials)
    return try await _publishModel(
      modelId: modelId,
      directory: directory,
      credentials: credentials,
      client: client,
      publicSession: .shared,
      keepOrphans: keepOrphans,
      progress: progress
    )
  }

  // MARK: - publishModel (internal, test-injectable)

  /// Test-facing publish. Public callers go through `publishModel(...)` which
  /// builds the live `S3CDNClient` and uses `URLSession.shared` for public
  /// readback. Tests inject an `S3CDNClient` configured against
  /// `MockURLProtocol.session()` for the signed mutation path and a separate
  /// mocked `URLSession` for the unauthenticated CHECK 5 / CHECK 6 reads.
  ///
  /// `publicSession` is the `URLSession` used to fetch `manifest.json` and
  /// the spot-check file from `credentials.publicBaseURL`. The S3 client
  /// brings its own session (passed to its initializer).
  static func _publishModel(
    modelId: String,
    directory: URL,
    credentials: AcervoCDNCredentials,
    client: S3CDNClient,
    publicSession: URLSession,
    keepOrphans: Bool,
    progress: (@Sendable (AcervoPublishProgress) -> Void)?
  ) async throws -> CDNManifest {
    // ---------- Step 1 — Generate manifest -------------------------------
    progress?(.generatingManifest)
    let generator = ManifestGenerator(modelId: modelId)
    // Step 2 (CHECK 2 — zero-byte) and step 3 (CHECK 3 — post-write
    // checksum) are enforced inside ManifestGenerator.generate. A
    // failure there throws AcervoError.manifestZeroByteFile or
    // AcervoError.manifestPostWriteCorrupted; we surface those directly.
    let manifestURL = try await generator.generate(directory: directory)

    // Decode the just-written manifest. ManifestGenerator already validated
    // its checksum during CHECK 3; we use the file we wrote on disk so
    // step 7's PUT and the readback in step 8 see the same bytes.
    let manifestData = try Data(contentsOf: manifestURL)
    let manifest = try JSONDecoder().decode(CDNManifest.self, from: manifestData)

    // ---------- Step 4 — CHECK 4: re-hash every staged file --------------
    progress?(.verifyingManifest)
    try Self.recheckStagedFiles(directory: directory, manifest: manifest)

    let slug = manifest.slug
    let prefix = "models/\(slug)/"

    // ---------- Step 5 — List existing CDN keys --------------------------
    let existingObjects = try await client.listObjects(prefix: prefix)
    let existingKeys = Set(existingObjects.map(\.key))
    progress?(.listingExistingKeys(found: existingKeys.count))

    // ---------- Step 6 — PUT every manifest file -------------------------
    // We upload files in deterministic order (manifest already sorted).
    // The manifest itself is uploaded LAST in step 7.
    var uploadedFileKeys: Set<String> = []
    for entry in manifest.files {
      let fileURL = directory.appendingPathComponent(entry.path)
      let key = prefix + entry.path

      progress?(
        .uploadingFile(
          name: entry.path,
          bytesSent: 0,
          bytesTotal: entry.sizeBytes
        )
      )

      _ = try await client.putObject(key: key, bodyURL: fileURL)

      progress?(
        .uploadingFile(
          name: entry.path,
          bytesSent: entry.sizeBytes,
          bytesTotal: entry.sizeBytes
        )
      )

      uploadedFileKeys.insert(key)
    }

    // ---------- Step 7 — PUT manifest.json LAST --------------------------
    progress?(.uploadingManifest)
    let manifestKey = prefix + "manifest.json"
    _ = try await client.putObject(key: manifestKey, bodyURL: manifestURL)

    // ---------- Step 8 — CHECK 5: fetch manifest.json from public URL ---
    progress?(.verifyingPublic(stage: "manifest"))
    try await Self.verifyPublicManifest(
      session: publicSession,
      publicBaseURL: credentials.publicBaseURL,
      slug: slug,
      expectedManifest: manifest
    )

    // ---------- Step 9 — CHECK 6: fetch one file, verify SHA-256 --------
    progress?(.verifyingPublic(stage: "sample-file"))
    let sampleEntry =
      manifest.file(at: "config.json")
      ?? manifest.files.first
    if let sample = sampleEntry {
      try await Self.verifyPublicSampleFile(
        session: publicSession,
        publicBaseURL: credentials.publicBaseURL,
        slug: slug,
        entry: sample
      )
    }
    // If the manifest is empty (zero files), there is nothing to spot-check.
    // ManifestGenerator does not write an empty manifest in practice (CHECK
    // 2 short-circuits on zero-byte files; an empty directory would still
    // produce a manifest with zero entries). No spot-check is the correct
    // behavior in that degenerate case.

    // ---------- Step 10 — Compute orphan set -----------------------------
    // orphans = existing_keys − new_manifest_keys − {manifest.json}
    let liveKeys = uploadedFileKeys.union([manifestKey])
    let orphans = existingKeys.subtracting(liveKeys)

    // ---------- Step 11 — Delete orphans (unless keepOrphans) -----------
    if !keepOrphans, !orphans.isEmpty {
      progress?(.pruningOrphans(count: orphans.count))
      // S3CDNClient.deleteObjects already batches at the 1000-key limit
      // internally; we hand it the full list and let it issue 1+ batches.
      let results = try await client.deleteObjects(keys: Array(orphans))
      let failedKeys = results.filter { !$0.success }.map(\.key)
      if !failedKeys.isEmpty {
        // The new manifest is already live; orphans are storage waste,
        // not a correctness bug. Surface the unswept keys so the caller
        // can retry the prune.
        throw AcervoError.publishOrphanPruneFailed(
          failedKeys: failedKeys,
          publishedManifest: manifest
        )
      }
    } else if !keepOrphans {
      // Emit pruningOrphans(0) so observers see the step ran.
      progress?(.pruningOrphans(count: 0))
    }

    progress?(.complete)
    return manifest
  }

  // MARK: - CHECK 4 — re-hash staged files

  /// Re-hashes every file the manifest references and confirms each digest
  /// matches what the manifest captured. Catches mid-flight mutation of the
  /// staging directory between manifest generation (step 1) and the upload
  /// loop (step 6). Mismatch throws
  /// `AcervoError.publishVerificationFailed(stage: "rehash")`.
  private static func recheckStagedFiles(
    directory: URL,
    manifest: CDNManifest
  ) throws {
    for entry in manifest.files {
      let fileURL = directory.appendingPathComponent(entry.path)
      let actual: String
      do {
        actual = try IntegrityVerification.sha256(of: fileURL)
      } catch {
        throw AcervoError.publishVerificationFailed(stage: "rehash")
      }
      if actual != entry.sha256 {
        throw AcervoError.publishVerificationFailed(stage: "rehash")
      }
    }
  }

  // MARK: - CHECK 5 — public manifest fetch + verify

  /// Fetches `<publicBaseURL>/models/<slug>/manifest.json` over plain HTTPS,
  /// decodes it, runs `verifyChecksum()`, and confirms its
  /// `manifestChecksum` matches the local manifest's. Any mismatch (HTTP
  /// status, JSON decode, checksum) throws
  /// `AcervoError.publishVerificationFailed(stage: "CHECK 5")`.
  ///
  /// The fetch is cache-hardened via `URLRequest.cacheBypassing(...)`: a
  /// content-derived `?cb=` query parameter, `Cache-Control: no-cache`, and
  /// `.reloadIgnoringLocalCacheData` together push past `URLCache`, edge
  /// caches, and any intermediate proxy that might still be serving the
  /// previous deployment's manifest.
  private static func verifyPublicManifest(
    session: URLSession,
    publicBaseURL: URL,
    slug: String,
    expectedManifest: CDNManifest
  ) async throws {
    let url =
      publicBaseURL
      .appendingPathComponent("models", isDirectory: true)
      .appendingPathComponent(slug, isDirectory: true)
      .appendingPathComponent("manifest.json")
    let request = URLRequest.cacheBypassing(
      url: url,
      cacheBuster: expectedManifest.manifestChecksum
    )

    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw AcervoError.publishVerificationFailed(stage: "CHECK 5")
    }
    guard
      let http = response as? HTTPURLResponse,
      (200..<300).contains(http.statusCode)
    else {
      throw AcervoError.publishVerificationFailed(stage: "CHECK 5")
    }
    let decoded: CDNManifest
    do {
      decoded = try JSONDecoder().decode(CDNManifest.self, from: data)
    } catch {
      throw AcervoError.publishVerificationFailed(stage: "CHECK 5")
    }
    guard
      decoded.verifyChecksum(),
      decoded.manifestChecksum == expectedManifest.manifestChecksum
    else {
      throw AcervoError.publishVerificationFailed(stage: "CHECK 5")
    }
  }

  // MARK: - CHECK 6 — sample-file fetch + SHA-256 verify

  /// Downloads one file from the public CDN and confirms its SHA-256
  /// matches the manifest entry. The file picked is the first one that
  /// exists in the manifest as `config.json`, falling back to the first
  /// entry in lexicographic order. Uses the same cache-bypass strategy as
  /// CHECK 5, keyed on the entry's SHA-256 so a republish of the same path
  /// with new content produces a different request URL.
  private static func verifyPublicSampleFile(
    session: URLSession,
    publicBaseURL: URL,
    slug: String,
    entry: CDNManifestFile
  ) async throws {
    let url =
      publicBaseURL
      .appendingPathComponent("models", isDirectory: true)
      .appendingPathComponent(slug, isDirectory: true)
      .appendingPathComponent(entry.path)
    let request = URLRequest.cacheBypassing(
      url: url,
      cacheBuster: entry.sha256
    )

    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw AcervoError.publishVerificationFailed(stage: "CHECK 6")
    }
    guard
      let http = response as? HTTPURLResponse,
      (200..<300).contains(http.statusCode)
    else {
      throw AcervoError.publishVerificationFailed(stage: "CHECK 6")
    }
    let actual = SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
    guard actual == entry.sha256 else {
      throw AcervoError.publishVerificationFailed(stage: "CHECK 6")
    }
  }

  // MARK: - deleteFromCDN

  /// Removes every object under `models/<slug>/` from the CDN.
  ///
  /// Non-atomic by design (see requirements §7): there is nothing to be
  /// consistent with after a delete, so the implementation simply lists,
  /// bulk-deletes, re-lists, and exits when the prefix is empty. Any single
  /// batch failure throws and lets the caller retry.
  ///
  /// Idempotent: if the prefix is already empty on the first listing, the
  /// call returns without issuing any `DeleteObjects` requests.
  ///
  /// - Parameters:
  ///   - modelId: `org/repo` identifier for the model. Used to compute the
  ///     CDN slug (`org_repo`).
  ///   - credentials: S3 credentials and addressing for the CDN bucket.
  ///   - progress: Optional callback invoked at each pass through the
  ///     list/delete loop and once for the terminal `.complete` event.
  /// - Throws: `AcervoError.invalidModelId` if the model ID is malformed,
  ///   plus any underlying error from `S3CDNClient.listObjects` /
  ///   `S3CDNClient.deleteObjects`.
  public static func deleteFromCDN(
    modelId: String,
    credentials: AcervoCDNCredentials,
    progress: (@Sendable (AcervoDeleteProgress) -> Void)? = nil
  ) async throws {
    let client = S3CDNClient(credentials: credentials)
    try await _deleteFromCDN(
      modelId: modelId,
      client: client,
      progress: progress
    )
  }

  /// Test-facing delete. Public callers go through `deleteFromCDN(...)`
  /// which builds the live `S3CDNClient`. Tests inject an `S3CDNClient`
  /// configured against `MockURLProtocol.session()`.
  static func _deleteFromCDN(
    modelId: String,
    client: S3CDNClient,
    progress: (@Sendable (AcervoDeleteProgress) -> Void)?
  ) async throws {
    let slashCount = modelId.filter { $0 == "/" }.count
    guard slashCount == 1 else {
      throw AcervoError.invalidModelId(modelId)
    }

    let slug = slugify(modelId)
    let prefix = "models/\(slug)/"

    var deletedSoFar = 0
    while true {
      progress?(.listingPrefix)
      let objects = try await client.listObjects(prefix: prefix)
      if objects.isEmpty {
        progress?(.complete)
        return
      }
      let keys = objects.map(\.key)
      // S3CDNClient.deleteObjects already batches at the 1000-key limit
      // internally. We split here too so each emitted progress event
      // corresponds to exactly one DeleteObjects request, keeping the
      // event stream meaningful for callers that wire it to a UI.
      let batchSize = 1000
      var index = 0
      while index < keys.count {
        let end = Swift.min(index + batchSize, keys.count)
        let batch = Array(keys[index..<end])
        let results = try await client.deleteObjects(keys: batch)
        deletedSoFar += results.filter(\.success).count
        progress?(.deletingBatch(count: batch.count, deletedSoFar: deletedSoFar))
        index = end
      }
      // Loop and re-list. Some implementations are eventually-consistent
      // about list-after-delete; the loop terminates the moment the
      // listing comes back empty.
    }
  }

  // MARK: - recache

  /// Re-fetches a model from a caller-supplied source and republishes it to
  /// the CDN.
  ///
  /// This is a thin convenience over `publishModel`: the closure populates
  /// `stagingDirectory` with the files for `modelId`, and then the
  /// directory is handed to `publishModel` for the atomic publish + orphan
  /// prune. The library is agnostic to where bytes come from — the CLI's
  /// closure shells out to `hf`, but a future caller could substitute git,
  /// S3, a tarball download, etc.
  ///
  /// - Parameters:
  ///   - modelId: `org/repo` identifier for the model.
  ///   - stagingDirectory: Directory the closure should populate with
  ///     model files. Existing contents are not cleaned up; the caller is
  ///     responsible for handing in a clean directory if desired.
  ///   - credentials: S3 credentials and addressing for the CDN bucket
  ///     plus the public base URL used by CHECK 5 / CHECK 6.
  ///   - fetchSource: Caller-supplied async closure that downloads or
  ///     otherwise materializes the model into `stagingDirectory`.
  ///   - keepOrphans: When `true`, the orphan-prune step is skipped.
  ///     Default `false`.
  ///   - progress: Optional callback forwarded to `publishModel`.
  /// - Returns: The `CDNManifest` produced by `publishModel`.
  /// - Throws: `AcervoError.fetchSourceFailed(modelId:underlying:)` if the
  ///   fetch closure throws, plus any error `publishModel` can raise.
  @discardableResult
  public static func recache(
    modelId: String,
    stagingDirectory: URL,
    credentials: AcervoCDNCredentials,
    fetchSource: @Sendable (_ modelId: String, _ into: URL) async throws -> Void,
    keepOrphans: Bool = false,
    progress: (@Sendable (AcervoPublishProgress) -> Void)? = nil
  ) async throws -> CDNManifest {
    let client = S3CDNClient(credentials: credentials)
    return try await _recache(
      modelId: modelId,
      stagingDirectory: stagingDirectory,
      credentials: credentials,
      client: client,
      publicSession: .shared,
      fetchSource: fetchSource,
      keepOrphans: keepOrphans,
      progress: progress
    )
  }

  /// Test-facing recache. Public callers go through `recache(...)` which
  /// builds the live `S3CDNClient` and uses `URLSession.shared` for public
  /// readback. Tests inject mocked sessions/clients here.
  static func _recache(
    modelId: String,
    stagingDirectory: URL,
    credentials: AcervoCDNCredentials,
    client: S3CDNClient,
    publicSession: URLSession,
    fetchSource: @Sendable (_ modelId: String, _ into: URL) async throws -> Void,
    keepOrphans: Bool,
    progress: (@Sendable (AcervoPublishProgress) -> Void)?
  ) async throws -> CDNManifest {
    do {
      try await fetchSource(modelId, stagingDirectory)
    } catch {
      throw AcervoError.fetchSourceFailed(modelId: modelId, underlying: error)
    }
    return try await _publishModel(
      modelId: modelId,
      directory: stagingDirectory,
      credentials: credentials,
      client: client,
      publicSession: publicSession,
      keepOrphans: keepOrphans,
      progress: progress
    )
  }
}
