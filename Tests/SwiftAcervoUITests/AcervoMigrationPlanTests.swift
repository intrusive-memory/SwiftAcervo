// AcervoMigrationPlanTests.swift
// SwiftAcervoUITests
//
// Pin the SwiftData schema metadata so an accidental version bump or
// stage reordering is caught here before it ships into a real catalog.

import Foundation
import Testing
import SwiftData
@testable import SwiftAcervoUI

@MainActor
struct AcervoMigrationPlanTests {

  @Test("schemas list starts with the V1 schema")
  func schemasContainsV1() {
    let schemas = AcervoMigrationPlan.schemas
    #expect(schemas.count >= 1)
    let first = schemas.first
    let firstIsV1 = first is AcervoSchemaV1.Type
    #expect(firstIsV1)
  }

  @Test("stages is empty while V1 is the only version")
  func stagesIsEmpty() {
    #expect(AcervoMigrationPlan.stages.isEmpty)
  }

  @Test("V1 schema reports version 1.0.0")
  func v1VersionIdentifier() {
    let version = AcervoSchemaV1.versionIdentifier
    #expect(version == Schema.Version(1, 0, 0))
  }

  @Test("V1 schema registers StoredModelReference as its sole model")
  func v1RegistersStoredModelReference() {
    let models = AcervoSchemaV1.models
    #expect(models.count == 1)
    let isStoredModelReference = models.first is StoredModelReference.Type
    #expect(isStoredModelReference)
  }

  @Test("StoredModelReference typealias points at the V1 nested type")
  func typealiasResolvesToV1() {
    let viaTypealias: StoredModelReference.Type = StoredModelReference.self
    let viaNested: AcervoSchemaV1.StoredModelReference.Type = AcervoSchemaV1.StoredModelReference.self
    #expect(viaTypealias == viaNested)
  }

  @Test("ModelContainer can be constructed with the migration plan")
  func containerConstructsWithPlan() throws {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
      for: StoredModelReference.self,
      migrationPlan: AcervoMigrationPlan.self,
      configurations: config
    )
    // Smoke-test: the container exposes at least one configuration.
    #expect(!container.configurations.isEmpty)
  }
}
