// StoredModelReferenceSeeding.swift
// SwiftAcervoUI
//
// Declarative seeding helpers for the SwiftData-backed catalog. A host
// app describes the set of models it wants its picker to show and hands
// that set to one of these functions; the helpers reconcile the store
// against it. `ensureSeeded` is additive (insert what's missing, leave
// the rest alone); `ensureOnlySeeded` is authoritative (the store ends
// up containing exactly the supplied set and nothing else).
//
// The authoritative variant is what lets an app guarantee its picker
// shows only the models it supports — e.g. pruning a model that was
// once offered but is no longer available on the CDN.

import Foundation
import SwiftData

extension StoredModelReference {

  /// Inserts each reference whose `id` is not already present in
  /// `context`, leaving existing records untouched.
  ///
  /// Records are matched by `id` (the stable Acervo slug, which is also
  /// the store's unique key). A reference whose `id` already exists is
  /// skipped entirely — its persisted fields are *not* overwritten, so
  /// any host edits to display metadata survive re-seeding. Duplicate
  /// `id`s within `references` are collapsed to the first occurrence.
  ///
  /// This is the additive seed: it grows the catalog toward `references`
  /// but never removes anything. Use ``ensureOnlySeeded(_:in:)`` when the
  /// supplied set should be the complete catalog.
  ///
  /// The newly-inserted objects are the elements of `references` that
  /// were missing; any reference already in the store is left as its own
  /// distinct (un-inserted) value object.
  ///
  /// - Parameters:
  ///   - references: The desired records. Construct fresh
  ///     `StoredModelReference` values; only the missing ones are
  ///     inserted into `context`.
  ///   - context: The `ModelContext` to seed.
  /// - Returns: The `id`s that were inserted, in input order.
  /// - Throws: Any error thrown while fetching existing records or
  ///   saving the context.
  @discardableResult
  @MainActor
  public static func ensureSeeded(
    _ references: [StoredModelReference],
    in context: ModelContext
  ) throws -> [String] {
    let existing = try existingIDs(in: context)

    var seededThisCall: Set<String> = []
    var inserted: [String] = []
    for reference in references {
      let id = reference.id
      // Skip records already in the store and intra-call duplicates so a
      // repeated `id` never trips the unique constraint at save time.
      guard !existing.contains(id), !seededThisCall.contains(id) else {
        continue
      }
      context.insert(reference)
      seededThisCall.insert(id)
      inserted.append(id)
    }

    if !inserted.isEmpty {
      try context.save()
    }
    return inserted
  }

  /// Reconciles `context` so it contains *exactly* the supplied
  /// references: missing ones are inserted, and every stored record whose
  /// `id` is not among `references` is deleted.
  ///
  /// This is the authoritative seed. After it returns (and saves), the
  /// only `StoredModelReference` records in `context` are those whose
  /// `id` appears in `references`. Stale entries — including a model that
  /// was previously seeded but has since been dropped — are removed.
  ///
  /// As with ``ensureSeeded(_:in:)``, an `id` that already exists is kept
  /// as-is rather than replaced, so host edits to a still-supported
  /// model's metadata are preserved. Duplicate `id`s within `references`
  /// are collapsed to the first occurrence.
  ///
  /// - Parameters:
  ///   - references: The complete desired catalog. Anything not in this
  ///     set is purged from `context`.
  ///   - context: The `ModelContext` to reconcile.
  /// - Returns: A tuple of the `id`s inserted and the `id`s removed.
  /// - Throws: Any error thrown while fetching existing records or
  ///   saving the context.
  @discardableResult
  @MainActor
  public static func ensureOnlySeeded(
    _ references: [StoredModelReference],
    in context: ModelContext
  ) throws -> (inserted: [String], removed: [String]) {
    // Desired set of ids.
    let desired = Set(references.map(\.id))

    let stored = try context.fetch(FetchDescriptor<StoredModelReference>())
    var existing: Set<String> = []

    // Purge every stored record that is not wanted. Records carrying a
    // duplicate `id` (which the unique constraint should preclude, but we
    // tolerate defensively) are also collapsed: only the first sighting
    // of a wanted `id` is retained.
    var removed: [String] = []
    for record in stored {
      let id = record.id
      let isWanted = desired.contains(id) && !existing.contains(id)
      if isWanted {
        existing.insert(id)
      } else {
        context.delete(record)
        removed.append(id)
      }
    }

    // Insert the wanted records that were not already present.
    var seededThisCall: Set<String> = []
    var inserted: [String] = []
    for reference in references {
      let id = reference.id
      guard
        desired.contains(id),
        !existing.contains(id),
        !seededThisCall.contains(id)
      else { continue }
      context.insert(reference)
      seededThisCall.insert(id)
      inserted.append(id)
    }

    if !inserted.isEmpty || !removed.isEmpty {
      try context.save()
    }
    return (inserted, removed)
  }

  // MARK: - Helpers

  /// The `id` of every record currently in `context`.
  @MainActor
  private static func existingIDs(in context: ModelContext) throws -> Set<String> {
    let stored = try context.fetch(FetchDescriptor<StoredModelReference>())
    return Set(stored.map(\.id))
  }
}
