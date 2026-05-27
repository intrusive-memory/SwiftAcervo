// AcervoModelRowItem.swift
// SwiftAcervoUI
//
// The view-model record passed to AcervoModelsSection / AcervoModelDownloadRow.
// Apps construct one of these from their domain types at the call site —
// SwiftAcervoUI deliberately does not depend on any app-level model type.

import Foundation

/// A single row's worth of display data for `AcervoModelDownloadRow` and
/// `AcervoModelsSection`.
///
/// `AcervoModelRowItem` is intentionally minimal — it carries just the
/// identifier the widget needs to drive the availability / download /
/// delete closures, plus the strings the row renders. Hosting apps map
/// their own model type to this struct at the call site (Vinetas maps its
/// `AvailableModel` here, for example).
///
/// Grouping is opt-in: when both `groupID` and `groupDisplayName` are set,
/// `AcervoModelsSection` renders an uppercased caption header above the
/// rows that share the same `groupID`. Items with `groupID == nil` are
/// rendered ungrouped, in the order they appear in the input array.
public struct AcervoModelRowItem: Identifiable, Hashable, Sendable {

  /// Stable identifier passed back to every closure (availability,
  /// download, delete). The host uses this to recover whatever richer
  /// domain type the item was built from.
  public let id: String

  /// Primary display label — typically the model's marketing name.
  public let displayName: String

  /// Secondary metadata lines shown beneath `displayName`, separated by
  /// `•` (rendered as a wrapping `HStack`). Examples: download size,
  /// minimum RAM, seconds-per-image. Empty array hides the secondary
  /// line entirely.
  public let subtitleLines: [String]

  /// Optional grouping key. Items sharing a `groupID` are rendered
  /// under one engine header. `nil` opts the row out of grouping.
  public let groupID: String?

  /// Header text rendered above the group when `groupID` is set. Ignored
  /// when `groupID` is `nil`. Items with the same `groupID` must agree on
  /// `groupDisplayName`; if they disagree, the first encountered wins.
  public let groupDisplayName: String?

  /// Creates a row item.
  ///
  /// - Parameters:
  ///   - id: Stable identifier handed back to the row's closures.
  ///   - displayName: Primary label.
  ///   - subtitleLines: Secondary metadata strings (size, RAM, etc.).
  ///   - groupID: Optional group key for engine-style grouping.
  ///   - groupDisplayName: Group header text (required when `groupID` is set).
  public init(
    id: String,
    displayName: String,
    subtitleLines: [String] = [],
    groupID: String? = nil,
    groupDisplayName: String? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.subtitleLines = subtitleLines
    self.groupID = groupID
    self.groupDisplayName = groupDisplayName
  }
}
