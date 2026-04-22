import Foundation
import Testing

@testable import SwiftAcervo

/// Tests for Sortie 5: catalog introspection hydration-awareness.
///
/// Verifies that `pendingComponents()`, `totalCatalogSize()`, and
/// `unhydratedComponents()` correctly exclude or enumerate un-hydrated descriptors.
@Suite("Catalog Hydration Tests")
struct CatalogHydrationTests {

  private let uid = UUID().uuidString.prefix(8)

  @Test("pendingComponents excludes un-hydrated descriptors; totalCatalogSize and unhydratedComponents are correct")
  func hydrationAwarenessInCatalog() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("CatalogHydrationTests-\(UUID().uuidString)")
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
}
