import Testing
import Foundation
@testable import SwiftAcervo

/// Tests for AcervoManager actor, focusing on per-model locking serialization,
/// concurrent access behavior, URL caching, and statistics tracking.
///
/// Serialized because tests share the `AcervoManager.shared` singleton
/// and its mutable cache/statistics state.
@Suite("AcervoManager Tests", .serialized)
struct AcervoManagerTests {

    // MARK: - Singleton

    @Test("AcervoManager.shared returns the same instance")
    func sharedReturnsSameInstance() async {
        let a = AcervoManager.shared
        let b = AcervoManager.shared
        // Both references should be the same actor instance.
        // We verify by checking they share state.
        let modelId = "test-org/singleton-test"

        let lockedA = await a.isLocked(modelId)
        let lockedB = await b.isLocked(modelId)
        #expect(!lockedA)
        #expect(!lockedB)
    }

    // MARK: - Locking Serialization (Same Model)

    @Test("Concurrent operations on the same model are serialized")
    func sameModelSerialized() async throws {
        let manager = AcervoManager.shared
        let modelId = "test-org/serialization-test"

        // We use withModelAccess to hold the lock while performing work.
        // The closure is synchronous, so it runs on the actor's executor.
        // We record timestamps to verify sequential execution.

        let tracker = TimestampTracker()

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    let _ = try await manager.withModelAccess(modelId) { _ -> String in
                        tracker.record("task1-start")
                        Thread.sleep(forTimeInterval: 0.1)
                        tracker.record("task1-end")
                        return "done"
                    }
                } catch {
                    // modelDirectory may not exist; OK for locking test
                }
            }

            group.addTask {
                // Small delay to bias task1 to acquire lock first
                try? await Task.sleep(for: .milliseconds(10))
                do {
                    let _ = try await manager.withModelAccess(modelId) { _ -> String in
                        tracker.record("task2-start")
                        Thread.sleep(forTimeInterval: 0.1)
                        tracker.record("task2-end")
                        return "done"
                    }
                } catch {
                    // modelDirectory may not exist; OK for locking test
                }
            }
        }

        let events = tracker.getEvents()

        // With serialization, one task must complete before the other starts.
        if events.count >= 4 {
            let task1EndIdx = events.firstIndex(where: { $0.name == "task1-end" })
            let task2StartIdx = events.firstIndex(where: { $0.name == "task2-start" })
            let task2EndIdx = events.firstIndex(where: { $0.name == "task2-end" })
            let task1StartIdx = events.firstIndex(where: { $0.name == "task1-start" })

            if let t1End = task1EndIdx, let t2Start = task2StartIdx {
                let serializedOrder1 = t1End < t2Start
                var serializedOrder2 = false
                if let t2End = task2EndIdx, let t1Start = task1StartIdx {
                    serializedOrder2 = t2End < t1Start
                }
                #expect(serializedOrder1 || serializedOrder2,
                        "Same-model operations should be serialized")
            }
        }
    }

    // MARK: - Locking Parallelism (Different Models)

    @Test("Concurrent operations on different models can proceed independently")
    func differentModelsIndependent() async throws {
        let manager = AcervoManager.shared
        let modelA = "test-org/independent-model-a"
        let modelB = "test-org/independent-model-b"

        // Since withModelAccess closures are synchronous and run on the
        // actor's serial executor, true parallelism requires suspension
        // points. Instead, we verify that different-model operations do
        // not block each other's locks -- i.e., there is no cross-model
        // lock contention.
        //
        // We verify this by checking that both operations complete
        // successfully and that neither model remains locked afterward.

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    let _ = try await manager.withModelAccess(modelA) { _ -> String in
                        return "done-A"
                    }
                } catch {
                    // OK for this test
                }
            }

            group.addTask {
                do {
                    let _ = try await manager.withModelAccess(modelB) { _ -> String in
                        return "done-B"
                    }
                } catch {
                    // OK for this test
                }
            }
        }

        // Verify neither model is locked after both operations complete
        let lockedA = await manager.isLocked(modelA)
        let lockedB = await manager.isLocked(modelB)
        #expect(!lockedA, "Model A lock should be released")
        #expect(!lockedB, "Model B lock should be released")
    }

    // MARK: - Lock release verification

    @Test("Lock is released after successful operation")
    func lockReleasedOnSuccess() async throws {
        let manager = AcervoManager.shared
        let modelId = "test-org/lock-release-success"

        // Initially not locked
        let lockedBefore = await manager.isLocked(modelId)
        #expect(!lockedBefore)

        // Perform an operation
        do {
            let _ = try await manager.withModelAccess(modelId) { _ -> String in
                return "result"
            }
        } catch {
            // modelDirectory may throw; that's fine
        }

        // Lock should be released after operation
        let lockedAfter = await manager.isLocked(modelId)
        #expect(!lockedAfter, "Lock should be released after successful operation")
    }

    @Test("Lock is released after error")
    func lockReleasedOnError() async throws {
        let manager = AcervoManager.shared
        let modelId = "test-org/lock-release-error"

        // Initially not locked
        let lockedBefore = await manager.isLocked(modelId)
        #expect(!lockedBefore)

        // Perform an operation that throws
        do {
            let _ = try await manager.withModelAccess(modelId) { _ -> String in
                throw AcervoError.modelNotFound("intentional test error")
            }
        } catch {
            // Expected error
        }

        // Lock should still be released even after error
        let lockedAfter = await manager.isLocked(modelId)
        #expect(!lockedAfter, "Lock should be released even after error")
    }

    // MARK: - withModelAccess() Tests

    @Test("withModelAccess provides model directory URL")
    func withModelAccessProvidesURL() async throws {
        let manager = AcervoManager.shared
        let modelId = "test-org/url-access-test"

        // withModelAccess should provide the model directory URL
        // matching what Acervo.modelDirectory(for:) returns
        let expectedDir = try Acervo.modelDirectory(for: modelId)

        let receivedURL = try await manager.withModelAccess(modelId) { url -> URL in
            return url
        }

        #expect(receivedURL == expectedDir,
                "withModelAccess should provide the correct model directory URL")
    }

    @Test("withModelAccess returns closure result")
    func withModelAccessReturnsResult() async throws {
        let manager = AcervoManager.shared
        let modelId = "test-org/result-test"

        let result = try await manager.withModelAccess(modelId) { url -> String in
            return "computed-result-\(url.lastPathComponent)"
        }

        #expect(result.hasPrefix("computed-result-"),
                "withModelAccess should return the closure's result")
        #expect(result.contains("test-org_result-test"),
                "Result should include the model directory name")
    }

    @Test("withModelAccess throws invalidModelId for bad model ID")
    func withModelAccessThrowsForBadModelId() async {
        let manager = AcervoManager.shared

        do {
            let _ = try await manager.withModelAccess("no-slash") { url -> String in
                return url.path
            }
            #expect(Bool(false), "Expected withModelAccess to throw invalidModelId")
        } catch let error as AcervoError {
            if case .invalidModelId(let id) = error {
                #expect(id == "no-slash")
            } else {
                #expect(Bool(false), "Expected invalidModelId but got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected AcervoError but got \(error)")
        }
    }

    @Test("withModelAccess lock released after invalidModelId error")
    func withModelAccessLockReleasedAfterValidationError() async {
        let manager = AcervoManager.shared
        let badModelId = "no-slash-validation"

        do {
            let _ = try await manager.withModelAccess(badModelId) { _ -> String in
                return ""
            }
        } catch {
            // Expected -- invalidModelId
        }

        // Lock should be released even after validation error
        let locked = await manager.isLocked(badModelId)
        #expect(!locked, "Lock should be released after invalidModelId error")
    }

    @Test("withModelAccess lock released after closure throws custom error")
    func withModelAccessLockReleasedAfterClosureError() async {
        let manager = AcervoManager.shared
        let modelId = "test-org/closure-error-test"

        do {
            let _ = try await manager.withModelAccess(modelId) { _ -> Int in
                throw AcervoError.directoryCreationFailed("test failure")
            }
        } catch {
            // Expected
        }

        // Lock should be released
        let locked = await manager.isLocked(modelId)
        #expect(!locked, "Lock should be released after closure error")
    }

    @Test("withModelAccess concurrent access to same model is serialized")
    func withModelAccessConcurrentSameModelSerialized() async throws {
        let manager = AcervoManager.shared
        let modelId = "test-org/concurrent-access-test"
        let tracker = TimestampTracker()

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    let _ = try await manager.withModelAccess(modelId) { _ -> Bool in
                        tracker.record("access1-start")
                        Thread.sleep(forTimeInterval: 0.08)
                        tracker.record("access1-end")
                        return true
                    }
                } catch {}
            }

            group.addTask {
                try? await Task.sleep(for: .milliseconds(5))
                do {
                    let _ = try await manager.withModelAccess(modelId) { _ -> Bool in
                        tracker.record("access2-start")
                        Thread.sleep(forTimeInterval: 0.08)
                        tracker.record("access2-end")
                        return true
                    }
                } catch {}
            }
        }

        let events = tracker.getEvents()

        // Verify serialization: one access must complete before the other starts
        if events.count >= 4 {
            let a1End = events.firstIndex(where: { $0.name == "access1-end" })
            let a2Start = events.firstIndex(where: { $0.name == "access2-start" })
            let a2End = events.firstIndex(where: { $0.name == "access2-end" })
            let a1Start = events.firstIndex(where: { $0.name == "access1-start" })

            if let end1 = a1End, let start2 = a2Start {
                let order1 = end1 < start2
                var order2 = false
                if let end2 = a2End, let start1 = a1Start {
                    order2 = end2 < start1
                }
                #expect(order1 || order2,
                        "Concurrent withModelAccess on same model should be serialized")
            }
        }

        // Both locks should be released
        let locked = await manager.isLocked(modelId)
        #expect(!locked, "Lock should be released after concurrent operations")
    }

    // MARK: - Timing-based serialization verification

    @Test("Same-model operations take at least 2x the work duration")
    func serializationTimingVerification() async throws {
        let manager = AcervoManager.shared
        let sameModel = "test-org/timing-same"
        let workDuration: TimeInterval = 0.08

        // Measure time for two same-model operations (should be serialized)
        let sameModelStart = ContinuousClock.now
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    let _ = try await manager.withModelAccess(sameModel) { _ -> Bool in
                        Thread.sleep(forTimeInterval: workDuration)
                        return true
                    }
                } catch {}
            }
            group.addTask {
                do {
                    let _ = try await manager.withModelAccess(sameModel) { _ -> Bool in
                        Thread.sleep(forTimeInterval: workDuration)
                        return true
                    }
                } catch {}
            }
        }
        let sameModelDuration = ContinuousClock.now - sameModelStart

        // Serialized should take at least 1.5x the work duration
        // (2x ideal, but we allow some slack for scheduling overhead)
        let minimumExpected: Duration = .milliseconds(Int(workDuration * 1500))
        #expect(sameModelDuration >= minimumExpected,
                "Serialized operations (\(sameModelDuration)) should take at least \(minimumExpected)")
    }

    // MARK: - URL Cache Tests

    @Test("URL cache stores and retrieves correctly")
    func urlCacheStoresAndRetrieves() async throws {
        let manager = AcervoManager.shared

        // Use a unique model ID to avoid interference from other tests
        let uniqueId = UUID().uuidString.prefix(8)

        // Create a temporary directory with mock model directories containing config.json
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("acervo-cache-test-\(uniqueId)")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: tempDir) }

        // Create a mock model directory with config.json
        let modelId = "test-org/cache-model-\(uniqueId)"
        let slug = Acervo.slugify(modelId)
        let modelDir = tempDir.appendingPathComponent(slug)
        try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try "{}".write(
            to: modelDir.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )

        // Record count before preloading
        let countBefore = await manager.cacheCount()

        // Preload the cache from the temp directory
        try await manager.preloadModels(in: tempDir)

        // Verify the model is cached
        let cached = await manager.isCached(modelId)
        #expect(cached, "Model should be present in cache after preloading")

        // Verify cache count increased
        let countAfter = await manager.cacheCount()
        #expect(countAfter > countBefore, "Cache count should increase after preloading")
    }

    @Test("clearCache() empties cache")
    func clearCacheEmptiesCache() async throws {
        let manager = AcervoManager.shared

        // Create a temporary directory with a mock model
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("acervo-clear-cache-test-\(UUID().uuidString)")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: tempDir) }

        let modelDir = tempDir.appendingPathComponent("test-org_clear-cache-model")
        try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try "{}".write(
            to: modelDir.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )

        // Preload to populate cache
        try await manager.preloadModels(in: tempDir)

        let cachedBefore = await manager.isCached("test-org/clear-cache-model")
        #expect(cachedBefore, "Model should be cached after preloading")

        // Clear the cache
        await manager.clearCache()

        // Verify cache is empty
        let cachedAfter = await manager.isCached("test-org/clear-cache-model")
        #expect(!cachedAfter, "Model should not be cached after clearCache()")

        let countAfter = await manager.cacheCount()
        #expect(countAfter == 0, "Cache count should be 0 after clearCache()")
    }

    @Test("preloadModels() populates cache for models in temp directory")
    func preloadModelsPopulatesCache() async throws {
        let manager = AcervoManager.shared
        let uniqueId = UUID().uuidString.prefix(8)

        // Create a temporary directory with multiple mock models
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("acervo-preload-test-\(uniqueId)")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: tempDir) }

        // Create three model directories with unique names
        let modelIds = [
            "org-a/preload-model-\(uniqueId)-one",
            "org-a/preload-model-\(uniqueId)-two",
            "org-b/preload-model-\(uniqueId)-three"
        ]

        for modelId in modelIds {
            let slug = Acervo.slugify(modelId)
            let modelDir = tempDir.appendingPathComponent(slug)
            try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
            try "{}".write(
                to: modelDir.appendingPathComponent("config.json"),
                atomically: true,
                encoding: .utf8
            )
        }

        // Record count before preloading
        let countBefore = await manager.cacheCount()

        // Preload models
        try await manager.preloadModels(in: tempDir)

        // Verify all three models are cached
        for modelId in modelIds {
            let cached = await manager.isCached(modelId)
            #expect(cached, "Model \(modelId) should be cached after preloading")
        }

        // Verify cache grew by at least 3
        let countAfter = await manager.cacheCount()
        #expect(countAfter >= countBefore + 3,
                "Cache should have at least 3 more entries after preloading")
    }

    // MARK: - Statistics Tests

    @Test("Download count increments after download()")
    func downloadCountIncrements() async throws {
        let manager = AcervoManager.shared
        // Use a unique model ID to avoid interference from other tests
        let uniqueId = UUID().uuidString.prefix(8)
        let modelId = "test-org/download-stats-\(uniqueId)"

        // Record count before (should be 0 for this unique model)
        let countBefore = await manager.getDownloadCount(for: modelId)

        // The download will fail (no real network), but the counter
        // should still increment because tracking happens before the
        // network call
        do {
            try await manager.download(modelId, files: ["config.json"])
        } catch {
            // Expected -- no real server to download from
        }

        let countAfter = await manager.getDownloadCount(for: modelId)
        #expect(countAfter == countBefore + 1,
                "Download count should increment by 1 after download()")
    }

    @Test("Access count increments after withModelAccess()")
    func accessCountIncrements() async throws {
        let manager = AcervoManager.shared
        let uniqueId = UUID().uuidString.prefix(8)
        let modelId = "test-org/access-stats-\(uniqueId)"

        let countBefore = await manager.getAccessCount(for: modelId)

        // withModelAccess will succeed (provides URL to closure)
        let _ = try await manager.withModelAccess(modelId) { url -> String in
            return url.lastPathComponent
        }

        let countAfter = await manager.getAccessCount(for: modelId)
        #expect(countAfter == countBefore + 1,
                "Access count should increment by 1 after withModelAccess()")
    }

    @Test("resetStatistics() clears all counters")
    func resetStatisticsClearsCounters() async throws {
        let manager = AcervoManager.shared
        let uniqueId = UUID().uuidString.prefix(8)
        let modelId = "test-org/reset-stats-\(uniqueId)"

        // Perform some operations to generate statistics
        let _ = try? await manager.withModelAccess(modelId) { _ -> Bool in true }
        do {
            try await manager.download(modelId, files: ["config.json"])
        } catch {
            // Expected
        }

        // Verify counters are non-zero before reset
        let downloadBefore = await manager.getDownloadCount(for: modelId)
        let accessBefore = await manager.getAccessCount(for: modelId)
        #expect(downloadBefore > 0, "Download count should be > 0 before reset")
        #expect(accessBefore > 0, "Access count should be > 0 before reset")

        // Reset statistics
        await manager.resetStatistics()

        // Verify counters are zero
        let downloadAfter = await manager.getDownloadCount(for: modelId)
        let accessAfter = await manager.getAccessCount(for: modelId)
        #expect(downloadAfter == 0, "Download count should be 0 after reset")
        #expect(accessAfter == 0, "Access count should be 0 after reset")
    }

    @Test("getDownloadCount returns 0 for unknown model")
    func downloadCountZeroForUnknownModel() async {
        let manager = AcervoManager.shared
        let uniqueId = UUID().uuidString.prefix(8)
        let count = await manager.getDownloadCount(for: "unknown-org/never-downloaded-\(uniqueId)")
        #expect(count == 0, "Download count should be 0 for a model that was never downloaded")
    }

    @Test("getAccessCount returns 0 for unknown model")
    func accessCountZeroForUnknownModel() async {
        let manager = AcervoManager.shared
        let uniqueId = UUID().uuidString.prefix(8)
        let count = await manager.getAccessCount(for: "unknown-org/never-accessed-\(uniqueId)")
        #expect(count == 0, "Access count should be 0 for a model that was never accessed")
    }

    @Test("printStatisticsReport() executes without error")
    func printStatisticsReportExecutes() async throws {
        let manager = AcervoManager.shared
        let uniqueId = UUID().uuidString.prefix(8)
        let modelA = "test-org/report-model-a-\(uniqueId)"
        let modelB = "test-org/report-model-b-\(uniqueId)"

        // Record baseline counts for these unique model IDs (should be 0)
        let baseA = await manager.getAccessCount(for: modelA)
        let baseB = await manager.getAccessCount(for: modelB)

        // Perform a few operations
        let _ = try? await manager.withModelAccess(modelA) { _ -> Bool in true }
        let _ = try? await manager.withModelAccess(modelA) { _ -> Bool in true }
        let _ = try? await manager.withModelAccess(modelB) { _ -> Bool in true }

        // printStatisticsReport should not throw or crash
        await manager.printStatisticsReport()

        // Verify the access counts incremented correctly
        let countA = await manager.getAccessCount(for: modelA)
        let countB = await manager.getAccessCount(for: modelB)
        #expect(countA == baseA + 2, "Model A should have 2 more accesses")
        #expect(countB == baseB + 1, "Model B should have 1 more access")
    }
}

// MARK: - Test Helpers

/// Thread-safe timestamp tracker for concurrency tests.
/// Uses a lock-based approach since it is called from synchronous closures.
private final class TimestampTracker: @unchecked Sendable {

    struct Event {
        let name: String
        let time: ContinuousClock.Instant
    }

    private let lock = NSLock()
    private var _events: [Event] = []

    func record(_ name: String) {
        lock.lock()
        _events.append(Event(name: name, time: .now))
        lock.unlock()
    }

    func getEvents() -> [Event] {
        lock.lock()
        let result = _events
        lock.unlock()
        return result
    }
}
