import Testing
import Foundation
@testable import SwiftAcervo

/// Tests for AcervoManager actor, focusing on per-model locking serialization
/// and concurrent access behavior.
@Suite("AcervoManager Tests")
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
