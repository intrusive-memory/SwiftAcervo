import Foundation
import Testing

@testable import SwiftAcervo

// NOTE: This test is deliberately not excluded from CI. The .timeLimit(.minutes(2)) annotation allows generous wall time. If any run approaches 5 seconds, the locking implementation needs investigation.

/// Stress concurrency tests for AcervoManager.
///
/// These tests exercise high-concurrency scenarios that go beyond the
/// standard concurrency tests. They verify deadlock-free operation under
/// load and that statistics tracking remains accurate under concurrent access.
///
/// Serialized at the suite level to avoid interference with AcervoConcurrencyTests
/// which also uses AcervoManager.shared state.
// STRESS: This suite is NOT excluded from CI but its timeLimit is generous. If wall time exceeds 5s, investigate.
@Suite("Acervo Stress Concurrency Tests", .serialized)
struct AcervoStressConcurrencyTests {

  // MARK: - 12 Concurrent Downloads of Different Models

  @Test("12 concurrent downloads of different models complete without deadlock", .timeLimit(.minutes(2)))
  func twelveConcurrentDownloadsCompleteWithoutDeadlock() async throws {
    let manager = AcervoManager.shared

    // Generate 12 unique model IDs to avoid any cross-test lock contention
    let modelIds: [String] = (0..<12).map { _ in
      let uniqueId = UUID().uuidString
      return "stress-org-\(uniqueId)/stress-model"
    }

    var completedCount = 0

    await withTaskGroup(of: Bool.self) { group in
      for modelId in modelIds {
        group.addTask { @Sendable in
          do {
            let result = try await manager.withModelAccess(modelId) { @Sendable _ -> Bool in
              return true
            }
            return result
          } catch {
            // modelDirectory validation may throw for fake IDs; treat as completed
            return false
          }
        }
      }

      for await _ in group {
        completedCount += 1
      }
    }

    // All 12 tasks must complete — no deadlock
    #expect(completedCount == 12, "All 12 concurrent downloads should complete without deadlock, got \(completedCount)")

    // Verify no locks remain held after all tasks complete
    for modelId in modelIds {
      let locked = await manager.isLocked(modelId)
      #expect(!locked, "Lock for \(modelId) should be released after completion")
    }
  }

  // MARK: - getAccessCount — 10 Concurrent Increments

  @Test("getAccessCount reflects all concurrent increments — 10 tasks")
  func getAccessCountReflectsAllConcurrentIncrements() async throws {
    let manager = AcervoManager.shared
    let uniqueId = UUID().uuidString.prefix(8)
    let modelId = "stress-org-\(uniqueId)/count-model"
    let taskCount = 10

    // Record baseline before any access
    let baseline = await manager.getAccessCount(for: modelId)

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<taskCount {
        group.addTask { @Sendable in
          do {
            let _ = try await manager.withModelAccess(modelId) { @Sendable _ -> Bool in
              return true
            }
          } catch {
            // modelDirectory validation may throw for fake IDs; access count still increments
          }
        }
      }
    }

    let finalCount = await manager.getAccessCount(for: modelId)
    #expect(
      finalCount == baseline + taskCount,
      "getAccessCount should reflect all \(taskCount) concurrent increments; expected \(baseline + taskCount), got \(finalCount)")
  }
}
