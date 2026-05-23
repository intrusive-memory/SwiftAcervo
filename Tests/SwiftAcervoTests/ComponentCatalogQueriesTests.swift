// ComponentCatalogQueriesTests.swift
// SwiftAcervoTests
//
// Companion tests for Sources/SwiftAcervo/Acervo+ComponentCatalog.swift.
// Covers the read-side catalog query API: registeredComponents, component(_:),
// isComponentReady, pendingComponents, totalCatalogSize, unhydratedComponents.
//
// These tests do NOT exercise hydration flows (hydrateComponent / downloadComponent).
// Hydration-driven tests live in CatalogHydrationTests.swift.

import Foundation
import Testing

@testable import SwiftAcervo

extension SharedStaticStateSuite.MockURLProtocolSuite {

  /// Tests for the read-side catalog query surface defined in
  /// `Acervo+ComponentCatalog.swift`.
  ///
  /// Nested under `MockURLProtocolSuite` so the `.serialized` trait on the
  /// parent prevents concurrent suites from racing on `ComponentRegistry.shared`
  /// between the baseline capture and the final delta assertion.
  @Suite("Component Catalog Queries Tests")
  struct ComponentCatalogQueriesTests {

    private let uid = UUID().uuidString.prefix(8)

    // MARK: - pendingComponents / totalCatalogSize / unhydratedComponents

    @Test(
      "pendingComponents excludes un-hydrated descriptors; totalCatalogSize and unhydratedComponents are correct"
    )
    func hydrationAwarenessInCatalog() throws {
      let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ComponentCatalogQueriesTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

      let declaredId = "cat-hydra-declared-\(uid)"
      let bareId = "cat-hydra-bare-\(uid)"

      let declaredDescriptor = ComponentDescriptor(
        id: declaredId,
        type: .backbone,
        displayName: "Declared",
        repoId: "test-org/declared-\(uid)",
        files: [ComponentFile(relativePath: "config.json", expectedSizeBytes: 100)],
        estimatedSizeBytes: 100,
        minimumMemoryBytes: 0
      )

      let bareDescriptor = ComponentDescriptor(
        id: bareId,
        type: .backbone,
        displayName: "Bare",
        repoId: "test-org/bare-\(uid)",
        minimumMemoryBytes: 0
      )

      // Capture baseline before registering our components so we can assert deltas
      let baselinePending = Acervo.totalCatalogSize(in: tempDir).pending

      Acervo.register(declaredDescriptor)
      Acervo.register(bareDescriptor)

      defer {
        Acervo.unregister(declaredId)
        Acervo.unregister(bareId)
        try? FileManager.default.removeItem(at: tempDir)
      }

      // pendingComponents: declared ID should appear (not downloaded); bare ID should NOT appear
      let pending = Acervo.pendingComponents(in: tempDir)
      let pendingIds = pending.map(\.id)
      #expect(pendingIds.contains(declaredId))
      #expect(!pendingIds.contains(bareId))

      // totalCatalogSize: only the declared descriptor (100 bytes) contributes to the delta.
      // Bare descriptor is excluded because it is un-hydrated.
      let sizes = Acervo.totalCatalogSize(in: tempDir)
      #expect(sizes.pending - baselinePending == 100)

      // unhydratedComponents: should return bareId (among our registered IDs), not declaredId
      let unhydrated = Acervo.unhydratedComponents()
      #expect(unhydrated.contains(bareId))
      #expect(!unhydrated.contains(declaredId))
    }

    // MARK: - registeredComponents

    @Test("registeredComponents returns all registered descriptors including new ones")
    func registeredComponentsIncludesNewlyRegistered() throws {
      let id = "cat-reg-all-\(uid)"
      let descriptor = ComponentDescriptor(
        id: id,
        type: .encoder,
        displayName: "Encoder Test",
        repoId: "test-org/encoder-\(uid)",
        files: [ComponentFile(relativePath: "model.safetensors")],
        estimatedSizeBytes: 500,
        minimumMemoryBytes: 0
      )

      let countBefore = Acervo.registeredComponents().count
      Acervo.register(descriptor)
      defer { Acervo.unregister(id) }

      let all = Acervo.registeredComponents()
      #expect(all.count == countBefore + 1)
      #expect(all.contains(where: { $0.id == id }))
    }

    @Test("registeredComponents(ofType:) filters by type correctly")
    func registeredComponentsOfTypeFilters() throws {
      let encoderId = "cat-type-enc-\(uid)"
      let backboneId = "cat-type-bck-\(uid)"

      let encoderDesc = ComponentDescriptor(
        id: encoderId,
        type: .encoder,
        displayName: "Encoder",
        repoId: "test-org/enc-\(uid)",
        files: [ComponentFile(relativePath: "model.safetensors")],
        estimatedSizeBytes: 200,
        minimumMemoryBytes: 0
      )
      let backboneDesc = ComponentDescriptor(
        id: backboneId,
        type: .backbone,
        displayName: "Backbone",
        repoId: "test-org/bck-\(uid)",
        files: [ComponentFile(relativePath: "model.safetensors")],
        estimatedSizeBytes: 300,
        minimumMemoryBytes: 0
      )

      Acervo.register(encoderDesc)
      Acervo.register(backboneDesc)
      defer {
        Acervo.unregister(encoderId)
        Acervo.unregister(backboneId)
      }

      let encoders = Acervo.registeredComponents(ofType: .encoder)
      let backbones = Acervo.registeredComponents(ofType: .backbone)

      #expect(encoders.contains(where: { $0.id == encoderId }))
      #expect(!encoders.contains(where: { $0.id == backboneId }))
      #expect(backbones.contains(where: { $0.id == backboneId }))
      #expect(!backbones.contains(where: { $0.id == encoderId }))
    }

    // MARK: - component(_:)

    @Test("component(_:) returns descriptor for registered ID and nil for unknown ID")
    func componentLookup() throws {
      let id = "cat-lookup-\(uid)"
      let descriptor = ComponentDescriptor(
        id: id,
        type: .backbone,
        displayName: "Lookup Test",
        repoId: "test-org/lookup-\(uid)",
        files: [ComponentFile(relativePath: "config.json")],
        estimatedSizeBytes: 100,
        minimumMemoryBytes: 0
      )

      #expect(Acervo.component(id) == nil)

      Acervo.register(descriptor)
      defer { Acervo.unregister(id) }

      let found = Acervo.component(id)
      #expect(found != nil)
      #expect(found?.id == id)
      #expect(found?.displayName == "Lookup Test")

      #expect(Acervo.component("definitely-not-registered-\(uid)") == nil)
    }

    // MARK: - isComponentReady

    @Test("isComponentReady returns false when component not downloaded")
    func isComponentReadyReturnsFalseWhenNotDownloaded() throws {
      let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CatalogReadyFalse-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tempDir) }

      let id = "cat-ready-false-\(uid)"
      let descriptor = ComponentDescriptor(
        id: id,
        type: .backbone,
        displayName: "Not Downloaded",
        repoId: "test-org/not-dl-\(uid)",
        files: [ComponentFile(relativePath: "model.safetensors", expectedSizeBytes: 1000)],
        estimatedSizeBytes: 1000,
        minimumMemoryBytes: 0
      )

      Acervo.register(descriptor)
      defer { Acervo.unregister(id) }

      #expect(Acervo.isComponentReady(id, in: tempDir) == false)
    }

    @Test("isComponentReady returns true when all files present with correct sizes")
    func isComponentReadyReturnsTrueWhenFilesPresent() throws {
      let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CatalogReadyTrue-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tempDir) }

      let id = "cat-ready-true-\(uid)"
      let repoId = "test-org/ready-true-\(uid)"
      let content = Data("hello".utf8)  // 5 bytes
      let descriptor = ComponentDescriptor(
        id: id,
        type: .backbone,
        displayName: "Downloaded",
        repoId: repoId,
        files: [ComponentFile(relativePath: "config.json", expectedSizeBytes: Int64(content.count))],
        estimatedSizeBytes: Int64(content.count),
        minimumMemoryBytes: 0
      )

      Acervo.register(descriptor)
      defer { Acervo.unregister(id) }

      // Write the file at the expected path
      let slug = Acervo.slugify(repoId)
      let componentDir = tempDir.appendingPathComponent(slug)
      try FileManager.default.createDirectory(at: componentDir, withIntermediateDirectories: true)
      let fileURL = componentDir.appendingPathComponent("config.json")
      try content.write(to: fileURL)

      #expect(Acervo.isComponentReady(id, in: tempDir) == true)
    }

    @Test("isComponentReady returns false for un-hydrated descriptor")
    func isComponentReadyReturnsFalseForUnhydrated() throws {
      let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CatalogReadyUnhydrated-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tempDir) }

      let id = "cat-ready-bare-\(uid)"
      // Bare (un-hydrated) descriptor — no files declared
      let descriptor = ComponentDescriptor(
        id: id,
        type: .backbone,
        displayName: "Bare",
        repoId: "test-org/bare-ready-\(uid)",
        minimumMemoryBytes: 0
      )

      Acervo.register(descriptor)
      defer { Acervo.unregister(id) }

      // Even if files are on disk somehow, un-hydrated should return false
      #expect(Acervo.isComponentReady(id, in: tempDir) == false)
    }

    @Test("isComponentReady returns false for unregistered ID")
    func isComponentReadyReturnsFalseForUnregistered() throws {
      let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CatalogReadyUnreg-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tempDir) }

      let unknownId = "cat-ready-unknown-\(uid)"
      #expect(Acervo.isComponentReady(unknownId, in: tempDir) == false)
    }
  }
}
