//
//  AcervoTests.swift
//  AcervoTests
//
//  Created by TOM STOVALL on 5/26/26.
//

import XCTest
import SwiftAcervoUI
@testable import Acervo

final class AcervoTests: XCTestCase {

    // MARK: - Fixture ID invariant

    /// Every fixture row must carry a non-empty stable identifier.
    /// An empty `id` would cause closure dispatch (availability / download /
    /// delete) to silently operate on the wrong model.
    func testEveryFixtureHasNonEmptyID() {
        for item in FixtureModels.demoFixtures {
            XCTAssertFalse(
                item.id.isEmpty,
                "AcervoModelRowItem.id must not be empty (found empty id in item with displayName '\(item.displayName)')"
            )
        }
    }

    // MARK: - Grouping invariant

    /// A row must be fully grouped (both `groupID` and `groupDisplayName` set)
    /// or fully ungrouped (both `nil`). A half-grouped row — `groupID` set but
    /// `groupDisplayName` nil, or vice versa — leaves `AcervoModelsSection`
    /// unable to render the engine caption header correctly.
    func testGroupingInvariant() {
        for item in FixtureModels.demoFixtures {
            let bothSet = item.groupID != nil && item.groupDisplayName != nil
            let bothNil = item.groupID == nil && item.groupDisplayName == nil
            XCTAssertTrue(
                bothSet || bothNil,
                "Row '\(item.id)' is half-grouped: groupID=\(item.groupID ?? "nil"), groupDisplayName=\(item.groupDisplayName ?? "nil"). Both must be set or both must be nil."
            )
        }
    }

    // MARK: - Path coverage: ungrouped and grouped rows both present

    /// The fixture array must exercise the ungrouped rendering path
    /// (at least one row with `groupID == nil`) AND the grouped-header path
    /// (at least two rows sharing the same non-nil `groupID`).
    func testGroupedAndUngroupedPathsExercised() {
        let fixtures = FixtureModels.demoFixtures

        // At least one row must be ungrouped.
        XCTAssertTrue(
            fixtures.contains { $0.groupID == nil },
            "demoFixtures must contain at least one row with groupID == nil to exercise the ungrouped rendering path."
        )

        // At least two rows must share a groupID to exercise the grouped-header path.
        let grouped = Dictionary(grouping: fixtures.filter { $0.groupID != nil }, by: { $0.groupID! })
        let hasSharedGroup = grouped.values.contains { $0.count >= 2 }
        XCTAssertTrue(
            hasSharedGroup,
            "demoFixtures must contain at least two rows with the same non-nil groupID to exercise the grouped-header rendering path. Current groupID counts: \(grouped.mapValues(\.count))."
        )
    }

}
