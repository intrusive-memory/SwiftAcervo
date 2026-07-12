// Companion tests for Sources/SwiftAcervo/BackgroundDownloadCoordinator.swift
//
// Exercises the platform-agnostic core of iOS background downloads (#81):
// completed-task routing (verify + install + ledger), event emission, and
// availability re-derivation. No URLSession — runs on macOS CI.

import Foundation
import Testing

@testable import SwiftAcervo

@Suite("BackgroundDownloadCoordinatorTests")
struct BackgroundDownloadCoordinatorTests {

  private final class TempDir {
    let url: URL
    init() {
      url = FileManager.default.temporaryDirectory
        .appendingPathComponent("acervo-bgcoord-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
  }

  private func writeTemp(_ tmp: TempDir, _ contents: String) throws -> URL {
    let url = tmp.url.appendingPathComponent("delivered-\(UUID().uuidString).tmp")
    try Data(contents.utf8).write(to: url)
    return url
  }

  /// Collects the next `count` buffered events (the coordinator's stream buffers
  /// unbounded, so events yielded before iteration are still delivered).
  private func collect(
    _ count: Int, from stream: AsyncStream<BackgroundDownloadEvent>
  ) async -> [BackgroundDownloadEvent] {
    var out: [BackgroundDownloadEvent] = []
    var iterator = stream.makeAsyncIterator()
    for _ in 0..<count {
      guard let event = await iterator.next() else { break }
      out.append(event)
    }
    return out
  }

  private let sampleURL = URL(string: "https://cdn.example/models/org_repo/w.bin")!

  @Test("completed task with matching SHA installs the file, verifies, and completes the repo")
  func resolveSuccess() async throws {
    let tmp = TempDir()
    let ledger = DownloadLedger(baseDirectory: tmp.url)
    let coord = BackgroundDownloadCoordinator(ledger: ledger, modelsBaseDirectory: tmp.url)

    let delivered = try writeTemp(tmp, "weights-payload")
    let sha = try IntegrityVerification.sha256(of: delivered)
    await coord.enqueue(repoId: "org/repo", file: "w.bin", remoteURL: sampleURL, expectedSHA256: sha)
    await coord.markInflight(repoId: "org/repo", file: "w.bin", taskIdentifier: 1)

    await coord.resolveCompletedTask(taskIdentifier: 1, deliveredFile: delivered)

    let dest = coord.destinationURL(repoId: "org/repo", file: "w.bin")
    #expect(FileManager.default.fileExists(atPath: dest.path))
    #expect(try Data(contentsOf: dest) == Data("weights-payload".utf8))
    #expect(await ledger.state(repoId: "org/repo", file: "w.bin") == .verified)
    #expect(await ledger.isRepoComplete(repoId: "org/repo"))

    let events = await collect(2, from: coord.events)
    #expect(events.contains(.fileVerified(repoId: "org/repo", file: "w.bin")))
    #expect(events.contains(.repoCompleted(repoId: "org/repo")))
  }

  @Test("multi-file repo emits repoCompleted only after the last file")
  func resolveMultiFile() async throws {
    let tmp = TempDir()
    let ledger = DownloadLedger(baseDirectory: tmp.url)
    let coord = BackgroundDownloadCoordinator(ledger: ledger, modelsBaseDirectory: tmp.url)

    let a = try writeTemp(tmp, "file-a")
    let b = try writeTemp(tmp, "file-b")
    await coord.enqueue(repoId: "org/m", file: "a", remoteURL: sampleURL,
      expectedSHA256: try IntegrityVerification.sha256(of: a))
    await coord.enqueue(repoId: "org/m", file: "b", remoteURL: sampleURL,
      expectedSHA256: try IntegrityVerification.sha256(of: b))
    await coord.markInflight(repoId: "org/m", file: "a", taskIdentifier: 10)
    await coord.markInflight(repoId: "org/m", file: "b", taskIdentifier: 11)

    await coord.resolveCompletedTask(taskIdentifier: 10, deliveredFile: a)
    #expect(await ledger.isRepoComplete(repoId: "org/m") == false)

    await coord.resolveCompletedTask(taskIdentifier: 11, deliveredFile: b)
    #expect(await ledger.isRepoComplete(repoId: "org/m") == true)

    // a -> fileVerified; b -> fileVerified + repoCompleted == 3 events total.
    let events = await collect(3, from: coord.events)
    #expect(events.filter { if case .fileVerified = $0 { return true }; return false }.count == 2)
    #expect(events.contains(.repoCompleted(repoId: "org/m")))
  }

  @Test("SHA mismatch marks the file failed, emits fileFailed, and does not install")
  func resolveMismatch() async throws {
    let tmp = TempDir()
    let ledger = DownloadLedger(baseDirectory: tmp.url)
    let coord = BackgroundDownloadCoordinator(ledger: ledger, modelsBaseDirectory: tmp.url)

    let delivered = try writeTemp(tmp, "corrupt")
    await coord.enqueue(repoId: "org/repo", file: "w.bin", remoteURL: sampleURL,
      expectedSHA256: "0000000000000000000000000000000000000000000000000000000000000000")
    await coord.markInflight(repoId: "org/repo", file: "w.bin", taskIdentifier: 2)

    await coord.resolveCompletedTask(taskIdentifier: 2, deliveredFile: delivered)

    let dest = coord.destinationURL(repoId: "org/repo", file: "w.bin")
    #expect(FileManager.default.fileExists(atPath: dest.path) == false)
    if case .failed = await ledger.state(repoId: "org/repo", file: "w.bin") {} else {
      Issue.record("expected failed state")
    }
    let events = await collect(1, from: coord.events)
    if case .fileFailed(let repo, let file, _) = events.first {
      #expect(repo == "org/repo"); #expect(file == "w.bin")
    } else {
      Issue.record("expected fileFailed event")
    }
  }

  @Test("an unknown task id drops the delivered file and does not crash")
  func resolveUnknownTask() async throws {
    let tmp = TempDir()
    let ledger = DownloadLedger(baseDirectory: tmp.url)
    let coord = BackgroundDownloadCoordinator(ledger: ledger, modelsBaseDirectory: tmp.url)

    let delivered = try writeTemp(tmp, "orphan")
    await coord.resolveCompletedTask(taskIdentifier: 999, deliveredFile: delivered)
    #expect(FileManager.default.fileExists(atPath: delivered.path) == false)
  }

  @Test("availability is re-derived from the ledger across states")
  func availabilityDerivation() async {
    let tmp = TempDir()
    let ledger = DownloadLedger(baseDirectory: tmp.url)
    let coord = BackgroundDownloadCoordinator(ledger: ledger, modelsBaseDirectory: tmp.url)

    #expect(await coord.availability(repoId: "org/x") == .notTracked)

    await ledger.register(repoId: "org/x", files: ["a", "b", "c", "d"])
    await ledger.markVerified(repoId: "org/x", file: "a")
    #expect(await coord.availability(repoId: "org/x") == .downloading(fraction: 0.25))

    await ledger.markFailed(repoId: "org/x", file: "b", reason: "boom")
    #expect(await coord.availability(repoId: "org/x") == .failed(files: ["b"]))

    // Clear the failure and verify the rest -> complete.
    await ledger.clear(repoId: "org/x")
    await ledger.register(repoId: "org/x", files: ["a"])
    await ledger.markVerified(repoId: "org/x", file: "a")
    #expect(await coord.availability(repoId: "org/x") == .complete)
  }

  @Test("recordProgress emits a progress event mapped to the task's file")
  func progressEvent() async {
    let tmp = TempDir()
    let ledger = DownloadLedger(baseDirectory: tmp.url)
    let coord = BackgroundDownloadCoordinator(ledger: ledger, modelsBaseDirectory: tmp.url)

    await coord.enqueue(repoId: "org/p", file: "w", remoteURL: sampleURL, expectedSHA256: nil)
    await coord.markInflight(repoId: "org/p", file: "w", taskIdentifier: 5)
    await coord.recordProgress(taskIdentifier: 5, totalWritten: 50, totalExpected: 200)

    let events = await collect(1, from: coord.events)
    #expect(events.first == .progress(repoId: "org/p", file: "w", fraction: 0.25))
  }

  @Test("destinationURL mirrors the slug/<file> layout, preserving subdirectories")
  func destinationLayout() {
    let tmp = TempDir()
    let ledger = DownloadLedger(baseDirectory: tmp.url)
    let coord = BackgroundDownloadCoordinator(ledger: ledger, modelsBaseDirectory: tmp.url)

    let dest = coord.destinationURL(repoId: "org/repo", file: "speech_tokenizer/config.json")
    let expected = tmp.url
      .appendingPathComponent(Acervo.slugify("org/repo"))
      .appendingPathComponent("speech_tokenizer")
      .appendingPathComponent("config.json")
    #expect(dest.path == expected.path)
  }
}
