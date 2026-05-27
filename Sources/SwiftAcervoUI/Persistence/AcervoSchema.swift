// AcervoSchema.swift
// SwiftAcervoUI
//
// Re-exports the *current* Acervo schema version at module scope.
// Application code references `StoredModelReference` directly; this
// file decides which `AcervoSchemaV<N>.StoredModelReference` that name
// resolves to. Bumping the schema typically means changing the
// right-hand side here (and appending a `MigrationStage` in
// `AcervoMigrationPlan`).

import SwiftData

/// The current persistent model type used by SwiftAcervoUI's
/// SwiftData-backed catalog. Currently resolves to
/// `AcervoSchemaV1.StoredModelReference`.
public typealias StoredModelReference = AcervoSchemaV1.StoredModelReference
