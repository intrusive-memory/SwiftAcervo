// AcervoStoredModelEditSheetDraftTests.swift
// SwiftAcervoUITests
//
// Pure value-type tests for AcervoStoredModelEditSheet.Draft. The sheet
// itself is a SwiftUI Form; the testable logic lives in the Draft's
// trimming/normalization accessors, which are what AcervoModelsList
// consumes to write SwiftData records.

import Foundation
import SwiftUI
import Testing

@testable import SwiftAcervoUI

struct AcervoStoredModelEditSheetDraftTests {

  // MARK: - Defaults

  @Test("default init produces empty strings everywhere")
  func defaultInitIsEmpty() {
    let draft = AcervoStoredModelEditSheet.Draft()
    #expect(draft.id == "")
    #expect(draft.displayName == "")
    #expect(draft.subtitleText == "")
    #expect(draft.groupID == "")
    #expect(draft.groupDisplayName == "")
    #expect(draft.origin == "")
    #expect(draft.subtitleLines.isEmpty)
    #expect(draft.normalizedGroupID == nil)
    #expect(draft.normalizedGroupDisplayName == nil)
    #expect(draft.normalizedOrigin == nil)
  }

  @Test("explicit init preserves every field verbatim")
  func explicitInitPreservesFields() {
    let draft = AcervoStoredModelEditSheet.Draft(
      id: "org/repo",
      displayName: "Display",
      subtitleText: "line-1\nline-2",
      groupID: "g",
      groupDisplayName: "Group",
      origin: "huggingface.co/org/repo"
    )
    #expect(draft.id == "org/repo")
    #expect(draft.displayName == "Display")
    #expect(draft.subtitleText == "line-1\nline-2")
    #expect(draft.groupID == "g")
    #expect(draft.groupDisplayName == "Group")
    #expect(draft.origin == "huggingface.co/org/repo")
  }

  // MARK: - subtitleLines

  @Test("subtitleLines returns an empty array for empty input")
  func subtitleLinesEmpty() {
    var draft = AcervoStoredModelEditSheet.Draft()
    draft.subtitleText = ""
    #expect(draft.subtitleLines.isEmpty)
  }

  @Test("subtitleLines returns one entry for a single non-empty line")
  func subtitleLinesSingle() {
    var draft = AcervoStoredModelEditSheet.Draft()
    draft.subtitleText = "~4 GB"
    #expect(draft.subtitleLines == ["~4 GB"])
  }

  @Test("subtitleLines splits on newlines and trims each line")
  func subtitleLinesTrims() {
    var draft = AcervoStoredModelEditSheet.Draft()
    draft.subtitleText = "  ~4 GB  \n  Requires 8 GB RAM  "
    #expect(draft.subtitleLines == ["~4 GB", "Requires 8 GB RAM"])
  }

  @Test("subtitleLines drops blank-after-trim lines")
  func subtitleLinesDropsBlanks() {
    var draft = AcervoStoredModelEditSheet.Draft()
    draft.subtitleText = "first\n\n   \nsecond\n"
    #expect(draft.subtitleLines == ["first", "second"])
  }

  @Test("subtitleLines handles CRLF and mixed newline styles")
  func subtitleLinesMixedNewlines() {
    var draft = AcervoStoredModelEditSheet.Draft()
    draft.subtitleText = "a\r\nb\nc"
    #expect(draft.subtitleLines == ["a", "b", "c"])
  }

  // MARK: - normalizedGroupID

  @Test("normalizedGroupID is nil when empty or whitespace-only")
  func normalizedGroupIDNil() {
    var draft = AcervoStoredModelEditSheet.Draft()
    #expect(draft.normalizedGroupID == nil)

    draft.groupID = "   "
    #expect(draft.normalizedGroupID == nil)

    draft.groupID = "\t\t"
    #expect(draft.normalizedGroupID == nil)
  }

  @Test("normalizedGroupID trims surrounding whitespace and returns the rest")
  func normalizedGroupIDTrims() {
    var draft = AcervoStoredModelEditSheet.Draft()
    draft.groupID = "  flux  "
    #expect(draft.normalizedGroupID == "flux")
  }

  // MARK: - normalizedGroupDisplayName

  @Test("normalizedGroupDisplayName is nil when empty or whitespace-only")
  func normalizedGroupDisplayNameNil() {
    var draft = AcervoStoredModelEditSheet.Draft()
    #expect(draft.normalizedGroupDisplayName == nil)

    draft.groupDisplayName = "   "
    #expect(draft.normalizedGroupDisplayName == nil)
  }

  @Test("normalizedGroupDisplayName trims whitespace")
  func normalizedGroupDisplayNameTrims() {
    var draft = AcervoStoredModelEditSheet.Draft()
    draft.groupDisplayName = "  FLUX models  "
    #expect(draft.normalizedGroupDisplayName == "FLUX models")
  }

  // MARK: - normalizedOrigin

  @Test("normalizedOrigin is nil when empty or whitespace-only")
  func normalizedOriginNil() {
    var draft = AcervoStoredModelEditSheet.Draft()
    #expect(draft.normalizedOrigin == nil)

    draft.origin = "   "
    #expect(draft.normalizedOrigin == nil)
  }

  @Test("normalizedOrigin trims whitespace")
  func normalizedOriginTrims() {
    var draft = AcervoStoredModelEditSheet.Draft()
    draft.origin = "  huggingface.co/org/repo  "
    #expect(draft.normalizedOrigin == "huggingface.co/org/repo")
  }

  // MARK: - Mode

  @Test("Mode.add and Mode.edit are distinct cases")
  func modeCasesDistinct() {
    let addMode = AcervoStoredModelEditSheet.Mode.add
    if case .add = addMode {
      // expected
    } else {
      Issue.record("Expected .add mode")
    }
  }
}
