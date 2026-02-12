// IntegrationTests.swift
// SwiftAcervo
//
// Integration tests that require network access and a real HuggingFace
// endpoint. These tests are compiled only when the INTEGRATION_TESTS
// flag is set, so they do not run during normal `xcodebuild test`.
//
// To run integration tests:
//   xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS' \
//       OTHER_SWIFT_FLAGS='-D INTEGRATION_TESTS'
//

#if INTEGRATION_TESTS

import Testing
import Foundation
@testable import SwiftAcervo

// MARK: - Integration Test Helpers

/// Creates a unique temporary directory for use as a SharedModels root.
/// The caller is responsible for cleaning up via `cleanupTempDirectory(_:)`.
private func makeTempSharedModels() throws -> URL {
    let tempBase = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftAcervo-Integration-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: tempBase,
        withIntermediateDirectories: true
    )
    return tempBase
}

/// Removes a temporary directory created by `makeTempSharedModels()`.
private func cleanupTempDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// A small, publicly accessible model on HuggingFace suitable for
/// integration testing. Only `config.json` is downloaded to keep
/// test runtime minimal.
private let testModelId = "mlx-community/Llama-3.2-1B-Instruct-4bit"

/// A thread-safe collector for download progress reports.
private actor IntegrationProgressCollector {
    var reports: [AcervoDownloadProgress] = []

    func append(_ report: AcervoDownloadProgress) {
        reports.append(report)
    }

    func getReports() -> [AcervoDownloadProgress] {
        reports
    }
}

#endif
