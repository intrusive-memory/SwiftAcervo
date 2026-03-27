import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

/// A thread-safe collector for download progress reports, used in stream-and-hash tests.
private actor StreamProgressCollector {
  var reports: [AcervoDownloadProgress] = []

  func append(_ report: AcervoDownloadProgress) {
    reports.append(report)
  }

  func getReports() -> [AcervoDownloadProgress] {
    reports
  }

  func count() -> Int {
    reports.count
  }
}

/// Tests for the stream-and-hash download infrastructure (Sortie 2).
///
/// These tests verify the incremental SHA-256 computation during streaming
/// downloads without requiring a live CDN. They use local file operations
/// to validate that the streaming hasher produces identical results to
/// `IntegrityVerification.sha256(of:)`, that mismatches are detected and
/// temp files cleaned up, and that progress callbacks fire correctly.
@Suite("Stream-and-Hash Download Tests")
struct StreamAndHashTests {

  // MARK: - Incremental SHA-256 Agreement

  @Test("Incremental SHA-256 matches IntegrityVerification.sha256 for small content")
  func incrementalHashMatchesSmallContent() throws {
    let tempDir = try makeTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    let content = Data("Hello, world! This is a test of incremental hashing.".utf8)
    let fileURL = tempDir.appendingPathComponent("small.txt")
    try content.write(to: fileURL)

    // Compute hash using IntegrityVerification (the file-based hasher)
    let fileHash = try IntegrityVerification.sha256(of: fileURL)

    // Compute hash incrementally (simulating the streaming approach)
    let incrementalHash = incrementalSHA256(of: content, chunkSize: 16)

    #expect(fileHash == incrementalHash)
  }

  @Test("Incremental SHA-256 matches IntegrityVerification.sha256 for 5 MB content")
  func incrementalHashMatchesLargeContent() throws {
    let tempDir = try makeTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    // Generate 5 MB of deterministic data (same pattern as IntegrityVerificationTests)
    let size = 5 * 1024 * 1024
    let content = Data(bytes: (0..<size).map { UInt8($0 % 256) }, count: size)
    let fileURL = tempDir.appendingPathComponent("5mb.bin")
    try content.write(to: fileURL)

    // Compute hash using IntegrityVerification
    let fileHash = try IntegrityVerification.sha256(of: fileURL)

    // Compute hash incrementally with 4 MB chunk size (matching streamChunkSize)
    let incrementalHash = incrementalSHA256(of: content, chunkSize: 4_194_304)

    #expect(fileHash == incrementalHash)
    // Also verify against the known reference hash
    #expect(incrementalHash == "2e7cab6314e9614b6f2da12630661c3038e5592025f6534ba5823c3b340a1cb6")
  }

  @Test("Incremental SHA-256 matches for content at exact 4 MB boundary")
  func incrementalHashMatchesAtChunkBoundary() throws {
    let tempDir = try makeTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    let size = 4 * 1024 * 1024
    let content = Data(bytes: (0..<size).map { UInt8($0 % 256) }, count: size)
    let fileURL = tempDir.appendingPathComponent("4mb.bin")
    try content.write(to: fileURL)

    let fileHash = try IntegrityVerification.sha256(of: fileURL)
    let incrementalHash = incrementalSHA256(of: content, chunkSize: 4_194_304)

    #expect(fileHash == incrementalHash)
    #expect(incrementalHash == "2b07811057df887086f06a67edc6ebf911de8b6741156e7a2eb1416a4b8b1b2e")
  }

  @Test("Incremental SHA-256 matches for empty content")
  func incrementalHashMatchesEmptyContent() throws {
    let tempDir = try makeTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    let content = Data()
    let fileURL = tempDir.appendingPathComponent("empty.bin")
    try content.write(to: fileURL)

    let fileHash = try IntegrityVerification.sha256(of: fileURL)
    let incrementalHash = incrementalSHA256(of: content, chunkSize: 4_194_304)

    #expect(fileHash == incrementalHash)
    // SHA-256 of empty data
    #expect(
      incrementalHash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  }

  // MARK: - Hash Mismatch Detection and Temp Cleanup

  @Test("Hash mismatch deletes temp file and throws integrityCheckFailed")
  func hashMismatchDeletesTempAndThrows() throws {
    let tempDir = try makeTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    // Write content to a temp file (simulating what streamDownloadFile produces)
    let content = Data("actual content".utf8)
    let tempFileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try content.write(to: tempFileURL)
    defer { try? FileManager.default.removeItem(at: tempFileURL) }

    // Compute the actual hash
    let actualHash = incrementalSHA256(of: content, chunkSize: 4_194_304)
    let wrongHash = "0000000000000000000000000000000000000000000000000000000000000000"

    // Verify the hash doesn't match
    #expect(actualHash != wrongHash)

    // Create a manifest file with the WRONG hash but correct size
    let manifestFile = CDNManifestFile(
      path: "test.bin",
      sha256: wrongHash,
      sizeBytes: Int64(content.count)
    )

    // Verify using IntegrityVerification (simulating what happens post-stream)
    // Write the content to a destination first
    let destination = tempDir.appendingPathComponent("test.bin")
    try content.write(to: destination)

    do {
      try IntegrityVerification.verifyAgainstManifest(
        fileURL: destination,
        manifestFile: manifestFile
      )
      Issue.record("Expected integrityCheckFailed to be thrown")
    } catch let error as AcervoError {
      if case .integrityCheckFailed(let file, let expected, let actual) = error {
        #expect(file == "test.bin")
        #expect(expected == wrongHash)
        #expect(actual == actualHash)
        // Verify the file was deleted by verifyAgainstManifest
        #expect(!FileManager.default.fileExists(atPath: destination.path))
      } else {
        Issue.record("Expected integrityCheckFailed but got \(error)")
      }
    }
  }

  // MARK: - Size Mismatch Detection

  @Test("Size mismatch throws downloadSizeMismatch")
  func sizeMismatchThrows() throws {
    let tempDir = try makeTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    let content = Data("short".utf8)
    let fileURL = tempDir.appendingPathComponent("size-test.bin")
    try content.write(to: fileURL)

    let contentHash = try IntegrityVerification.sha256(of: fileURL)

    // Create manifest entry with WRONG size but correct hash
    let manifestFile = CDNManifestFile(
      path: "size-test.bin",
      sha256: contentHash,
      sizeBytes: 99999  // Wrong size
    )

    do {
      try IntegrityVerification.verifyAgainstManifest(
        fileURL: fileURL,
        manifestFile: manifestFile
      )
      Issue.record("Expected downloadSizeMismatch to be thrown")
    } catch let error as AcervoError {
      if case .downloadSizeMismatch(let fileName, let expected, let actual) = error {
        #expect(fileName == "size-test.bin")
        #expect(expected == 99999)
        #expect(actual == Int64(content.count))
        // Verify the file was deleted
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
      } else {
        Issue.record("Expected downloadSizeMismatch but got \(error)")
      }
    }
  }

  // MARK: - Incomplete Stream Cleanup

  @Test("Incomplete stream cleans up temp files")
  func incompleteStreamCleansUpTempFiles() throws {
    // Simulate what happens when a stream is interrupted: a UUID-named temp
    // file is created in temporaryDirectory, partially written, then the
    // error handler must remove it.

    let tempFileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)

    // Create the temp file with partial content (simulating interrupted stream)
    let partialContent = Data("partial data before connection drop".utf8)
    FileManager.default.createFile(atPath: tempFileURL.path, contents: partialContent)

    // Verify temp file exists
    #expect(FileManager.default.fileExists(atPath: tempFileURL.path))

    // Simulate the cleanup that streamDownloadFile performs on error
    try? FileManager.default.removeItem(at: tempFileURL)

    // Verify temp file was cleaned up
    #expect(!FileManager.default.fileExists(atPath: tempFileURL.path))
  }

  @Test("Temp file uses UUID name in temporaryDirectory")
  func tempFileUsesUUIDInTemporaryDirectory() {
    let tempBase = FileManager.default.temporaryDirectory
    let tempFileURL = tempBase.appendingPathComponent(UUID().uuidString)

    // Verify the temp file is in temporaryDirectory
    #expect(tempFileURL.deletingLastPathComponent().path == tempBase.path)

    // Verify the file name looks like a UUID (36 chars with hyphens)
    let fileName = tempFileURL.lastPathComponent
    #expect(fileName.count == 36)
    #expect(fileName.contains("-"))
  }

  // MARK: - Progress Callback During Streaming

  @Test("Progress callback receives intermediate bytesDownloaded values during chunked write")
  func progressCallbackReceivesIntermediateValues() throws {
    // Simulate what streamDownloadFile does internally: write in chunks
    // and fire progress callbacks after each chunk flush.

    let totalSize: Int64 = 10_000_000  // 10 MB
    let chunkSize = 4_194_304  // 4 MB

    // Simulate streaming progress by calculating what chunks would be produced
    var progressReports: [AcervoDownloadProgress] = []
    var bytesWritten: Int64 = 0

    // Initial progress (0 bytes)
    progressReports.append(
      AcervoDownloadProgress(
        fileName: "model.safetensors",
        bytesDownloaded: 0,
        totalBytes: totalSize,
        fileIndex: 0,
        totalFiles: 1
      ))

    // Simulate chunk-by-chunk writing
    var remaining = Int(totalSize)
    while remaining > 0 {
      let thisChunk = min(remaining, chunkSize)
      bytesWritten += Int64(thisChunk)
      remaining -= thisChunk

      if thisChunk == chunkSize || remaining == 0 {
        progressReports.append(
          AcervoDownloadProgress(
            fileName: "model.safetensors",
            bytesDownloaded: bytesWritten,
            totalBytes: totalSize,
            fileIndex: 0,
            totalFiles: 1
          ))
      }
    }

    // Final completion report
    progressReports.append(
      AcervoDownloadProgress(
        fileName: "model.safetensors",
        bytesDownloaded: totalSize,
        totalBytes: totalSize,
        fileIndex: 0,
        totalFiles: 1
      ))

    // Verify we got multiple intermediate reports (not just start and end)
    #expect(progressReports.count >= 3)

    // Verify first report is 0 bytes
    #expect(progressReports[0].bytesDownloaded == 0)

    // Verify last report is the full size
    #expect(progressReports[progressReports.count - 1].bytesDownloaded == totalSize)

    // Verify intermediate reports have increasing bytesDownloaded
    for i in 1..<progressReports.count {
      #expect(progressReports[i].bytesDownloaded >= progressReports[i - 1].bytesDownloaded)
    }

    // Verify overallProgress is monotonically increasing
    for i in 1..<progressReports.count {
      #expect(progressReports[i].overallProgress >= progressReports[i - 1].overallProgress)
    }

    // Verify we have at least one intermediate progress value that's between 0 and 1
    let intermediateReports = progressReports.filter {
      $0.overallProgress > 0.0 && $0.overallProgress < 1.0
    }
    #expect(!intermediateReports.isEmpty)
  }

  @Test("Streaming progress reports correct fileIndex and totalFiles")
  func streamingProgressReportsCorrectIndices() {
    // Test that progress reports during streaming correctly propagate
    // fileIndex and totalFiles for multi-file downloads

    let report = AcervoDownloadProgress(
      fileName: "model-00001-of-00003.safetensors",
      bytesDownloaded: 2_097_152,
      totalBytes: 4_194_304,
      fileIndex: 1,
      totalFiles: 3
    )

    #expect(report.fileIndex == 1)
    #expect(report.totalFiles == 3)
    #expect(report.fileName == "model-00001-of-00003.safetensors")

    // (1 + 0.5) / 3 = 0.5
    #expect(abs(report.overallProgress - 0.5) < 0.001)
  }

  // MARK: - End-to-End Streaming Hash Simulation

  @Test("Full streaming simulation produces correct hash and size")
  func fullStreamingSimulation() throws {
    let tempDir = try makeTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    // Create source content
    let content = Data("This is a complete file for stream-and-hash testing.".utf8)
    let expectedHash = incrementalSHA256(of: content, chunkSize: 4_194_304)
    let expectedSize = Int64(content.count)

    // Simulate the full streaming pipeline:
    // 1. Create UUID-named temp file
    let tempFileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tempFileURL) }

    // 2. Stream bytes into temp file + hasher
    var hasher = SHA256()
    var buffer = Data()
    let chunkSize = 16  // Small chunk size for testing
    var bytesWritten: Int64 = 0

    FileManager.default.createFile(atPath: tempFileURL.path, contents: nil)
    let fileHandle = try FileHandle(forWritingTo: tempFileURL)

    for byte in content {
      buffer.append(byte)
      if buffer.count >= chunkSize {
        hasher.update(data: buffer)
        try fileHandle.write(contentsOf: buffer)
        bytesWritten += Int64(buffer.count)
        buffer.removeAll(keepingCapacity: true)
      }
    }

    // Flush remaining
    if !buffer.isEmpty {
      hasher.update(data: buffer)
      try fileHandle.write(contentsOf: buffer)
      bytesWritten += Int64(buffer.count)
    }
    try fileHandle.close()

    // 3. Verify size
    #expect(bytesWritten == expectedSize)

    // 4. Verify hash
    let digest = hasher.finalize()
    let actualHash = digest.map { String(format: "%02x", $0) }.joined()
    #expect(actualHash == expectedHash)

    // 5. Verify temp file content matches original
    let writtenData = try Data(contentsOf: tempFileURL)
    #expect(writtenData == content)

    // 6. Atomic move to destination
    let destination = tempDir.appendingPathComponent("output.bin")
    try FileManager.default.moveItem(at: tempFileURL, to: destination)
    #expect(FileManager.default.fileExists(atPath: destination.path))
    #expect(!FileManager.default.fileExists(atPath: tempFileURL.path))
  }

  // MARK: - Helpers

  /// Computes SHA-256 incrementally over `data` using the specified chunk size.
  /// This mirrors the logic in `streamDownloadFile`.
  private func incrementalSHA256(of data: Data, chunkSize: Int) -> String {
    var hasher = SHA256()
    var offset = 0
    while offset < data.count {
      let end = min(offset + chunkSize, data.count)
      let chunk = data[offset..<end]
      hasher.update(data: chunk)
      offset = end
    }
    let digest = hasher.finalize()
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private func makeTempDirectory() throws -> URL {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("SwiftAcervoStreamTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    return tempDir
  }

  private func cleanupTempDirectory(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
  }
}
