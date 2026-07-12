// Companion tests for Sources/SwiftAcervo/DownloadLedger.swift
//
// The ledger is the durable record that lets a background download survive an
// app relaunch (#81). These tests exercise it against a temp directory — no
// URLSession, no App Group — so they run on macOS CI.

import Foundation
import Testing

@testable import SwiftAcervo

@Suite("DownloadLedgerTests")
struct DownloadLedgerTests {

  /// A fresh, isolated base directory per test, cleaned up on deinit.
  private final class TempDir {
    let url: URL
    init() {
      url = FileManager.default.temporaryDirectory
        .appendingPathComponent("acervo-ledger-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
  }

  @Test("register inserts files as queued and is idempotent")
  func registerQueuesFiles() async {
    let tmp = TempDir()
    let ledger = DownloadLedger(baseDirectory: tmp.url)

    await ledger.register(repoId: "org/repo", files: ["a.json", "b.safetensors"])
    #expect(await ledger.state(repoId: "org/repo", file: "a.json") == .queued)
    #expect(await ledger.state(repoId: "org/repo", file: "b.safetensors") == .queued)

    // Re-registering must not clobber an advanced state.
    await ledger.markVerified(repoId: "org/repo", file: "a.json")
    await ledger.register(repoId: "org/repo", files: ["a.json", "b.safetensors", "c.txt"])
    #expect(await ledger.state(repoId: "org/repo", file: "a.json") == .verified)
    #expect(await ledger.state(repoId: "org/repo", file: "c.txt") == .queued)
  }

  @Test("state transitions: inflight, verified, failed")
  func stateTransitions() async {
    let tmp = TempDir()
    let ledger = DownloadLedger(baseDirectory: tmp.url)
    await ledger.register(repoId: "org/repo", files: ["w.bin"])

    await ledger.markInflight(repoId: "org/repo", file: "w.bin", taskIdentifier: 7)
    #expect(await ledger.state(repoId: "org/repo", file: "w.bin") == .inflight(taskIdentifier: 7))

    await ledger.markFailed(repoId: "org/repo", file: "w.bin", reason: "sha mismatch")
    #expect(await ledger.state(repoId: "org/repo", file: "w.bin") == .failed(reason: "sha mismatch"))

    await ledger.markVerified(repoId: "org/repo", file: "w.bin")
    #expect(await ledger.state(repoId: "org/repo", file: "w.bin") == .verified)
  }

  @Test("pendingFiles excludes verified; isRepoComplete requires all verified")
  func pendingAndCompletion() async {
    let tmp = TempDir()
    let ledger = DownloadLedger(baseDirectory: tmp.url)
    await ledger.register(repoId: "org/repo", files: ["a", "b", "c"])

    #expect(await ledger.isRepoComplete(repoId: "org/repo") == false)
    #expect(await ledger.pendingFiles(repoId: "org/repo") == ["a", "b", "c"])

    await ledger.markVerified(repoId: "org/repo", file: "a")
    await ledger.markVerified(repoId: "org/repo", file: "b")
    #expect(await ledger.pendingFiles(repoId: "org/repo") == ["c"])
    #expect(await ledger.isRepoComplete(repoId: "org/repo") == false)

    await ledger.markVerified(repoId: "org/repo", file: "c")
    #expect(await ledger.pendingFiles(repoId: "org/repo").isEmpty)
    #expect(await ledger.isRepoComplete(repoId: "org/repo") == true)
  }

  @Test("isRepoComplete is false for an unknown or empty repo")
  func completionEdgeCases() async {
    let tmp = TempDir()
    let ledger = DownloadLedger(baseDirectory: tmp.url)
    #expect(await ledger.isRepoComplete(repoId: "nope") == false)
    #expect(await ledger.pendingFiles(repoId: "nope").isEmpty)
  }

  @Test("location(forTaskIdentifier:) reverse-maps an in-flight task")
  func reverseLookupByTask() async {
    let tmp = TempDir()
    let ledger = DownloadLedger(baseDirectory: tmp.url)
    await ledger.register(repoId: "org/one", files: ["x"])
    await ledger.register(repoId: "org/two", files: ["y"])
    await ledger.markInflight(repoId: "org/two", file: "y", taskIdentifier: 42)

    let hit = await ledger.location(forTaskIdentifier: 42)
    #expect(hit?.repoId == "org/two")
    #expect(hit?.file == "y")
    #expect(await ledger.location(forTaskIdentifier: 999) == nil)
  }

  @Test("state persists across a new ledger instance (simulated relaunch)")
  func persistsAcrossRelaunch() async {
    let tmp = TempDir()

    do {
      let ledger = DownloadLedger(baseDirectory: tmp.url)
      await ledger.register(repoId: "org/repo", files: ["a", "b"])
      await ledger.markVerified(repoId: "org/repo", file: "a")
      await ledger.markInflight(repoId: "org/repo", file: "b", taskIdentifier: 5)
    }

    // A brand-new instance over the same directory == a relaunch.
    let reloaded = DownloadLedger(baseDirectory: tmp.url)
    #expect(await reloaded.state(repoId: "org/repo", file: "a") == .verified)
    #expect(await reloaded.state(repoId: "org/repo", file: "b") == .inflight(taskIdentifier: 5))
    #expect(await reloaded.location(forTaskIdentifier: 5)?.file == "b")
  }

  @Test("clear removes a repo; pruneCompletedRepos keeps in-progress repos")
  func cleanup() async {
    let tmp = TempDir()
    let ledger = DownloadLedger(baseDirectory: tmp.url)
    await ledger.register(repoId: "org/done", files: ["a"])
    await ledger.markVerified(repoId: "org/done", file: "a")
    await ledger.register(repoId: "org/busy", files: ["b"])

    await ledger.pruneCompletedRepos()
    #expect(await ledger.isRepoComplete(repoId: "org/done") == false)  // removed entirely
    #expect(await ledger.state(repoId: "org/done", file: "a") == nil)
    #expect(await ledger.state(repoId: "org/busy", file: "b") == .queued)  // kept

    await ledger.clear(repoId: "org/busy")
    #expect(await ledger.state(repoId: "org/busy", file: "b") == nil)
  }

  @Test("a corrupt ledger file loads as empty (forward progress guaranteed)")
  func corruptFileLoadsEmpty() async throws {
    let tmp = TempDir()
    let dir = tmp.url.appendingPathComponent(".acervo-downloads", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("{ not valid json".utf8).write(to: dir.appendingPathComponent("ledger.json"))

    let ledger = DownloadLedger(baseDirectory: tmp.url)
    #expect(await ledger.state(repoId: "anything", file: "x") == nil)
    // And it can still be written to normally.
    await ledger.register(repoId: "org/repo", files: ["a"])
    #expect(await ledger.state(repoId: "org/repo", file: "a") == .queued)
  }

  @Test("enqueue records URL + SHA; state changes preserve that metadata across relaunch")
  func enqueueRecordsMetadata() async {
    let tmp = TempDir()
    let url = URL(string: "https://cdn.example/models/org/repo/w.safetensors")!
    let sha = "abc123def456"

    do {
      let ledger = DownloadLedger(baseDirectory: tmp.url)
      await ledger.enqueue(repoId: "org/repo", file: "w.safetensors", remoteURL: url, expectedSHA256: sha)
      #expect(await ledger.state(repoId: "org/repo", file: "w.safetensors") == .queued)
      #expect(await ledger.expectedSHA256(repoId: "org/repo", file: "w.safetensors") == sha)
      #expect(await ledger.remoteURL(repoId: "org/repo", file: "w.safetensors") == url)

      // Advancing state must not drop the URL/SHA the delegate needs later.
      await ledger.markInflight(repoId: "org/repo", file: "w.safetensors", taskIdentifier: 3)
    }

    let reloaded = DownloadLedger(baseDirectory: tmp.url)
    #expect(await reloaded.state(repoId: "org/repo", file: "w.safetensors") == .inflight(taskIdentifier: 3))
    #expect(await reloaded.expectedSHA256(repoId: "org/repo", file: "w.safetensors") == sha)
    #expect(await reloaded.remoteURL(repoId: "org/repo", file: "w.safetensors") == url)
  }
}
