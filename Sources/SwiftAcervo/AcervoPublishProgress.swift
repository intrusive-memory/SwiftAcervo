// AcervoPublishProgress.swift
// SwiftAcervo
//
// Progress reporter for `Acervo.publishModel` (WU2 Sortie 2). The cases
// mirror the 11-step "publish" execution order frozen in
// `REQUIREMENTS-delete-and-recache.md` §7. A single value is emitted at
// each major stage so consumer-side UIs (CLI progress bars, app spinners)
// can render meaningful state without coupling to S3 internals.
//
// This file defines only the type. The producer (the publish orchestrator)
// lands in WU2 Sortie 2; downstream sorties depend on the type signature
// and need it to compile cleanly here.

import Foundation

/// Progress event emitted during `Acervo.publishModel`.
///
/// The cases form a partial order matching requirements §7's frozen
/// execution sequence:
///
///   1. `.generatingManifest`
///   2. `.verifyingManifest`         (covers manifest re-read + re-hash)
///   3. `.listingExistingKeys`
///   4. `.uploadingFile` × N         (one event per file; bytesSent is
///                                    cumulative within the file)
///   5. `.uploadingManifest`
///   6. `.verifyingPublic` × stages  (manifest fetch, sample-file fetch)
///   7. `.pruningOrphans`            (count is the number of orphans about
///                                    to be deleted; emitted once)
///   8. `.complete`
///
/// Consumers should treat unknown cases defensively — additional cases
/// may be appended in future minor versions.
public enum AcervoPublishProgress: Sendable {

  /// Step 1 — building `manifest.json` from the staging directory's
  /// contents. Emitted exactly once at the start of publish.
  case generatingManifest

  /// Steps 2–4 — manifest checksum-of-checksums verification and per-file
  /// re-hash against the manifest. Emitted exactly once between manifest
  /// generation and the first network call.
  case verifyingManifest

  /// Step 5 — `ListObjectsV2` against `models/<slug>/` finished. `found`
  /// is the count of keys already present at the prefix; this lets the
  /// caller estimate how many will eventually become orphans.
  case listingExistingKeys(found: Int)

  /// Step 6 — uploading one file from the manifest. Emitted multiple
  /// times per file when the underlying transport surfaces incremental
  /// progress, or exactly twice (start with `bytesSent: 0`, and end with
  /// `bytesSent == bytesTotal`) when it does not. `name` is the relative
  /// path within the model directory, not a full S3 key.
  case uploadingFile(name: String, bytesSent: Int64, bytesTotal: Int64)

  /// Step 7 — uploading `manifest.json` itself, after every payload file
  /// has uploaded successfully. Emitted exactly once.
  case uploadingManifest

  /// Steps 8–9 — public-URL readback verification. `stage` identifies
  /// which check is running, e.g. `"manifest"` (CHECK 5: re-fetch the
  /// just-uploaded `manifest.json` and verify its checksum-of-checksums)
  /// or `"sample-file"` (CHECK 6: re-fetch one file and verify SHA-256).
  case verifyingPublic(stage: String)

  /// Step 10–11 — about to bulk-delete orphan keys. `count` is the size
  /// of `existing_keys - new_manifest_keys - {manifest.json}`. Emitted
  /// exactly once. If `count == 0`, this case may still be emitted so
  /// consumers can show a "0 orphans pruned" line for transparency.
  case pruningOrphans(count: Int)

  /// Terminal event — the publish completed successfully. Emitted exactly
  /// once. After this, no further events are produced.
  case complete
}
