// Companion tests for Sources/SwiftAcervo/DownloadFinalizer.swift
//
// Verifies the pure file-installation step used by the iOS background download
// delegate (#81): SHA-256 verification + atomic move into the model directory.
// No URLSession — runs on macOS CI against a temp directory.

import Foundation
import Testing

@testable import SwiftAcervo

@Suite("DownloadFinalizerTests")
struct DownloadFinalizerTests {

  private final class TempDir {
    let url: URL
    init() {
      url = FileManager.default.temporaryDirectory
        .appendingPathComponent("acervo-finalizer-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
  }

  private func writeDelivered(_ tmp: TempDir, _ contents: String) throws -> URL {
    let url = tmp.url.appendingPathComponent("delivered-\(UUID().uuidString).tmp")
    try Data(contents.utf8).write(to: url)
    return url
  }

  @Test("moves the delivered file into place (creating parents) when SHA matches")
  func finalizeSuccess() throws {
    let tmp = TempDir()
    let delivered = try writeDelivered(tmp, "hello world")
    let sha = try IntegrityVerification.sha256(of: delivered)
    // Destination is nested to prove parent directories are created.
    let dest = tmp.url.appendingPathComponent("model/weights/w.safetensors")

    try DownloadFinalizer.finalize(deliveredFile: delivered, destination: dest, expectedSHA256: sha)

    #expect(FileManager.default.fileExists(atPath: dest.path))
    #expect(FileManager.default.fileExists(atPath: delivered.path) == false)  // consumed
    #expect(try Data(contentsOf: dest) == Data("hello world".utf8))
  }

  @Test("nil expected SHA skips verification and still installs the file")
  func finalizeNilSHA() throws {
    let tmp = TempDir()
    let delivered = try writeDelivered(tmp, "no checksum")
    let dest = tmp.url.appendingPathComponent("model/config.json")

    try DownloadFinalizer.finalize(deliveredFile: delivered, destination: dest, expectedSHA256: nil)

    #expect(FileManager.default.fileExists(atPath: dest.path))
    #expect(try Data(contentsOf: dest) == Data("no checksum".utf8))
  }

  @Test("SHA mismatch deletes the delivered file, throws, and leaves destination untouched")
  func finalizeMismatch() throws {
    let tmp = TempDir()
    let delivered = try writeDelivered(tmp, "corrupt payload")
    let dest = tmp.url.appendingPathComponent("model/w.safetensors")

    #expect(throws: AcervoError.self) {
      try DownloadFinalizer.finalize(
        deliveredFile: delivered,
        destination: dest,
        expectedSHA256: "0000000000000000000000000000000000000000000000000000000000000000"
      )
    }

    #expect(FileManager.default.fileExists(atPath: delivered.path) == false)  // deleted
    #expect(FileManager.default.fileExists(atPath: dest.path) == false)  // untouched
  }

  @Test("replaces an existing file already present at the destination")
  func finalizeReplacesExisting() throws {
    let tmp = TempDir()
    let dest = tmp.url.appendingPathComponent("model/w.bin")
    try FileManager.default.createDirectory(
      at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("stale".utf8).write(to: dest)

    let delivered = try writeDelivered(tmp, "fresh")
    let sha = try IntegrityVerification.sha256(of: delivered)

    try DownloadFinalizer.finalize(deliveredFile: delivered, destination: dest, expectedSHA256: sha)

    #expect(try Data(contentsOf: dest) == Data("fresh".utf8))
  }
}
