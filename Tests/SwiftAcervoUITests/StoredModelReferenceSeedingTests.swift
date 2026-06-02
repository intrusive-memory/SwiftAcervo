// StoredModelReferenceSeedingTests.swift
// SwiftAcervoUITests
//
// Tests for StoredModelReference.ensureSeeded / ensureOnlySeeded — the
// declarative catalog reconciliation helpers. Each test uses a fresh
// in-memory ModelContainer so nothing touches the host's real catalog.

import Foundation
import SwiftAcervo
import SwiftData
import Testing

@testable import SwiftAcervoUI

@MainActor
struct StoredModelReferenceSeedingTests {

  /// One in-memory container per test instance (swift-testing makes a
  /// fresh instance per `@Test`). Held as a stored property so it stays
  /// alive for the whole test body — a container dropped mid-test while
  /// its `mainContext` is still in use traps inside SwiftData.
  let container: ModelContainer

  init() throws {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    container = try ModelContainer(
      for: StoredModelReference.self,
      migrationPlan: AcervoMigrationPlan.self,
      configurations: config
    )
  }

  // MARK: - ensureSeeded

  @Test("ensureSeeded inserts every reference into an empty store")
  func ensureSeededInsertsAll() throws {
    let context = try makeContext()

    let inserted = try StoredModelReference.ensureSeeded(
      [ref("a/1"), ref("b/2")],
      in: context
    )

    #expect(Set(inserted) == ["a/1", "b/2"])
    #expect(try storedIDs(context) == ["a/1", "b/2"])
  }

  @Test("ensureSeeded skips references whose id already exists")
  func ensureSeededSkipsExisting() throws {
    let context = try makeContext()
    context.insert(ref("a/1", displayName: "Original"))
    try context.save()

    let inserted = try StoredModelReference.ensureSeeded(
      [ref("a/1", displayName: "Replacement"), ref("b/2")],
      in: context
    )

    #expect(inserted == ["b/2"])
    #expect(try storedIDs(context) == ["a/1", "b/2"])
    // Existing record's fields are preserved, not overwritten.
    let a = try #require(try fetch(context).first { $0.id == "a/1" })
    #expect(a.displayName == "Original")
  }

  @Test("ensureSeeded collapses duplicate ids within the input")
  func ensureSeededCollapsesDuplicates() throws {
    let context = try makeContext()

    let inserted = try StoredModelReference.ensureSeeded(
      [ref("a/1"), ref("a/1"), ref("b/2")],
      in: context
    )

    #expect(inserted == ["a/1", "b/2"])
    #expect(try storedIDs(context) == ["a/1", "b/2"])
  }

  @Test("ensureSeeded is idempotent across repeated calls")
  func ensureSeededIdempotent() throws {
    let context = try makeContext()
    let refs = [ref("a/1"), ref("b/2")]

    try StoredModelReference.ensureSeeded(refs, in: context)
    let second = try StoredModelReference.ensureSeeded(
      [ref("a/1"), ref("b/2")],
      in: context
    )

    #expect(second.isEmpty)
    #expect(try storedIDs(context) == ["a/1", "b/2"])
  }

  // MARK: - ensureOnlySeeded

  @Test("ensureOnlySeeded prunes records not in the desired set")
  func ensureOnlySeededPrunes() throws {
    let context = try makeContext()
    context.insert(ref("klein/4b"))
    context.insert(ref("klein/9b"))  // no longer supported
    context.insert(ref("pixart/xl"))
    try context.save()

    let result = try StoredModelReference.ensureOnlySeeded(
      [ref("klein/4b"), ref("pixart/xl")],
      in: context
    )

    #expect(result.inserted.isEmpty)
    #expect(result.removed == ["klein/9b"])
    #expect(try storedIDs(context) == ["klein/4b", "pixart/xl"])
  }

  @Test("ensureOnlySeeded inserts missing and removes extra in one pass")
  func ensureOnlySeededInsertsAndRemoves() throws {
    let context = try makeContext()
    context.insert(ref("old/1"))
    try context.save()

    let result = try StoredModelReference.ensureOnlySeeded(
      [ref("new/1"), ref("new/2")],
      in: context
    )

    #expect(Set(result.inserted) == ["new/1", "new/2"])
    #expect(result.removed == ["old/1"])
    #expect(try storedIDs(context) == ["new/1", "new/2"])
  }

  @Test("ensureOnlySeeded preserves fields of still-wanted records")
  func ensureOnlySeededPreservesExisting() throws {
    let context = try makeContext()
    context.insert(ref("keep/1", displayName: "Edited By Host"))
    try context.save()

    let result = try StoredModelReference.ensureOnlySeeded(
      [ref("keep/1", displayName: "Seed Default")],
      in: context
    )

    #expect(result.inserted.isEmpty)
    #expect(result.removed.isEmpty)
    let kept = try #require(try fetch(context).first)
    #expect(kept.displayName == "Edited By Host")
  }

  @Test("ensureOnlySeeded on an empty desired set clears the store")
  func ensureOnlySeededEmptyClears() throws {
    let context = try makeContext()
    context.insert(ref("a/1"))
    context.insert(ref("b/2"))
    try context.save()

    let result = try StoredModelReference.ensureOnlySeeded([], in: context)

    #expect(Set(result.removed) == ["a/1", "b/2"])
    #expect(try fetch(context).isEmpty)
  }

  @Test("ensureOnlySeeded collapses duplicate ids within the input")
  func ensureOnlySeededCollapsesDuplicates() throws {
    let context = try makeContext()

    let result = try StoredModelReference.ensureOnlySeeded(
      [ref("a/1"), ref("a/1")],
      in: context
    )

    #expect(result.inserted == ["a/1"])
    #expect(try storedIDs(context) == ["a/1"])
  }

  @Test("ensureOnlySeeded is idempotent across repeated calls")
  func ensureOnlySeededIdempotent() throws {
    let context = try makeContext()
    try StoredModelReference.ensureOnlySeeded(
      [ref("a/1"), ref("b/2")],
      in: context
    )

    let second = try StoredModelReference.ensureOnlySeeded(
      [ref("a/1"), ref("b/2")],
      in: context
    )

    #expect(second.inserted.isEmpty)
    #expect(second.removed.isEmpty)
    #expect(try storedIDs(context) == ["a/1", "b/2"])
  }

  // MARK: - Helpers

  private func ref(
    _ id: String,
    displayName: String? = nil
  ) -> StoredModelReference {
    StoredModelReference(id: id, displayName: displayName ?? id)
  }

  private func fetch(_ context: ModelContext) throws -> [StoredModelReference] {
    try context.fetch(FetchDescriptor<StoredModelReference>())
  }

  /// Stored ids, sorted, for order-independent comparison.
  private func storedIDs(_ context: ModelContext) throws -> [String] {
    try fetch(context).map(\.id).sorted()
  }

  private func makeContext() throws -> ModelContext {
    container.mainContext
  }
}
