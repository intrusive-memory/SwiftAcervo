// AcervoModelsList.swift
// SwiftAcervoUI
//
// A SwiftData-backed catalog manager: queries `StoredModelReference`,
// renders the rows grouped by `groupID`, and (when the underlying
// store is writable) provides add/remove/edit affordances via toolbar
// + sheets + context menu.

import SwiftAcervo
import SwiftData
import SwiftUI

/// A drop-in catalog manager for `StoredModelReference` records.
///
/// The list `@Query`s the current `ModelContext` for every
/// `StoredModelReference`, groups them by `groupID`, and renders each
/// row through `AcervoModelDownloadRow`. The same three closures the
/// other components take (`availability`, `download`, `deleteModel`)
/// wire the rows to the host's download stack.
///
/// ### Editability
///
/// The list's mutating affordances (add/edit/remove toolbar buttons,
/// per-row "Remove…" context menu, sheet presentations) are gated by
/// the `editability` parameter. By default (`.automatic`) the list
/// inspects the model context's container configurations and treats
/// itself as read-only iff any configuration was created with
/// `ModelConfiguration(allowsSave: false)`. Hosts can force either
/// state with `.editable` / `.readOnly` — handy for "viewer" modes
/// where the store is writable but you want this particular view to
/// stay quiet.
///
/// ```swift
/// AcervoModelsList(
///   availability: { await Acervo.availability($0.id) },
///   download: { item, progress in
///     try await Acervo.ensureAvailable(
///       item.id,
///       files: [],
///       progress: { progress($0.overallProgress) }
///     )
///   },
///   deleteModel: { try Acervo.deleteModel($0.id) }
/// )
/// .navigationTitle("Models")
/// ```
public struct AcervoModelsList: View {

  /// Controls whether the list exposes add/edit/remove UI.
  public enum Editability: Sendable {
    /// Read from the `ModelContext`'s container configurations: the list is
    /// editable iff every configuration has `allowsSave == true`.
    case automatic
    /// Show no mutating UI regardless of the store's writability.
    case readOnly
    /// Always show mutating UI. Mutations still throw at the SwiftData layer
    /// if the underlying store is read-only.
    case editable
  }

  @Environment(\.modelContext) private var context
  @Query private var models: [StoredModelReference]

  @State private var selection: Set<String> = []
  @State private var sheet: ActiveSheet?

  private let editability: Editability
  private let addButtonLabel: LocalizedStringKey
  private let removeButtonLabel: LocalizedStringKey
  private let editButtonLabel: LocalizedStringKey
  private let editContextMenuLabel: LocalizedStringKey
  private let removeContextMenuLabel: LocalizedStringKey
  private let rowLabels: AcervoModelDownloadRow.Labels
  private let editSheetLabels: AcervoStoredModelEditSheet.Labels
  private let availability: @Sendable (AcervoModelRowItem) async -> ModelAvailability
  private let download:
    @Sendable (AcervoModelRowItem, @escaping @Sendable (Double) -> Void) async throws -> Void
  private let deleteModel: @Sendable (AcervoModelRowItem) async throws -> Void

  /// Creates the list.
  ///
  /// All user-visible copy is parameterized via `LocalizedStringKey` so
  /// hosts can supply localized strings that resolve against their own
  /// `Localizable.xcstrings`. Defaults are English-only on purpose.
  ///
  /// - Parameters:
  ///   - sortBy: Sort descriptors for the underlying `@Query`. Defaults to
  ///     `groupDisplayName` then `createdAt` ascending.
  ///   - editability: How the mutating UI is gated. See `Editability`.
  ///   - addButtonLabel: Toolbar "Add" button title. Default `"Add Model"`.
  ///   - removeButtonLabel: Toolbar "Remove" button title. Default `"Remove Model"`.
  ///   - editButtonLabel: Toolbar "Edit" button title. Default `"Edit Model"`.
  ///   - editContextMenuLabel: Per-row context menu "Edit" item. Default `"Edit…"`.
  ///   - removeContextMenuLabel: Per-row context menu destructive item.
  ///     Default `"Remove from Catalog & Delete Files"`.
  ///   - rowLabels: Copy for the rows the list renders. Defaults inherit
  ///     from `AcervoModelDownloadRow.Labels()`.
  ///   - editSheetLabels: Copy for the add/edit sheet the list presents
  ///     internally. Defaults inherit from `AcervoStoredModelEditSheet.Labels()`.
  ///   - availability: Reads current `ModelAvailability` for a row.
  ///   - download: Performs the download, calling the provided progress
  ///     sink with values in `0.0...1.0`.
  ///   - deleteModel: Deletes the model binary on disk. Called for both
  ///     the row's own delete button and the list's bulk-remove actions
  ///     (the SwiftData record is removed by the list either way).
  public init(
    sortBy: [SortDescriptor<StoredModelReference>] = [
      SortDescriptor(\.groupDisplayName),
      SortDescriptor(\.createdAt),
    ],
    editability: Editability = .automatic,
    addButtonLabel: LocalizedStringKey = "Add Model",
    removeButtonLabel: LocalizedStringKey = "Remove Model",
    editButtonLabel: LocalizedStringKey = "Edit Model",
    editContextMenuLabel: LocalizedStringKey = "Edit…",
    removeContextMenuLabel: LocalizedStringKey = "Remove from Catalog & Delete Files",
    rowLabels: AcervoModelDownloadRow.Labels = AcervoModelDownloadRow.Labels(),
    editSheetLabels: AcervoStoredModelEditSheet.Labels = AcervoStoredModelEditSheet.Labels(),
    availability: @escaping @Sendable (AcervoModelRowItem) async -> ModelAvailability,
    download:
      @escaping @Sendable (AcervoModelRowItem, @escaping @Sendable (Double) -> Void) async throws ->
      Void,
    deleteModel: @escaping @Sendable (AcervoModelRowItem) async throws -> Void
  ) {
    _models = Query(sort: sortBy)
    self.editability = editability
    self.addButtonLabel = addButtonLabel
    self.removeButtonLabel = removeButtonLabel
    self.editButtonLabel = editButtonLabel
    self.editContextMenuLabel = editContextMenuLabel
    self.removeContextMenuLabel = removeContextMenuLabel
    self.rowLabels = rowLabels
    self.editSheetLabels = editSheetLabels
    self.availability = availability
    self.download = download
    self.deleteModel = deleteModel
  }

  public var body: some View {
    List(selection: $selection) {
      ForEach(groupedModels, id: \.key) { group in
        Section {
          ForEach(group.models) { stored in
            row(for: stored)
          }
        } header: {
          if let label = group.displayName {
            Text(label.uppercased())
              .font(.caption)
              .fontWeight(.semibold)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier(
                "\(AcervoUIAccessibility.engineGroupHeaderPrefix).\(group.key)"
              )
          }
        }
      }
    }
    .toolbar { toolbarContent }
    .sheet(item: $sheet) { sheet in
      switch sheet {
      case .add:
        AcervoStoredModelEditSheet(mode: .add, labels: editSheetLabels) { draft in
          insert(draft)
        }
      case .edit(let id):
        if let model = models.first(where: { $0.id == id }) {
          AcervoStoredModelEditSheet(mode: .edit(model), labels: editSheetLabels) { draft in
            apply(draft, to: model)
          }
        }
      }
    }
  }

  // MARK: - Editability resolution

  private var isEditable: Bool {
    Self.resolveEditable(
      editability: editability,
      allConfigurationsAllowSave: context.container.configurations.allSatisfy(\.allowsSave)
    )
  }

  /// Pure editability resolver. Hosts pass the configured `Editability`
  /// and a precomputed flag describing whether every container
  /// configuration is writable; the function decides whether mutating UI
  /// should be shown. Exposed for unit testing.
  static func resolveEditable(
    editability: Editability,
    allConfigurationsAllowSave: Bool
  ) -> Bool {
    switch editability {
    case .editable: return true
    case .readOnly: return false
    case .automatic: return allConfigurationsAllowSave
    }
  }

  // MARK: - Rows

  @ViewBuilder
  private func row(for stored: StoredModelReference) -> some View {
    let rowView = AcervoModelDownloadRow(
      item: stored.rowItem,
      availability: availability,
      download: download,
      deleteModel: deleteModel,
      labels: rowLabels
    )
    .tag(stored.id)

    if isEditable {
      rowView.contextMenu {
        Button(editContextMenuLabel) { sheet = .edit(stored.id) }
        Button(removeContextMenuLabel, role: .destructive) {
          delete([stored])
        }
      }
    } else {
      rowView
    }
  }

  // MARK: - Toolbar

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    if isEditable {
      ToolbarItemGroup {
        Button {
          sheet = .add
        } label: {
          Label(addButtonLabel, systemImage: "plus")
        }

        Button(role: .destructive) {
          deleteSelected()
        } label: {
          Label(removeButtonLabel, systemImage: "minus")
        }
        .disabled(selection.isEmpty)

        Button {
          if let only = selection.first,
            selection.count == 1,
            models.contains(where: { $0.id == only })
          {
            sheet = .edit(only)
          }
        } label: {
          Label(editButtonLabel, systemImage: "pencil")
        }
        .disabled(selection.count != 1)
      }
    }
  }

  // MARK: - Mutations

  private func insert(_ draft: AcervoStoredModelEditSheet.Draft) {
    let id = draft.id.trimmingCharacters(in: .whitespaces)
    guard !models.contains(where: { $0.id == id }) else { return }
    let model = StoredModelReference(
      id: id,
      displayName: draft.displayName.trimmingCharacters(in: .whitespaces),
      subtitleLines: draft.subtitleLines,
      groupID: draft.normalizedGroupID,
      groupDisplayName: draft.normalizedGroupDisplayName,
      origin: draft.normalizedOrigin
    )
    context.insert(model)
    try? context.save()
  }

  private func apply(
    _ draft: AcervoStoredModelEditSheet.Draft,
    to model: StoredModelReference
  ) {
    model.displayName = draft.displayName.trimmingCharacters(in: .whitespaces)
    model.subtitleLines = draft.subtitleLines
    model.groupID = draft.normalizedGroupID
    model.groupDisplayName = draft.normalizedGroupDisplayName
    model.origin = draft.normalizedOrigin
    try? context.save()
  }

  private func deleteSelected() {
    let toDelete = models.filter { selection.contains($0.id) }
    delete(toDelete)
  }

  private func delete(_ records: [StoredModelReference]) {
    let snapshots = records.map { (id: $0.id, rowItem: $0.rowItem) }

    // Drop SwiftData records first so the UI updates immediately.
    for record in records {
      context.delete(record)
    }
    try? context.save()
    selection.subtract(snapshots.map(\.id))

    // Best-effort disk cleanup in the background; ignore failures so
    // the catalog stays consistent even when the binary is already gone.
    let deleteModel = self.deleteModel
    Task {
      for snapshot in snapshots {
        try? await deleteModel(snapshot.rowItem)
      }
    }
  }

  // MARK: - Grouping

  struct Group {
    let key: String
    let displayName: String?
    let models: [StoredModelReference]
  }

  var groupedModels: [Group] {
    Self.groupModels(models)
  }

  /// Pure grouper. Walks the input in order and buckets records by
  /// `groupID`, preserving first-seen iteration order. Ungrouped records
  /// land in a `"__ungrouped__"` bucket whose `displayName` is `nil`.
  /// Exposed for unit testing — the only reason this is a static
  /// function is so the algorithm can be exercised without a SwiftUI host.
  static func groupModels(_ models: [StoredModelReference]) -> [Group] {
    var order: [String] = []
    var seen: Set<String> = []
    var labelByKey: [String: String?] = [:]
    var modelsByKey: [String: [StoredModelReference]] = [:]

    for model in models {
      let key = model.groupID ?? "__ungrouped__"
      if !seen.contains(key) {
        order.append(key)
        seen.insert(key)
        labelByKey[key] = model.groupDisplayName
      }
      modelsByKey[key, default: []].append(model)
    }

    return order.map { key in
      Group(
        key: key,
        displayName: labelByKey[key] ?? nil,
        models: modelsByKey[key] ?? []
      )
    }
  }
}

// MARK: - Sheet routing

private enum ActiveSheet: Identifiable {
  case add
  case edit(String)

  var id: String {
    switch self {
    case .add: "add"
    case .edit(let id): "edit:\(id)"
    }
  }
}
