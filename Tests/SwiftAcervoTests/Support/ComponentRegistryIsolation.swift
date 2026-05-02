// ComponentRegistryIsolation.swift
// SwiftAcervo tests
//
// Test-only snapshot/restore helpers for `ComponentRegistry.shared` and the
// `ACERVO_APP_GROUP_ID` environment variable that drives
// `Acervo.sharedModelsDirectory`. Complements `AppGroupEnvironmentSuite`
// (the `.serialized` parent suite): even though the parent suite serializes
// env-var writers, this helper guarantees snapshot/restore semantics so a
// test crashing mid-body cannot contaminate the next test in line.
//
// Helpers provided:
//
//   - `withIsolatedAcervoState` — sets `ACERVO_APP_GROUP_ID` to a unique
//     per-test group identifier, snapshots `ComponentRegistry.shared`,
//     yields to the body, and restores both on exit (including on throw).
//     The resolved `~/Library/Group Containers/<test-group>/` directory is
//     removed in `defer` so tests do not leak data between runs.
//   - `withIsolatedComponentRegistry` — narrower: registry only, for tests
//     that do not exercise model storage.
//   - `withIsolatedSharedModelsDirectory` — for tests that previously wrote
//     `Acervo.customBaseDirectory = tmp` and read `tmp` directly. Yields the
//     resolved `Acervo.sharedModelsDirectory` URL into the body.
//
// Usage:
// ```swift
// try await withIsolatedComponentRegistry {
//   Acervo.register(...)
//   // ...test body...
// }
// ```

import Foundation
import Testing

@testable import SwiftAcervo

// MARK: - Per-test App Group helpers

/// Generates a unique App Group identifier suitable for use as a test
/// `ACERVO_APP_GROUP_ID`. The resolved Group Containers directory will be
/// `~/Library/Group Containers/<returned-id>/`, isolated per test.
func makeTestAppGroupID() -> String {
  "group.acervo.test.\(UUID().uuidString.lowercased())"
}

/// Removes the on-disk Group Containers directory for a given test group ID,
/// if it exists. Safe to call even when the directory was never created.
func cleanupTestGroupContainer(_ groupID: String) {
  #if os(macOS)
    let groupRoot = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Group Containers")
      .appendingPathComponent(groupID)
    try? FileManager.default.removeItem(at: groupRoot)
  #else
    if let groupRoot = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: groupID
    ) {
      try? FileManager.default.removeItem(at: groupRoot)
    }
  #endif
}

// MARK: - Combined helper (env var + ComponentRegistry)

/// Sets `ACERVO_APP_GROUP_ID` to a unique per-test value, snapshots the
/// component registry, runs `body`, and restores both on exit. Cleans up the
/// resolved Group Containers directory afterward.
@discardableResult
func withIsolatedAcervoState<T>(
  _ body: () async throws -> T
) async rethrows -> T {
  let testGroupID = makeTestAppGroupID()
  let previousEnv = ProcessInfo.processInfo.environment[Acervo.appGroupEnvironmentVariable]
  setenv(Acervo.appGroupEnvironmentVariable, testGroupID, 1)
  let savedDescriptors = ComponentRegistry.shared.allComponents()
  defer {
    if let previous = previousEnv {
      setenv(Acervo.appGroupEnvironmentVariable, previous, 1)
    } else {
      unsetenv(Acervo.appGroupEnvironmentVariable)
    }
    ComponentRegistry.shared.removeAll()
    for descriptor in savedDescriptors {
      ComponentRegistry.shared.replace(descriptor)
    }
    cleanupTestGroupContainer(testGroupID)
  }
  return try await body()
}

/// Synchronous variant of `withIsolatedAcervoState`.
@discardableResult
func withIsolatedAcervoStateSync<T>(
  _ body: () throws -> T
) rethrows -> T {
  let testGroupID = makeTestAppGroupID()
  let previousEnv = ProcessInfo.processInfo.environment[Acervo.appGroupEnvironmentVariable]
  setenv(Acervo.appGroupEnvironmentVariable, testGroupID, 1)
  let savedDescriptors = ComponentRegistry.shared.allComponents()
  defer {
    if let previous = previousEnv {
      setenv(Acervo.appGroupEnvironmentVariable, previous, 1)
    } else {
      unsetenv(Acervo.appGroupEnvironmentVariable)
    }
    ComponentRegistry.shared.removeAll()
    for descriptor in savedDescriptors {
      ComponentRegistry.shared.replace(descriptor)
    }
    cleanupTestGroupContainer(testGroupID)
  }
  return try body()
}

// MARK: - Narrow helper (ComponentRegistry only)

/// Snapshots `ComponentRegistry.shared` contents, yields to `body`, and
/// restores the snapshot on exit (via `defer` — runs on throw too).
@discardableResult
func withIsolatedComponentRegistry<T>(
  _ body: () async throws -> T
) async rethrows -> T {
  let saved = ComponentRegistry.shared.allComponents()
  defer {
    ComponentRegistry.shared.removeAll()
    for descriptor in saved {
      ComponentRegistry.shared.replace(descriptor)
    }
  }
  return try await body()
}

/// Synchronous variant of `withIsolatedComponentRegistry`.
@discardableResult
func withIsolatedComponentRegistrySync<T>(
  _ body: () throws -> T
) rethrows -> T {
  let saved = ComponentRegistry.shared.allComponents()
  defer {
    ComponentRegistry.shared.removeAll()
    for descriptor in saved {
      ComponentRegistry.shared.replace(descriptor)
    }
  }
  return try body()
}

// MARK: - Yield-the-resolved-URL helpers

/// Runs `body` with `ACERVO_APP_GROUP_ID` set to a unique per-test value and
/// passes the resolved `Acervo.sharedModelsDirectory` URL into the closure.
/// Cleans up the env var and the resolved Group Containers directory on exit.
///
/// Use this in tests that previously wrote `Acervo.customBaseDirectory = tmp`
/// and then read `tmp` directly. The yielded URL is the new "tmp" — it lives
/// under `~/Library/Group Containers/<unique-id>/SharedModels/`.
@discardableResult
func withIsolatedSharedModelsDirectory<T>(
  _ body: (URL) throws -> T
) rethrows -> T {
  let testGroupID = makeTestAppGroupID()
  let previousEnv = ProcessInfo.processInfo.environment[Acervo.appGroupEnvironmentVariable]
  setenv(Acervo.appGroupEnvironmentVariable, testGroupID, 1)
  defer {
    if let previous = previousEnv {
      setenv(Acervo.appGroupEnvironmentVariable, previous, 1)
    } else {
      unsetenv(Acervo.appGroupEnvironmentVariable)
    }
    cleanupTestGroupContainer(testGroupID)
  }
  return try body(Acervo.sharedModelsDirectory)
}

@discardableResult
func withIsolatedSharedModelsDirectoryAsync<T>(
  _ body: (URL) async throws -> T
) async rethrows -> T {
  let testGroupID = makeTestAppGroupID()
  let previousEnv = ProcessInfo.processInfo.environment[Acervo.appGroupEnvironmentVariable]
  setenv(Acervo.appGroupEnvironmentVariable, testGroupID, 1)
  defer {
    if let previous = previousEnv {
      setenv(Acervo.appGroupEnvironmentVariable, previous, 1)
    } else {
      unsetenv(Acervo.appGroupEnvironmentVariable)
    }
    cleanupTestGroupContainer(testGroupID)
  }
  return try await body(Acervo.sharedModelsDirectory)
}
