// StoredModelReferenceTests.swift
// SwiftAcervoUITests
//
// Tests for AcervoSchemaV1.StoredModelReference, the SwiftData record
// that backs AcervoModelsList. Uses an in-memory ModelContainer so
// nothing touches the host's real catalog.

import Foundation
import SwiftAcervo
import SwiftData
import Testing

@testable import SwiftAcervoUI

@MainActor
struct StoredModelReferenceTests {

  // MARK: - Init defaults

  @Test("init applies sensible defaults for optional fields")
  func initDefaults() {
    let record = StoredModelReference(
      id: "org/repo",
      displayName: "Display"
    )
    #expect(record.id == "org/repo")
    #expect(record.displayName == "Display")
    #expect(record.subtitleLines.isEmpty)
    #expect(record.groupID == nil)
    #expect(record.groupDisplayName == nil)
    #expect(record.origin == nil)
    // createdAt defaults to .now — just confirm it was populated.
    #expect(record.createdAt.timeIntervalSinceReferenceDate > 0)
  }

  @Test("init preserves every explicit argument")
  func initExplicit() {
    let timestamp = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let record = StoredModelReference(
      id: "org/repo",
      displayName: "Display",
      subtitleLines: ["a", "b"],
      groupID: "g",
      groupDisplayName: "Group",
      origin: "huggingface.co/org/repo",
      createdAt: timestamp
    )
    #expect(record.id == "org/repo")
    #expect(record.displayName == "Display")
    #expect(record.subtitleLines == ["a", "b"])
    #expect(record.groupID == "g")
    #expect(record.groupDisplayName == "Group")
    #expect(record.origin == "huggingface.co/org/repo")
    #expect(record.createdAt == timestamp)
  }

  // MARK: - rowItem projection

  @Test("rowItem projects every display-relevant field")
  func rowItemProjectsDisplayFields() {
    let record = StoredModelReference(
      id: "org/repo",
      displayName: "Display",
      subtitleLines: ["~4 GB", "Requires 8 GB RAM"],
      groupID: "flux",
      groupDisplayName: "FLUX models"
    )

    let item = record.rowItem
    #expect(item.id == "org/repo")
    #expect(item.displayName == "Display")
    #expect(item.subtitleLines == ["~4 GB", "Requires 8 GB RAM"])
    #expect(item.groupID == "flux")
    #expect(item.groupDisplayName == "FLUX models")
  }

  @Test("rowItem leaves group fields nil when the record has none")
  func rowItemPreservesNilGroups() {
    let record = StoredModelReference(
      id: "org/repo",
      displayName: "Display"
    )
    let item = record.rowItem
    #expect(item.groupID == nil)
    #expect(item.groupDisplayName == nil)
    #expect(item.subtitleLines.isEmpty)
  }

  // MARK: - SwiftData round-trip

  @Test("record round-trips through an in-memory ModelContainer")
  func swiftDataRoundTrip() throws {
    let container = try makeInMemoryContainer()
    let context = container.mainContext

    let record = StoredModelReference(
      id: "org/repo",
      displayName: "Display",
      subtitleLines: ["meta"]
    )
    context.insert(record)
    try context.save()

    let fetched = try context.fetch(FetchDescriptor<StoredModelReference>())
    #expect(fetched.count == 1)
    #expect(fetched.first?.id == "org/repo")
    #expect(fetched.first?.subtitleLines == ["meta"])
  }

  @Test("delete removes the record from the store")
  func swiftDataDelete() throws {
    let container = try makeInMemoryContainer()
    let context = container.mainContext

    let record = StoredModelReference(id: "org/repo", displayName: "Display")
    context.insert(record)
    try context.save()

    context.delete(record)
    try context.save()

    let fetched = try context.fetch(FetchDescriptor<StoredModelReference>())
    #expect(fetched.isEmpty)
  }

  @Test("mutating display fields persists across save/fetch cycles")
  func swiftDataMutationPersists() throws {
    let container = try makeInMemoryContainer()
    let context = container.mainContext

    let record = StoredModelReference(id: "org/repo", displayName: "Old")
    context.insert(record)
    try context.save()

    record.displayName = "New"
    record.subtitleLines = ["x"]
    record.groupID = "g"
    record.groupDisplayName = "Group"
    record.origin = "host"
    try context.save()

    let fetched = try context.fetch(FetchDescriptor<StoredModelReference>())
    let only = try #require(fetched.first)
    #expect(only.displayName == "New")
    #expect(only.subtitleLines == ["x"])
    #expect(only.groupID == "g")
    #expect(only.groupDisplayName == "Group")
    #expect(only.origin == "host")
  }

  @Test("sort by groupDisplayName then createdAt orders rows deterministically")
  func swiftDataSortOrder() throws {
    let container = try makeInMemoryContainer()
    let context = container.mainContext

    let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    let t1 = Date(timeIntervalSinceReferenceDate: 2_000)
    let t2 = Date(timeIntervalSinceReferenceDate: 3_000)

    context.insert(
      StoredModelReference(
        id: "b/1", displayName: "B1",
        groupID: "b", groupDisplayName: "B Group", createdAt: t1
      ))
    context.insert(
      StoredModelReference(
        id: "a/2", displayName: "A2",
        groupID: "a", groupDisplayName: "A Group", createdAt: t2
      ))
    context.insert(
      StoredModelReference(
        id: "a/1", displayName: "A1",
        groupID: "a", groupDisplayName: "A Group", createdAt: t0
      ))
    try context.save()

    let descriptor = FetchDescriptor<StoredModelReference>(
      sortBy: [
        SortDescriptor(\.groupDisplayName),
        SortDescriptor(\.createdAt),
      ]
    )
    let fetched = try context.fetch(descriptor)
    #expect(fetched.map(\.id) == ["a/1", "a/2", "b/1"])
  }

  // MARK: - Helpers

  private func makeInMemoryContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(
      for: StoredModelReference.self,
      migrationPlan: AcervoMigrationPlan.self,
      configurations: config
    )
  }
}
