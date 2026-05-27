// AcervoModelsSection.swift
// SwiftAcervoUI
//
// The drop-in Models section for a host app's Settings form. Renders the
// caller's items grouped by `groupID`, with one AcervoModelDownloadRow
// per item.

import SwiftUI
import SwiftAcervo

/// A reusable `Section` listing every model the host wants to expose for
/// download/delete, optionally grouped by engine.
///
/// The widget is decoupled from any specific download stack — the host
/// supplies three closures that the rows invoke. Identical closures may
/// be used across rows or specialized per-item; the row item's `id` is
/// always passed back so the closure can dispatch correctly.
///
/// Usage in a SwiftUI `Form`:
///
/// ```swift
/// Form {
///   AcervoModelsSection(
///     items: viewModel.rowItems,
///     availability: { await client.availability(itemId: $0.id) },
///     download: { item, progress in
///       try await client.download(itemId: item.id) { progress($0) }
///     },
///     deleteModel: { try await client.delete(itemId: $0.id) }
///   )
///   // ... your other settings sections
/// }
/// ```
public struct AcervoModelsSection: View {

  // MARK: - Inputs

  private let items: [AcervoModelRowItem]
  private let header: LocalizedStringKey
  private let headerAccessibilityIdentifier: String?
  private let availability: @Sendable (AcervoModelRowItem) async -> ModelAvailability
  private let download: @Sendable (AcervoModelRowItem, @escaping @Sendable (Double) -> Void) async throws -> Void
  private let deleteModel: @Sendable (AcervoModelRowItem) async throws -> Void

  // MARK: - Init

  /// Creates the section.
  ///
  /// - Parameters:
  ///   - items: The rows to render. Items sharing a non-nil `groupID`
  ///     are rendered under one caption header in the order they first
  ///     appear; ungrouped items render in input order.
  ///   - header: The Section header text. Defaults to `"Models"`.
  ///   - headerAccessibilityIdentifier: Optional accessibility id for
  ///     the header text. Vinetas wires its existing
  ///     `"settings.modelsSection"` identifier here so UI tests keep
  ///     finding the section.
  ///   - availability: Reads current `ModelAvailability` for a row.
  ///   - download: Performs the download, calling the provided
  ///     progress sink with values in `0.0...1.0`.
  ///   - deleteModel: Removes the model.
  public init(
    items: [AcervoModelRowItem],
    header: LocalizedStringKey = "Models",
    headerAccessibilityIdentifier: String? = nil,
    availability: @escaping @Sendable (AcervoModelRowItem) async -> ModelAvailability,
    download: @escaping @Sendable (AcervoModelRowItem, @escaping @Sendable (Double) -> Void) async throws -> Void,
    deleteModel: @escaping @Sendable (AcervoModelRowItem) async throws -> Void
  ) {
    self.items = items
    self.header = header
    self.headerAccessibilityIdentifier = headerAccessibilityIdentifier
    self.availability = availability
    self.download = download
    self.deleteModel = deleteModel
  }

  // MARK: - Body

  public var body: some View {
    Section {
      ForEach(orderedGroups, id: \.key) { group in
        if let key = group.key, let label = group.displayName {
          engineGroupHeader(label, groupID: key)
        }
        ForEach(group.items) { item in
          AcervoModelDownloadRow(
            item: item,
            availability: availability,
            download: download,
            deleteModel: deleteModel
          )
        }
      }
    } header: {
      headerLabel
    }
  }

  @ViewBuilder
  private var headerLabel: some View {
    if let id = headerAccessibilityIdentifier {
      Text(header).accessibilityIdentifier(id)
    } else {
      Text(header)
    }
  }

  // MARK: - Group Header

  private func engineGroupHeader(_ name: String, groupID: String) -> some View {
    HStack(spacing: 6) {
      Text(name)
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      Spacer()
    }
    .padding(.top, 4)
    .listRowSeparator(.hidden)
    .accessibilityIdentifier("\(AcervoUIAccessibility.engineGroupHeaderPrefix).\(groupID)")
  }

  // MARK: - Grouping

  /// Stable, input-ordered grouping. The key is `nil` for ungrouped
  /// items so the surrounding `ForEach(id: \.key)` stays well-formed.
  private struct OrderedGroup: Hashable {
    let key: String?
    let displayName: String?
    let items: [AcervoModelRowItem]
  }

  private var orderedGroups: [OrderedGroup] {
    var order: [String?] = []
    var seen: Set<String?> = []
    var labelByKey: [String?: String?] = [:]
    var itemsByKey: [String?: [AcervoModelRowItem]] = [:]

    for item in items {
      let key = item.groupID
      if !seen.contains(key) {
        order.append(key)
        seen.insert(key)
        labelByKey[key] = item.groupDisplayName
      }
      itemsByKey[key, default: []].append(item)
    }

    return order.map { key in
      OrderedGroup(
        key: key,
        displayName: labelByKey[key] ?? nil,
        items: itemsByKey[key] ?? []
      )
    }
  }
}
