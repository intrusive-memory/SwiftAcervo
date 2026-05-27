// AcervoMigrationPlan.swift
// SwiftAcervoUI
//
// Describes how the Acervo SwiftData schema evolves across versions.
// Today the plan only contains V1; as new versions are added the
// `schemas` list grows and a `MigrationStage` is appended to `stages`
// describing how to move from the previous version to the new one.

import Foundation
import SwiftData

/// The Acervo schema's migration plan.
///
/// Pass this to `ModelContainer.init(for:migrationPlan:configurations:)`
/// alongside the *current* schema's model types. SwiftData walks the
/// `stages` array on launch, applying each stage in order until the
/// store is at the latest version.
///
/// ```swift
/// let container = try ModelContainer(
///     for: StoredModelReference.self,
///     migrationPlan: AcervoMigrationPlan.self
/// )
/// ```
///
/// ### Adding a new version
///
/// 1. Create `AcervoSchemaV2` with the new model shape.
/// 2. Append `AcervoSchemaV2.self` to `schemas`.
/// 3. Append a `MigrationStage` describing the V1 → V2 transition:
///    - `.lightweight(...)` for purely additive or renameable changes
///      SwiftData can infer.
///    - `.custom(...)` when the migration needs to read/write data
///      (splits, backfills, type changes).
/// 4. Update the `StoredModelReference` typealias in
///    `AcervoSchema.swift` to point at the new version's nested type.
public enum AcervoMigrationPlan: SchemaMigrationPlan {

  public static var schemas: [any VersionedSchema.Type] {
    [AcervoSchemaV1.self]
  }

  public static var stages: [MigrationStage] {
    []
  }
}
