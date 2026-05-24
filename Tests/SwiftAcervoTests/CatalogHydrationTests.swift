// CatalogHydrationTests.swift
// SwiftAcervoTests
//
// Companion tests for Sources/SwiftAcervo/Acervo+ComponentCatalog.swift
// and Sources/SwiftAcervo/Acervo+Hydration.swift.
//
// This file is reserved for tests that exercise hydration-DRIVEN catalog flows
// (i.e., tests that call Acervo.hydrateComponent or downloadComponent and then
// assert on catalog state). Pure catalog read-side tests (registeredComponents,
// isComponentReady, pendingComponents, totalCatalogSize, unhydratedComponents)
// live in ComponentCatalogQueriesTests.swift.

import Foundation
import Testing

@testable import SwiftAcervo

extension SharedStaticStateSuite.MockURLProtocolSuite {

  /// Tests for hydration-driven catalog behavior.
  ///
  /// Nested under `MockURLProtocolSuite` so the `.serialized` trait on the
  /// parent prevents concurrent suites from racing on `ComponentRegistry.shared`.
  @Suite("Catalog Hydration Tests")
  struct CatalogHydrationTests {
    // Hydration-driven tests will be added here as part of S6
    // (Acervo+Hydration.swift extraction), which creates HydrationCoalescerTests.swift.
    // The initial catalog-awareness test (pure read-side) was lifted to
    // ComponentCatalogQueriesTests.swift during S5.
  }
}
