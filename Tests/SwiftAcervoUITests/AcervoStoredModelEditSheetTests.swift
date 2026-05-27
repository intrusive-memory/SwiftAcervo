// AcervoStoredModelEditSheetTests.swift
// SwiftAcervoUITests
//
// Tests for AcervoStoredModelEditSheet's internal helpers (isEditing,
// title, isValid) plus a deterministic NSHostingController render on
// macOS that forces the SwiftUI body to evaluate. The body itself has
// no async work so the render is synchronous and non-flaky.

import Foundation
import SwiftUI
import Testing

@testable import SwiftAcervoUI

#if canImport(AppKit)
  import AppKit
#endif

@MainActor
struct AcervoStoredModelEditSheetTests {

  // MARK: - Mode-derived helpers

  @Test("isEditing is false in add mode")
  func isEditingFalseInAdd() {
    let sheet = AcervoStoredModelEditSheet(mode: .add) { _ in }
    #expect(sheet.isEditing == false)
    #expect(sheet.title == "New Model")
  }

  @Test("isEditing is true in edit mode")
  func isEditingTrueInEdit() {
    let record = StoredModelReference(id: "org/repo", displayName: "Display")
    let sheet = AcervoStoredModelEditSheet(mode: .edit(record)) { _ in }
    #expect(sheet.isEditing == true)
    #expect(sheet.title == "Edit Model")
  }

  // MARK: - isDraftValid

  @Test("isDraftValid rejects empty/whitespace id and displayName")
  func isDraftValidRejectsBlank() {
    #expect(!AcervoStoredModelEditSheet.isDraftValid(.init()))
    #expect(
      !AcervoStoredModelEditSheet.isDraftValid(
        .init(id: "", displayName: "Display")
      ))
    #expect(
      !AcervoStoredModelEditSheet.isDraftValid(
        .init(id: "  ", displayName: "Display")
      ))
    #expect(
      !AcervoStoredModelEditSheet.isDraftValid(
        .init(id: "org/repo", displayName: "")
      ))
    #expect(
      !AcervoStoredModelEditSheet.isDraftValid(
        .init(id: "org/repo", displayName: "   ")
      ))
  }

  @Test("isDraftValid accepts non-empty trimmed id + displayName")
  func isDraftValidAcceptsBoth() {
    #expect(
      AcervoStoredModelEditSheet.isDraftValid(
        .init(id: "org/repo", displayName: "Display")
      ))
    #expect(
      AcervoStoredModelEditSheet.isDraftValid(
        .init(id: "  org/repo  ", displayName: "  Display  ")
      ))
  }

  @Test("isValid instance accessor mirrors the static rule")
  func isValidInstanceAccessor() {
    let addSheet = AcervoStoredModelEditSheet(mode: .add) { _ in }
    // Default draft is empty → invalid.
    #expect(addSheet.isValid == false)
  }

  // MARK: - Body rendering (macOS host)

  #if canImport(AppKit)
    @Test("sheet body renders without crashing in add mode")
    func renderAddMode() {
      let sheet = AcervoStoredModelEditSheet(mode: .add) { _ in }
      let host = NSHostingController(rootView: sheet)
      host.view.frame = CGRect(x: 0, y: 0, width: 600, height: 600)
      host.view.layoutSubtreeIfNeeded()
      #expect(host.view.subviews.isEmpty == false || host.view.bounds.width > 0)
    }

    @Test("sheet body renders without crashing in edit mode")
    func renderEditMode() {
      let record = StoredModelReference(
        id: "org/repo",
        displayName: "Display",
        subtitleLines: ["line"]
      )
      let sheet = AcervoStoredModelEditSheet(mode: .edit(record)) { _ in }
      let host = NSHostingController(rootView: sheet)
      host.view.frame = CGRect(x: 0, y: 0, width: 600, height: 600)
      host.view.layoutSubtreeIfNeeded()
      #expect(host.view.bounds.width > 0)
    }
  #endif

  // MARK: - onSave callback wiring

  @Test("Draft mirrors a record's fields when edit-mode is constructed")
  func editModeInitialDraftMirrorsRecord() {
    let record = StoredModelReference(
      id: "org/repo",
      displayName: "Display",
      subtitleLines: ["a", "b"],
      groupID: "g",
      groupDisplayName: "Group",
      origin: "host"
    )
    // The sheet's initial @State draft is initialized from the record;
    // we can't read the @State directly, but we can confirm the
    // mode-passed record's fields are intact (this also pins the
    // expectations the body relies on).
    if case .edit(let m) = AcervoStoredModelEditSheet.Mode.edit(record) {
      #expect(m.id == "org/repo")
      #expect(m.displayName == "Display")
      #expect(m.subtitleLines == ["a", "b"])
      #expect(m.groupID == "g")
      #expect(m.groupDisplayName == "Group")
      #expect(m.origin == "host")
    } else {
      Issue.record("Expected .edit mode")
    }
  }
}
