// AcervoStoredModelEditSheet.swift
// SwiftAcervoUI
//
// Add/edit form for a single `StoredModelReference`. Used by
// `AcervoModelsList` and also available as a standalone sheet body for
// hosts that want to drive their own add/edit flows.

import SwiftUI
import SwiftData

/// A `Form`-based add/edit sheet for one `StoredModelReference`.
///
/// The sheet is *value-driven*: it never touches the `ModelContext`
/// itself. Callers receive a fully-populated `Draft` from the `onSave`
/// closure and decide whether to insert (add mode) or mutate an
/// existing record (edit mode).
///
/// ```swift
/// .sheet(item: $activeSheet) { sheet in
///   switch sheet {
///   case .add:
///     AcervoStoredModelEditSheet(mode: .add) { draft in
///       let record = StoredModelReference(
///         id: draft.id,
///         displayName: draft.displayName,
///         subtitleLines: draft.subtitleLines,
///         groupID: draft.normalizedGroupID,
///         groupDisplayName: draft.normalizedGroupDisplayName
///       )
///       context.insert(record)
///     }
///   case .edit(let model):
///     AcervoStoredModelEditSheet(mode: .edit(model)) { draft in
///       model.displayName = draft.displayName
///       model.subtitleLines = draft.subtitleLines
///       // ...
///     }
///   }
/// }
/// ```
///
/// The identifier field is editable in `.add` mode and locked in
/// `.edit` mode (the slug is the primary key and cannot be renamed
/// without re-inserting).
public struct AcervoStoredModelEditSheet: View {

  /// Whether the sheet is creating a new record or editing an existing one.
  public enum Mode {
    case add
    case edit(StoredModelReference)
  }

  /// The trimmed/normalized values produced by the form on save.
  ///
  /// `subtitleLines` is derived from the multi-line text editor's contents:
  /// each non-empty line becomes one entry. The two `normalized*` accessors
  /// return `nil` when the underlying field is empty after trimming, which
  /// matches `StoredModelReference`'s optional group fields.
  public struct Draft: Sendable {

    /// The slug (Acervo identifier). Trimmed before being handed to `onSave`.
    public var id: String

    /// Primary display label.
    public var displayName: String

    /// Newline-separated subtitle text. Parse via `subtitleLines`.
    public var subtitleText: String

    /// Raw group ID input. Use `normalizedGroupID` for the persisted value.
    public var groupID: String

    /// Raw group display name input. Use `normalizedGroupDisplayName` for the persisted value.
    public var groupDisplayName: String

    /// Free-form source URL or host (e.g. `"huggingface.co/org/repo"`).
    public var origin: String

    public init(
      id: String = "",
      displayName: String = "",
      subtitleText: String = "",
      groupID: String = "",
      groupDisplayName: String = "",
      origin: String = ""
    ) {
      self.id = id
      self.displayName = displayName
      self.subtitleText = subtitleText
      self.groupID = groupID
      self.groupDisplayName = groupDisplayName
      self.origin = origin
    }

    /// One entry per non-empty trimmed line of `subtitleText`.
    public var subtitleLines: [String] {
      subtitleText
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    }

    /// `nil` when `groupID` is empty after trimming.
    public var normalizedGroupID: String? {
      let trimmed = groupID.trimmingCharacters(in: .whitespaces)
      return trimmed.isEmpty ? nil : trimmed
    }

    /// `nil` when `groupDisplayName` is empty after trimming.
    public var normalizedGroupDisplayName: String? {
      let trimmed = groupDisplayName.trimmingCharacters(in: .whitespaces)
      return trimmed.isEmpty ? nil : trimmed
    }

    /// `nil` when `origin` is empty after trimming.
    public var normalizedOrigin: String? {
      let trimmed = origin.trimmingCharacters(in: .whitespaces)
      return trimmed.isEmpty ? nil : trimmed
    }
  }

  let mode: Mode
  let onSave: (Draft) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var draft: Draft

  /// Creates an add/edit sheet.
  ///
  /// - Parameters:
  ///   - mode: `.add` for a brand-new record, `.edit(_:)` to populate the
  ///     form from an existing `StoredModelReference`.
  ///   - onSave: Called with the trimmed/normalized `Draft` when the
  ///     user taps Save. The sheet dismisses automatically.
  public init(mode: Mode, onSave: @escaping (Draft) -> Void) {
    self.mode = mode
    self.onSave = onSave
    switch mode {
    case .add:
      _draft = State(initialValue: Draft())
    case .edit(let model):
      _draft = State(initialValue: Draft(
        id: model.id,
        displayName: model.displayName,
        subtitleText: model.subtitleLines.joined(separator: "\n"),
        groupID: model.groupID ?? "",
        groupDisplayName: model.groupDisplayName ?? "",
        origin: model.origin ?? ""
      ))
    }
  }

  public var body: some View {
    NavigationStack {
      Form {
        Section("Identifier") {
          TextField("org/model-slug", text: $draft.id)
            .textFieldStyle(.roundedBorder)
            .disabled(isEditing)
            .help(isEditing ? "Slug is immutable once created." : "")
        }

        Section("Display") {
          TextField("Display name", text: $draft.displayName)
            .textFieldStyle(.roundedBorder)
        }

        Section {
          TextEditor(text: $draft.subtitleText)
            .font(.body.monospaced())
            .frame(minHeight: 100)
        } header: {
          Text("Subtitle lines")
        } footer: {
          Text("One line per row. Shown beneath the display name.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section {
          TextField("Group ID (optional)", text: $draft.groupID)
            .textFieldStyle(.roundedBorder)
          TextField("Group display name", text: $draft.groupDisplayName)
            .textFieldStyle(.roundedBorder)
        } header: {
          Text("Grouping")
        } footer: {
          Text("Rows sharing a Group ID render under one header.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section {
          TextField("Source URL or host (optional)", text: $draft.origin)
            .textFieldStyle(.roundedBorder)
        } header: {
          Text("Origin")
        } footer: {
          Text("Free-form note recording where the model came from.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .navigationTitle(title)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            onSave(draft)
            dismiss()
          }
          .disabled(!isValid)
        }
      }
    }
    .frame(minWidth: 480, minHeight: 460)
  }

  var isEditing: Bool {
    if case .edit = mode { return true }
    return false
  }

  var title: String {
    switch mode {
    case .add: "New Model"
    case .edit: "Edit Model"
    }
  }

  var isValid: Bool {
    Self.isDraftValid(draft)
  }

  /// Pure validity check used by the Save button. Exposed for unit testing
  /// so the rule can be exercised without standing up a SwiftUI host.
  static func isDraftValid(_ draft: Draft) -> Bool {
    !draft.id.trimmingCharacters(in: .whitespaces).isEmpty &&
      !draft.displayName.trimmingCharacters(in: .whitespaces).isEmpty
  }
}
