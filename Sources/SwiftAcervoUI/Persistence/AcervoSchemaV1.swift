// AcervoSchemaV1.swift
// SwiftAcervoUI
//
// First version of the SwiftData schema that backs Acervo-aware apps.
// Each schema version is its own `VersionedSchema` enum that namespaces
// the `@Model` types belonging to that version. The current version is
// re-exported at module scope via the `StoredModelReference` typealias
// in `AcervoSchema.swift`; consumers normally write that typealias, not
// the namespaced form.

import Foundation
import SwiftData

/// Version 1 of the Acervo persistence schema.
///
/// The schema namespaces every `@Model` type that belongs to this
/// version so future versions (`AcervoSchemaV2`, ...) can redeclare the
/// same type names with different shapes without colliding. A
/// `SchemaMigrationPlan` (see `AcervoMigrationPlan`) describes the
/// stages between versions.
public enum AcervoSchemaV1: VersionedSchema {

  public static var versionIdentifier: Schema.Version {
    Schema.Version(1, 0, 0)
  }

  public static var models: [any PersistentModel.Type] {
    [StoredModelReference.self]
  }

  /// A SwiftData-backed reference to a single Acervo model entry in the
  /// host app's catalog. Mirrors the fields `AcervoModelRowItem` needs
  /// to render a row, plus bookkeeping (`createdAt`, `origin`).
  ///
  /// The `id` is the stable Acervo slug (e.g.
  /// `"black-forest-labs/FLUX.2-klein-4B"`) — the same string the host
  /// passes to `Acervo.ensureAvailable(slug:)`. It is marked unique so
  /// SwiftData enforces no-duplicates at the store level.
  @Model
  public final class StoredModelReference {

    /// Stable slug — also the CDN identifier.
    @Attribute(.unique) public var id: String

    /// Primary display label rendered by `AcervoModelRowItem.displayName`.
    public var displayName: String

    /// Secondary metadata strings (size, RAM, etc.) shown beneath the
    /// display name.
    public var subtitleLines: [String]

    /// Optional group key used by `AcervoModelsSection` to render a
    /// caption header above siblings that share the same `groupID`.
    public var groupID: String?

    /// Header text for the group. Required when `groupID` is non-nil.
    public var groupDisplayName: String?

    /// Free-form source URL or host where the model was fetched from
    /// (e.g. `"huggingface.co/black-forest-labs/FLUX.2-klein-4B"`).
    public var origin: String?

    /// Insertion timestamp — drives the default chronological sort.
    public var createdAt: Date

    public init(
      id: String,
      displayName: String,
      subtitleLines: [String] = [],
      groupID: String? = nil,
      groupDisplayName: String? = nil,
      origin: String? = nil,
      createdAt: Date = .now
    ) {
      self.id = id
      self.displayName = displayName
      self.subtitleLines = subtitleLines
      self.groupID = groupID
      self.groupDisplayName = groupDisplayName
      self.origin = origin
      self.createdAt = createdAt
    }
  }
}

extension AcervoSchemaV1.StoredModelReference {

  /// Projects the persistent record into the value-type row item that
  /// `AcervoModelsSection` and `AcervoModelDownloadRow` consume.
  public var rowItem: AcervoModelRowItem {
    AcervoModelRowItem(
      id: id,
      displayName: displayName,
      subtitleLines: subtitleLines,
      groupID: groupID,
      groupDisplayName: groupDisplayName
    )
  }
}
