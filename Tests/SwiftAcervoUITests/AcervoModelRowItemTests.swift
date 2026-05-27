// AcervoModelRowItemTests.swift
// SwiftAcervoUITests
//
// AcervoModelRowItem is a value type passed between host apps and the
// row/section/list views. Tests pin its defaults, equality, and hashing
// since downstream identity (ForEach, selection sets) depends on them.

import Foundation
import Testing

@testable import SwiftAcervoUI

struct AcervoModelRowItemTests {

  @Test("init applies sensible defaults for optional fields")
  func initDefaults() {
    let item = AcervoModelRowItem(id: "org/repo", displayName: "Display")
    #expect(item.id == "org/repo")
    #expect(item.displayName == "Display")
    #expect(item.subtitleLines.isEmpty)
    #expect(item.groupID == nil)
    #expect(item.groupDisplayName == nil)
  }

  @Test("init preserves every explicit argument")
  func initExplicit() {
    let item = AcervoModelRowItem(
      id: "org/repo",
      displayName: "Display",
      subtitleLines: ["a", "b"],
      groupID: "g",
      groupDisplayName: "Group"
    )
    #expect(item.subtitleLines == ["a", "b"])
    #expect(item.groupID == "g")
    #expect(item.groupDisplayName == "Group")
  }

  @Test("Identifiable.id matches the slug field")
  func idEqualsSlug() {
    let item = AcervoModelRowItem(id: "x", displayName: "X")
    let identifier: String = item.id
    #expect(identifier == "x")
  }

  @Test("Equatable compares every stored field")
  func equatableComparesAllFields() {
    let base = AcervoModelRowItem(
      id: "a", displayName: "A",
      subtitleLines: ["x"], groupID: "g", groupDisplayName: "G"
    )
    let same = AcervoModelRowItem(
      id: "a", displayName: "A",
      subtitleLines: ["x"], groupID: "g", groupDisplayName: "G"
    )
    let differentSubtitle = AcervoModelRowItem(
      id: "a", displayName: "A",
      subtitleLines: ["y"], groupID: "g", groupDisplayName: "G"
    )
    let differentGroupID = AcervoModelRowItem(
      id: "a", displayName: "A",
      subtitleLines: ["x"], groupID: "h", groupDisplayName: "G"
    )

    #expect(base == same)
    #expect(base != differentSubtitle)
    #expect(base != differentGroupID)
  }

  @Test("Hashable keeps equal values colliding in a Set")
  func hashableSetSemantics() {
    let a = AcervoModelRowItem(id: "x", displayName: "X")
    let b = AcervoModelRowItem(id: "x", displayName: "X")
    let c = AcervoModelRowItem(id: "y", displayName: "Y")
    let set: Set<AcervoModelRowItem> = [a, b, c]
    #expect(set.count == 2)
  }
}
