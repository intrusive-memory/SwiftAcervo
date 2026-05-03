// AcervoDeleteProgress.swift
// SwiftAcervo
//
// Progress reporter for `Acervo.deleteFromCDN` (WU2 Sortie 2). The cases
// mirror the 4-step "delete" execution order frozen in
// `REQUIREMENTS-delete-and-recache.md` §7 ("`deleteFromCDN` execution
// order"). Unlike `publishModel`, delete is non-atomic by design — there
// is nothing to be consistent with after a delete, so the loop simply
// lists, deletes, re-lists, and exits when the prefix is empty.
//
// This file defines only the type. The producer lands in WU2 Sortie 2.

import Foundation

/// Progress event emitted during `Acervo.deleteFromCDN`.
///
/// The cases form a simple loop:
///
///   1. `.listingPrefix`             (emitted once per pass; the loop
///                                    re-lists after each batch and may
///                                    therefore emit this multiple times)
///   2. `.deletingBatch` × N         (one event per S3 `DeleteObjects`
///                                    call; batches cap at 1000 keys)
///   3. `.complete`                  (terminal; the prefix listing
///                                    returned empty)
///
/// Consumers should treat unknown cases defensively — additional cases
/// may be appended in future minor versions.
public enum AcervoDeleteProgress: Sendable {

  /// `ListObjectsV2` against `models/<slug>/` is about to start (or has
  /// just started). Emitted at the top of every pass through the
  /// delete loop, including any re-list after a batch deletion.
  case listingPrefix

  /// A batch of keys has been submitted to `DeleteObjects`.
  ///
  /// `count` is the size of the batch just dispatched (1...1000).
  /// `deletedSoFar` is the cumulative count of keys deleted in the
  /// current `deleteFromCDN` invocation, including the batch this event
  /// represents. The caller can use this for a running progress total.
  case deletingBatch(count: Int, deletedSoFar: Int)

  /// Terminal event — the prefix listing returned empty, so no more
  /// keys remain to delete. Emitted exactly once. After this, no
  /// further events are produced.
  case complete
}
