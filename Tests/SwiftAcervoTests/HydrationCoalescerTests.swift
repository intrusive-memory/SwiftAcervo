// HydrationCoalescerTests.swift
// SwiftAcervoTests
//
// Companion tests for Sources/SwiftAcervo/Acervo+Hydration.swift
//
// Exercises `HydrationCoalescer` (the internal actor) directly using a
// test-injectable fetch closure and an atomic counter. These tests live
// outside `SharedStaticStateSuite` because they create a fresh, isolated
// `HydrationCoalescer` instance per test — no shared static state is touched.
//
// Case A — same-key coalescing: two concurrent calls for the same key share
//           one underlying load (counter == 1).
// Case B — different-key non-coalescing: two concurrent calls for different
//           keys each run their own underlying load (counter == 2).

import Foundation
import Testing

@testable import SwiftAcervo

// MARK: - Thread-safe counter helper

/// A simple thread-safe call counter for test assertions.
private final class AtomicCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var _count: Int = 0

  func increment() {
    lock.lock()
    defer { lock.unlock() }
    _count += 1
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return _count
  }
}

// MARK: - HydrationCoalescer unit tests

@Suite("HydrationCoalescer Actor Tests")
struct HydrationCoalescerTests {

  // MARK: - Case A: Same-key coalescing

  /// Two concurrent calls for the SAME key must share a single underlying
  /// load. The fetch closure increments a counter; asserting `counter == 1`
  /// after both calls complete proves coalescing occurred.
  ///
  /// The fetch closure is given a `Task.sleep` delay so both concurrent
  /// callers reach the actor before the first one completes — otherwise the
  /// second call would arrive after the inflight slot cleared.
  @Test("Same key: two concurrent calls coalesce into one underlying load")
  func sameKeyCoalescesIntoOneLoad() async throws {
    let coalescer = HydrationCoalescer()
    let counter = AtomicCounter()

    let fetch: @Sendable () async throws -> Void = {
      // Brief delay ensures both tasks are in flight simultaneously.
      try await Task.sleep(for: .milliseconds(80))
      counter.increment()
    }

    // Launch both tasks concurrently.
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await coalescer.hydrate("component-A", fetch: fetch) }
      group.addTask { try await coalescer.hydrate("component-A", fetch: fetch) }
      try await group.waitForAll()
    }

    // F7 gate: if this fails (counter == 2), HydrationCoalescer does NOT
    // coalesce same-key concurrent calls. Stop and report PARTIAL.
    #expect(counter.count == 1, "Expected exactly 1 load for 2 concurrent same-key calls; got \(counter.count). HydrationCoalescer may not be coalescing correctly.")
  }

  // MARK: - Case B: Different-key non-coalescing

  /// Two concurrent calls for DIFFERENT keys must each run their own
  /// underlying load independently. The counter must be 2 after both
  /// calls complete.
  ///
  /// A delay in the fetch closure gives both tasks time to overlap. If
  /// the actor were incorrectly serializing all keys (not just same-key),
  /// the counter would still be 2 but the total elapsed time would roughly
  /// double. We assert the count; timing-based assertions are omitted to
  /// avoid flakiness.
  @Test("Different keys: two concurrent calls each run their own load")
  func differentKeysRunIndependentLoads() async throws {
    let coalescer = HydrationCoalescer()
    let counter = AtomicCounter()

    let fetch: @Sendable () async throws -> Void = {
      // Delay ensures the two different-key tasks can overlap.
      try await Task.sleep(for: .milliseconds(40))
      counter.increment()
    }

    // Launch both tasks concurrently — different keys.
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await coalescer.hydrate("component-X", fetch: fetch) }
      group.addTask { try await coalescer.hydrate("component-Y", fetch: fetch) }
      try await group.waitForAll()
    }

    // Both keys must have executed their fetch exactly once each.
    #expect(counter.count == 2, "Expected 2 loads for 2 concurrent different-key calls; got \(counter.count).")
  }

  // MARK: - Supporting verification: sequential same-key re-fetches

  /// After a completed hydration, a subsequent call for the same key must
  /// create a new inflight task (not coalesce with an already-completed one).
  /// Counter must reach 2 across two sequential calls.
  @Test("Same key: sequential calls after completion each run independently")
  func sameKeySequentialCallsAreSeparate() async throws {
    let coalescer = HydrationCoalescer()
    let counter = AtomicCounter()

    let fetch: @Sendable () async throws -> Void = {
      counter.increment()
    }

    // First call.
    try await coalescer.hydrate("component-seq", fetch: fetch)
    // Second call — the inflight slot was cleared on completion of the first.
    try await coalescer.hydrate("component-seq", fetch: fetch)

    #expect(counter.count == 2, "Expected 2 loads for 2 sequential same-key calls after completion; got \(counter.count).")
  }

  // MARK: - Supporting verification: many concurrent same-key calls coalesce to one

  /// Ten concurrent calls for the same key should all coalesce into a single
  /// underlying load. This is an extended version of Case A.
  @Test("Same key: ten concurrent calls coalesce into exactly one load")
  func tenConcurrentSameKeyCoalescesToOne() async throws {
    let coalescer = HydrationCoalescer()
    let counter = AtomicCounter()

    let fetch: @Sendable () async throws -> Void = {
      try await Task.sleep(for: .milliseconds(100))
      counter.increment()
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<10 {
        group.addTask { try await coalescer.hydrate("component-bulk", fetch: fetch) }
      }
      try await group.waitForAll()
    }

    #expect(counter.count == 1, "Expected 1 load for 10 concurrent same-key calls; got \(counter.count).")
  }
}
