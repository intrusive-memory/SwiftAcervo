import Testing
import Foundation
@testable import SwiftAcervo

/// Concurrency stress tests for AcervoManager.
///
/// Verifies that per-model locking correctly serializes same-model operations
/// while allowing different-model operations to proceed independently.
/// Uses `AcervoManager.shared` with unique model IDs per test for isolation.
///
/// Serialized at the suite level because tests share `AcervoManager.shared` state.
@Suite("Acervo Concurrency Tests", .serialized)
struct AcervoConcurrencyTests {

    // MARK: - 10 Concurrent Downloads of Different Models

    @Test("10 concurrent accesses of different models complete independently")
    func tenDifferentModelsCompleteIndependently() async throws {
        let manager = AcervoManager.shared
        let uniqueId = UUID().uuidString.prefix(8)
        let modelCount = 10

        let tracker = ConcurrencyTracker()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<modelCount {
                let modelId = "stress-org-\(uniqueId)/diff-model-\(i)"
                group.addTask { @Sendable in
                    do {
                        let _ = try await manager.withModelAccess(modelId) { @Sendable url -> String in
                            tracker.recordStart(modelId)
                            Thread.sleep(forTimeInterval: 0.02)
                            tracker.recordEnd(modelId)
                            return url.lastPathComponent
                        }
                    } catch {
                        // modelDirectory validation may throw; that's fine
                    }
                }
            }
        }

        // All 10 models should have been accessed
        let completedCount = tracker.completedCount()
        #expect(completedCount == modelCount,
                "All \(modelCount) different-model accesses should complete, got \(completedCount)")

        // Verify no locks remain held
        for i in 0..<modelCount {
            let modelId = "stress-org-\(uniqueId)/diff-model-\(i)"
            let locked = await manager.isLocked(modelId)
            #expect(!locked, "Lock for \(modelId) should be released")
        }
    }

    @Test("Different-model operations do not contend on locks")
    func differentModelsDoNotContendOnLocks() async throws {
        let manager = AcervoManager.shared
        let uniqueId = UUID().uuidString.prefix(8)
        let modelCount = 10

        // Launch 10 concurrent operations on different models.
        // Since each model has its own lock, none should wait for another.
        // We verify this by checking that all complete successfully and
        // no cross-model lock contention occurs (all locks released).
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<modelCount {
                let modelId = "stress-org-\(uniqueId)/no-contention-\(i)"
                group.addTask { @Sendable in
                    do {
                        let _ = try await manager.withModelAccess(modelId) { @Sendable _ -> Bool in
                            return true
                        }
                    } catch {}
                }
            }
        }

        // All locks should be released -- no deadlocks or cross-model contention
        for i in 0..<modelCount {
            let modelId = "stress-org-\(uniqueId)/no-contention-\(i)"
            let locked = await manager.isLocked(modelId)
            #expect(!locked, "Lock for model \(i) should be released (no cross-model contention)")
        }
    }

    // MARK: - 10 Concurrent Accesses to Same Model (Serialized)

    @Test("10 concurrent accesses to the same model are serialized")
    func tenSameModelAccessesSerialized() async throws {
        let manager = AcervoManager.shared
        let uniqueId = UUID().uuidString.prefix(8)
        let modelId = "stress-org-\(uniqueId)/same-model"
        let accessCount = 10
        let workDuration: TimeInterval = 0.02

        let tracker = ConcurrencyTracker()

        let start = ContinuousClock.now

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<accessCount {
                group.addTask { @Sendable in
                    do {
                        let _ = try await manager.withModelAccess(modelId) { @Sendable _ -> Int in
                            tracker.recordStart("access-\(i)")
                            Thread.sleep(forTimeInterval: workDuration)
                            tracker.recordEnd("access-\(i)")
                            return i
                        }
                    } catch {}
                }
            }
        }

        let elapsed = ContinuousClock.now - start

        // All 10 accesses should have completed
        let completedCount = tracker.completedCount()
        #expect(completedCount == accessCount,
                "All \(accessCount) same-model accesses should complete, got \(completedCount)")

        // Serialized: total time should be at least 80% of (accessCount * workDuration)
        // to prove they were not fully parallel.
        let minimumExpected: Duration = .milliseconds(Int(workDuration * Double(accessCount) * 1000 * 0.8))
        #expect(elapsed >= minimumExpected,
                "Same-model operations (\(elapsed)) should take at least \(minimumExpected) (serialized)")

        // Verify no overlapping execution by checking the tracker
        let maxConcurrent = tracker.maxConcurrency()
        #expect(maxConcurrent <= 1,
                "Same-model operations should not overlap; max concurrency was \(maxConcurrent)")

        // Lock should be released
        let locked = await manager.isLocked(modelId)
        #expect(!locked, "Lock should be released after all accesses complete")
    }

    // MARK: - Interleaved Downloads and Accesses

    @Test("Interleaved downloads and accesses to mixed models work correctly")
    func interleavedDownloadsAndAccesses() async throws {
        let manager = AcervoManager.shared
        let uniqueId = UUID().uuidString.prefix(8)
        let sharedModelId = "stress-org-\(uniqueId)/shared-model"

        let tracker = ConcurrencyTracker()

        await withTaskGroup(of: Void.self) { group in
            // 3 accesses to the same model (should serialize with each other)
            for i in 0..<3 {
                group.addTask { @Sendable in
                    do {
                        let _ = try await manager.withModelAccess(sharedModelId) { @Sendable _ -> String in
                            tracker.recordStart("shared-access-\(i)")
                            Thread.sleep(forTimeInterval: 0.02)
                            tracker.recordEnd("shared-access-\(i)")
                            return "done"
                        }
                    } catch {}
                }
            }

            // 3 downloads of different models (should proceed independently)
            for i in 0..<3 {
                let differentModelId = "stress-org-\(uniqueId)/different-\(i)"
                group.addTask { @Sendable in
                    do {
                        try await manager.download(
                            differentModelId,
                            files: ["config.json"]
                        )
                    } catch {
                        // Network error expected for fake model IDs
                    }
                    tracker.recordStart("download-\(i)")
                    tracker.recordEnd("download-\(i)")
                }
            }

            // 2 more accesses to different unique models
            for i in 0..<2 {
                let uniqueModelId = "stress-org-\(uniqueId)/unique-access-\(i)"
                group.addTask { @Sendable in
                    do {
                        let _ = try await manager.withModelAccess(uniqueModelId) { @Sendable _ -> Bool in
                            tracker.recordStart("unique-access-\(i)")
                            Thread.sleep(forTimeInterval: 0.01)
                            tracker.recordEnd("unique-access-\(i)")
                            return true
                        }
                    } catch {}
                }
            }
        }

        // All 8 operations should have completed
        let completedCount = tracker.completedCount()
        #expect(completedCount == 8,
                "All 8 interleaved operations should complete, got \(completedCount)")

        // Verify all locks are released
        let sharedLocked = await manager.isLocked(sharedModelId)
        #expect(!sharedLocked, "Shared model lock should be released")

        for i in 0..<3 {
            let locked = await manager.isLocked("stress-org-\(uniqueId)/different-\(i)")
            #expect(!locked, "Different model \(i) lock should be released")
        }

        for i in 0..<2 {
            let locked = await manager.isLocked("stress-org-\(uniqueId)/unique-access-\(i)")
            #expect(!locked, "Unique access model \(i) lock should be released")
        }
    }

    @Test("Concurrent accesses to same model track statistics correctly")
    func concurrentAccessesTrackStatistics() async throws {
        let manager = AcervoManager.shared
        let uniqueId = UUID().uuidString.prefix(8)
        let modelId = "stress-org-\(uniqueId)/stats-model"
        let accessCount = 5

        // Record baseline
        let baseLine = await manager.getAccessCount(for: modelId)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<accessCount {
                group.addTask { @Sendable in
                    do {
                        let _ = try await manager.withModelAccess(modelId) { @Sendable _ -> Bool in
                            return true
                        }
                    } catch {
                        // modelDirectory may throw; OK for stats test
                    }
                }
            }
        }

        let finalCount = await manager.getAccessCount(for: modelId)
        #expect(finalCount == baseLine + accessCount,
                "Access count should increment by \(accessCount), got \(finalCount - baseLine)")
    }
}

// MARK: - Test Helper

/// Thread-safe concurrency tracker for stress tests.
/// Records start/end events and calculates max concurrency to detect overlapping execution.
private final class ConcurrencyTracker: @unchecked Sendable {

    private let lock = NSLock()
    private var _starts: [String: ContinuousClock.Instant] = [:]
    private var _ends: [String: ContinuousClock.Instant] = [:]
    private var _activeCount: Int = 0
    private var _maxActive: Int = 0

    func recordStart(_ label: String) {
        lock.lock()
        _starts[label] = .now
        _activeCount += 1
        if _activeCount > _maxActive {
            _maxActive = _activeCount
        }
        lock.unlock()
    }

    func recordEnd(_ label: String) {
        lock.lock()
        _ends[label] = .now
        _activeCount -= 1
        lock.unlock()
    }

    func completedCount() -> Int {
        lock.lock()
        let count = _ends.count
        lock.unlock()
        return count
    }

    func maxConcurrency() -> Int {
        lock.lock()
        let max = _maxActive
        lock.unlock()
        return max
    }
}
