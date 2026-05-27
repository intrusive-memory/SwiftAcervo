// AcervoModelsListTests.swift
// SwiftAcervoUITests
//
// Tests for AcervoModelsList's pure logic (grouping, editability) plus
// a deterministic NSHostingController render on macOS. The list relies
// on SwiftData @Query and a ModelContext environment; the render tests
// wire up an in-memory container so nothing touches the host's catalog.

import Foundation
import SwiftUI
import SwiftData
import Testing
@testable import SwiftAcervoUI
import SwiftAcervo

#if canImport(AppKit)
import AppKit
#endif

@MainActor
struct AcervoModelsListTests {

  // MARK: - Fixtures

  private static let availability: @Sendable (AcervoModelRowItem) async -> ModelAvailability = { _ in .notAvailable }
  private static let download: @Sendable (AcervoModelRowItem, @escaping @Sendable (Double) -> Void) async throws -> Void = { _, _ in }
  private static let deleteModel: @Sendable (AcervoModelRowItem) async throws -> Void = { _ in }

  // MARK: - resolveEditable

  @Test("resolveEditable: .editable always returns true")
  func resolveEditableEditable() {
    #expect(AcervoModelsList.resolveEditable(editability: .editable, allConfigurationsAllowSave: true) == true)
    #expect(AcervoModelsList.resolveEditable(editability: .editable, allConfigurationsAllowSave: false) == true)
  }

  @Test("resolveEditable: .readOnly always returns false")
  func resolveEditableReadOnly() {
    #expect(AcervoModelsList.resolveEditable(editability: .readOnly, allConfigurationsAllowSave: true) == false)
    #expect(AcervoModelsList.resolveEditable(editability: .readOnly, allConfigurationsAllowSave: false) == false)
  }

  @Test("resolveEditable: .automatic mirrors the container's writability flag")
  func resolveEditableAutomatic() {
    #expect(AcervoModelsList.resolveEditable(editability: .automatic, allConfigurationsAllowSave: true) == true)
    #expect(AcervoModelsList.resolveEditable(editability: .automatic, allConfigurationsAllowSave: false) == false)
  }

  // MARK: - groupModels

  @Test("groupModels: empty input produces no groups")
  func groupModelsEmpty() {
    #expect(AcervoModelsList.groupModels([]).isEmpty)
  }

  @Test("groupModels: ungrouped records share the __ungrouped__ bucket with nil displayName")
  func groupModelsUngrouped() {
    let a = StoredModelReference(id: "a", displayName: "A")
    let b = StoredModelReference(id: "b", displayName: "B")
    let groups = AcervoModelsList.groupModels([a, b])
    #expect(groups.count == 1)
    let only = try? #require(groups.first)
    #expect(only?.key == "__ungrouped__")
    #expect(only?.displayName == nil)
    #expect(only?.models.map(\.id) == ["a", "b"])
  }

  @Test("groupModels: records sharing a groupID bucket under one group")
  func groupModelsGrouped() {
    let a = StoredModelReference(
      id: "a", displayName: "A",
      groupID: "flux", groupDisplayName: "FLUX"
    )
    let b = StoredModelReference(
      id: "b", displayName: "B",
      groupID: "flux", groupDisplayName: "FLUX"
    )
    let groups = AcervoModelsList.groupModels([a, b])
    #expect(groups.count == 1)
    #expect(groups.first?.key == "flux")
    #expect(groups.first?.displayName == "FLUX")
    #expect(groups.first?.models.count == 2)
  }

  @Test("groupModels: first-seen iteration order is preserved")
  func groupModelsPreservesOrder() {
    let a = StoredModelReference(
      id: "a", displayName: "A",
      groupID: "second", groupDisplayName: "Second"
    )
    let b = StoredModelReference(
      id: "b", displayName: "B",
      groupID: "first", groupDisplayName: "First"
    )
    let c = StoredModelReference(
      id: "c", displayName: "C",
      groupID: "second", groupDisplayName: "Second"
    )
    let groups = AcervoModelsList.groupModels([a, b, c])
    #expect(groups.map(\.key) == ["second", "first"])
    #expect(groups[0].models.map(\.id) == ["a", "c"])
    #expect(groups[1].models.map(\.id) == ["b"])
  }

  @Test("groupModels: first-encountered groupDisplayName wins on conflict")
  func groupModelsFirstLabelWins() {
    let a = StoredModelReference(
      id: "a", displayName: "A",
      groupID: "g", groupDisplayName: "First Label"
    )
    let b = StoredModelReference(
      id: "b", displayName: "B",
      groupID: "g", groupDisplayName: "Second Label"
    )
    let groups = AcervoModelsList.groupModels([a, b])
    #expect(groups.count == 1)
    #expect(groups.first?.displayName == "First Label")
  }

  @Test("groupModels: mix of grouped and ungrouped records")
  func groupModelsMixed() {
    let a = StoredModelReference(id: "a", displayName: "A")
    let b = StoredModelReference(
      id: "b", displayName: "B",
      groupID: "flux", groupDisplayName: "FLUX"
    )
    let c = StoredModelReference(id: "c", displayName: "C")
    let groups = AcervoModelsList.groupModels([a, b, c])
    #expect(groups.count == 2)
    #expect(groups[0].key == "__ungrouped__")
    #expect(groups[0].models.map(\.id) == ["a", "c"])
    #expect(groups[1].key == "flux")
    #expect(groups[1].models.map(\.id) == ["b"])
  }

  // MARK: - Editability enum

  @Test("Editability is Sendable and exposes all three cases")
  func editabilityCases() {
    let cases: [AcervoModelsList.Editability] = [.automatic, .editable, .readOnly]
    #expect(cases.count == 3)
  }

  // MARK: - Body rendering (macOS host)

  #if canImport(AppKit)
  @Test("list body renders without crashing against an empty in-memory store")
  func renderEmptyStore() throws {
    let container = try makeInMemoryContainer()
    let view = AcervoModelsList(
      availability: Self.availability,
      download: Self.download,
      deleteModel: Self.deleteModel
    )
    .modelContainer(container)

    let host = NSHostingController(rootView: view)
    host.view.frame = CGRect(x: 0, y: 0, width: 600, height: 600)
    host.view.layoutSubtreeIfNeeded()
    #expect(host.view.bounds.width > 0)
  }

  @Test("list body renders against a populated in-memory store")
  func renderPopulatedStore() throws {
    let container = try makeInMemoryContainer()
    let context = container.mainContext
    context.insert(StoredModelReference(
      id: "a", displayName: "A",
      groupID: "g", groupDisplayName: "G"
    ))
    context.insert(StoredModelReference(id: "b", displayName: "B"))
    try context.save()

    let view = AcervoModelsList(
      editability: .editable,
      availability: Self.availability,
      download: Self.download,
      deleteModel: Self.deleteModel
    )
    .modelContainer(container)

    let host = NSHostingController(rootView: view)
    host.view.frame = CGRect(x: 0, y: 0, width: 600, height: 600)
    host.view.layoutSubtreeIfNeeded()
    #expect(host.view.bounds.width > 0)
  }

  @Test("list body renders in read-only mode")
  func renderReadOnlyMode() throws {
    let container = try makeInMemoryContainer()
    let view = AcervoModelsList(
      editability: .readOnly,
      availability: Self.availability,
      download: Self.download,
      deleteModel: Self.deleteModel
    )
    .modelContainer(container)

    let host = NSHostingController(rootView: view)
    host.view.frame = CGRect(x: 0, y: 0, width: 600, height: 600)
    host.view.layoutSubtreeIfNeeded()
    #expect(host.view.bounds.width > 0)
  }
  #endif

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
