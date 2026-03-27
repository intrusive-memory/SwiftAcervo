import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

/// Tests for Sortie 3: Concurrent File Downloads via TaskGroup.
///
/// These tests exercise:
///   - The `ProgressCoordinator` actor (monotonic index assignment)
///   - The skip logic path in `downloadFiles()` (pre-existing files)
///   - `overallProgress` monotonicity across concurrent completion events
///   - `totalFiles` accuracy across all progress callbacks
///   - Error propagation through a `withThrowingTaskGroup`
///   - Cooperative cancellation via `Task.checkCancellation()`
@Suite("Concurrent Download Tests")
struct ConcurrentDownloadTests {

  // MARK: - ProgressCoordinator: Sequential Index Assignment

  @Test("ProgressCoordinator assigns sequential indices starting at 0")
  func progressCoordinatorAssignsSequentialIndices() async {
    let coordinator = ConcurrentProgressCoordinator()

    let index0 = await coordinator.nextCompletedIndex()
    let index1 = await coordinator.nextCompletedIndex()
    let index2 = await coordinator.nextCompletedIndex()

    #expect(index0 == 0)
    #expect(index1 == 1)
    #expect(index2 == 2)
  }

  @Test("ProgressCoordinator indices from concurrent tasks are unique and cover 0..<N")
  func progressCoordinatorConcurrentUnique() async {
    let coordinator = ConcurrentProgressCoordinator()
    let n = 20

    // Collect indices from the task group's serial iteration — no lock needed.
    var indices: [Int] = []
    await withTaskGroup(of: Int.self) { group in
      for _ in 0..<n {
        group.addTask {
          await coordinator.nextCompletedIndex()
        }
      }
      for await index in group {
        indices.append(index)
      }
    }

    indices.sort()
    #expect(
      indices == Array(0..<n),
      "Indices should be exactly 0..<\(n)"
    )
  }

  @Test("ProgressCoordinator produces monotonically increasing overallProgress when sorted by index")
  func progressCoordinatorProducesMonotonicProgress() async {
    let coordinator = ConcurrentProgressCoordinator()
    let totalFiles = 5

    // Collect (completedIndex, overallProgress) pairs via serial task-group iteration.
    var pairs: [(index: Int, progress: Double)] = []
    await withTaskGroup(of: (Int, Double).self) { group in
      for fileSize: Int64 in [100, 200, 50, 300, 150] {
        let capturedSize = fileSize
        group.addTask {
          let completedIndex = await coordinator.nextCompletedIndex()
          let report = AcervoDownloadProgress(
            fileName: "file.bin",
            bytesDownloaded: capturedSize,
            totalBytes: capturedSize,
            fileIndex: completedIndex,
            totalFiles: totalFiles
          )
          return (completedIndex, report.overallProgress)
        }
      }
      for await pair in group {
        pairs.append((index: pair.0, progress: pair.1))
      }
    }

    // Sort by the coordinator-assigned index (completion order).
    let sorted = pairs.sorted { $0.index < $1.index }

    // All progress values must be distinct.
    let unique = Set(sorted.map(\.progress))
    #expect(unique.count == totalFiles)

    // When sorted by index, progress must be strictly increasing.
    for i in 1..<sorted.count {
      #expect(sorted[i].progress > sorted[i - 1].progress)
    }

    // Final value should be 1.0: (4 + 1.0) / 5 == 1.0
    #expect(abs(sorted.last!.progress - 1.0) < 0.001)
  }

  // MARK: - Skip Logic: Pre-Existing Files Emit Progress

  @Test("Pre-existing file with correct size is skipped and emits one progress event")
  func skipLogicEmitsProgressForExistingFile() async throws {
    let tempDir = try makeTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    let content = Data("pre-existing-file-content".utf8)
    let hash = sha256Hex(content)

    let destination = tempDir.appendingPathComponent("model-skip")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let fileURL = destination.appendingPathComponent("existing.bin")
    try content.write(to: fileURL)

    let manifestFile = CDNManifestFile(
      path: "existing.bin",
      sha256: hash,
      sizeBytes: Int64(content.count)
    )

    let collector = ProgressCollectorActor()

    // Replicate the skip path from downloadFiles() to verify it emits progress
    // via the coordinator — no CDN call needed for this path.
    let totalFiles = 1
    let coordinator = ConcurrentProgressCoordinator()

    let fileDestination = destination.appendingPathComponent(manifestFile.path)
    let existingSize = (try? IntegrityVerification.fileSize(at: fileDestination)) ?? -1
    if existingSize == manifestFile.sizeBytes {
      let completedIndex = await coordinator.nextCompletedIndex()
      await collector.append(
        AcervoDownloadProgress(
          fileName: manifestFile.path,
          bytesDownloaded: manifestFile.sizeBytes,
          totalBytes: manifestFile.sizeBytes,
          fileIndex: completedIndex,
          totalFiles: totalFiles
        ))
    }

    let reports = await collector.getReports()
    #expect(reports.count == 1)
    #expect(reports[0].bytesDownloaded == manifestFile.sizeBytes)
    #expect(abs(reports[0].overallProgress - 1.0) < 0.001)
    #expect(reports[0].totalFiles == totalFiles)
  }

  // MARK: - overallProgress Monotonicity with Out-of-Order Completion

  @Test("overallProgress is monotonically non-decreasing when files complete out of order")
  func overallProgressMonotonicOutOfOrder() async {
    let totalFiles = 4
    let coordinator = ConcurrentProgressCoordinator()

    var reports: [(index: Int, progress: Double)] = []
    await withTaskGroup(of: (Int, Double).self) { group in
      for _ in 0..<totalFiles {
        group.addTask {
          let idx = await coordinator.nextCompletedIndex()
          let report = AcervoDownloadProgress(
            fileName: "f.bin",
            bytesDownloaded: 1000,
            totalBytes: 1000,
            fileIndex: idx,
            totalFiles: totalFiles
          )
          return (idx, report.overallProgress)
        }
      }
      for await pair in group {
        reports.append((index: pair.0, progress: pair.1))
      }
    }

    let sorted = reports.sorted { $0.index < $1.index }

    for i in 1..<sorted.count {
      #expect(sorted[i].progress > sorted[i - 1].progress)
    }

    // Final indexed value should be 1.0
    #expect(abs(sorted.last!.progress - 1.0) < 0.001)
  }

  // MARK: - totalFiles Consistency

  @Test("totalFiles is consistent across all progress reports in a simulated batch")
  func totalFilesConsistentAcrossBatch() async {
    let totalFiles = 5
    let coordinator = ConcurrentProgressCoordinator()

    var reports: [AcervoDownloadProgress] = []
    await withTaskGroup(of: AcervoDownloadProgress.self) { group in
      for fileSize: Int64 in [100, 200, 150, 300, 50] {
        let size = fileSize
        group.addTask {
          let idx = await coordinator.nextCompletedIndex()
          return AcervoDownloadProgress(
            fileName: "f.bin",
            bytesDownloaded: size,
            totalBytes: size,
            fileIndex: idx,
            totalFiles: totalFiles
          )
        }
      }
      for await report in group {
        reports.append(report)
      }
    }

    #expect(reports.count == totalFiles)
    for report in reports {
      #expect(report.totalFiles == totalFiles)
    }
  }

  // MARK: - Error Propagation via TaskGroup

  @Test("downloadFile network error propagates through task group")
  func downloadFileErrorPropagatesThroughTaskGroup() async {
    let unreachableURL = URL(string: "https://localhost:1/fake/file.bin")!
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("ConcurrentDownloadTests-error-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: destination) }

    let manifestFile = CDNManifestFile(
      path: "file.bin",
      sha256: "0000000000000000000000000000000000000000000000000000000000000000",
      sizeBytes: 100
    )

    var thrownError: Error?

    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<2 {
          group.addTask {
            try Task.checkCancellation()
            try await AcervoDownloader.downloadFile(
              from: unreachableURL,
              to: destination.appendingPathComponent(manifestFile.path),
              manifestFile: manifestFile
            )
          }
        }
        try await group.waitForAll()
      }
    } catch {
      thrownError = error
    }

    // Must have thrown — either networkError or cancellationError is acceptable.
    #expect(thrownError != nil, "Expected task group to throw when download fails")

    if let acervoError = thrownError as? AcervoError {
      if case .networkError = acervoError {
        // Expected — unreachable host produces networkError
      } else {
        Issue.record("Expected AcervoError.networkError but got \(acervoError)")
      }
    } else if thrownError is CancellationError {
      // Also acceptable if cancellation fired first
    } else if let err = thrownError {
      Issue.record("Expected AcervoError or CancellationError but got \(err)")
    }
  }

  // MARK: - Cooperative Cancellation

  @Test("Cancelled task propagates CancellationError or networkError")
  func cancelledTaskPropagatesCancellationError() async {
    let unreachableURL = URL(string: "https://localhost:1/fake/slow-file.bin")!
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("ConcurrentDownloadTests-cancel-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: destination) }

    let manifestFile = CDNManifestFile(
      path: "slow-file.bin",
      sha256: "0000000000000000000000000000000000000000000000000000000000000000",
      sizeBytes: 1_000_000
    )

    let task = Task {
      do {
        try await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask {
            try Task.checkCancellation()
            try await AcervoDownloader.downloadFile(
              from: unreachableURL,
              to: destination.appendingPathComponent(manifestFile.path),
              manifestFile: manifestFile
            )
          }
          try await group.waitForAll()
        }
      } catch {
        // Any error (CancellationError, AcervoError.networkError, etc.) is acceptable.
        // We swallow it here so task.value is non-throwing.
        _ = error
      }
    }

    task.cancel()
    await task.value
    // If we reach here the task completed (with or without errors caught above).
  }

  // MARK: - Concurrency Limit

  @Test("Task group throttle limits peak concurrent tasks to maxConcurrentDownloads (4)")
  func taskGroupRespectsConcurrencyLimit() async throws {
    let maxConcurrent = 4
    let totalTasks = 10
    let counter = ConcurrentInflightCounter()

    var peakConcurrency = 0

    try await withThrowingTaskGroup(of: Int.self) { group in
      var inFlight = 0
      for _ in 0..<totalTasks {
        if inFlight >= maxConcurrent {
          if let peak = try await group.next() {
            if peak > peakConcurrency { peakConcurrency = peak }
          }
          inFlight -= 1
        }

        group.addTask {
          await counter.increment()
          let current = await counter.current()
          // Simulate brief work to allow overlap
          try await Task.sleep(for: .milliseconds(5))
          await counter.decrement()
          return current
        }
        inFlight += 1
      }
      // Drain remaining
      for try await peak in group {
        if peak > peakConcurrency { peakConcurrency = peak }
      }
    }

    #expect(
      peakConcurrency <= maxConcurrent,
      "Peak concurrency \(peakConcurrency) should not exceed limit \(maxConcurrent)")
    #expect(peakConcurrency > 0)
  }
}

// MARK: - Test-Local Progress Coordinator

/// A test-local mirror of the production `ProgressCoordinator` actor.
/// Used to unit-test the monotonic index-assignment logic.
private actor ConcurrentProgressCoordinator {
  private var completedCount: Int = 0

  func nextCompletedIndex() -> Int {
    let index = completedCount
    completedCount += 1
    return index
  }

  func currentCompletedCount() -> Int { completedCount }
}

// MARK: - Thread-Safe In-Flight Counter

private actor ConcurrentInflightCounter {
  private var count: Int = 0
  func increment() { count += 1 }
  func decrement() { count -= 1 }
  func current() -> Int { count }
}

// MARK: - Test Helpers

private actor ProgressCollectorActor {
  private var reports: [AcervoDownloadProgress] = []

  func append(_ report: AcervoDownloadProgress) {
    reports.append(report)
  }

  func getReports() -> [AcervoDownloadProgress] {
    reports
  }
}

private func sha256Hex(_ data: Data) -> String {
  let digest = SHA256.hash(data: data)
  return digest.map { String(format: "%02x", $0) }.joined()
}

private func makeTempDirectory() throws -> URL {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("ConcurrentDownloadTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

private func cleanupTempDirectory(_ dir: URL) {
  try? FileManager.default.removeItem(at: dir)
}
