// ComponentRegistryIsolation.swift
// SwiftAcervo tests — OPERATION TRIPWIRE GAUNTLET Sortie 2.
//
// Test-only snapshot/restore helpers for `ComponentRegistry.shared` and
// `Acervo.customBaseDirectory`. Complements `CustomBaseDirectorySuite`
// (the `.serialized` parent suite) as the (b) half of the Sortie 2 decision:
// even though the parent suite serializes customBaseDirectory writers, this
// helper guarantees snapshot/restore semantics so a test crashing mid-body
// cannot contaminate the next test in line.
//
// Two helpers are provided:
//
//   - `withIsolatedAcervoState` — snapshots BOTH `Acervo.customBaseDirectory`
//     AND `ComponentRegistry.shared` contents, yields to the body, and
//     restores them on exit (including on throw).
//   - `withIsolatedComponentRegistry` — narrower: registry only, for tests
//     that do not touch customBaseDirectory.
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

// MARK: - Combined helper (customBaseDirectory + ComponentRegistry)

/// Runs `body` with both `Acervo.customBaseDirectory` and the
/// `ComponentRegistry.shared` contents snapshotted and restored on exit.
@discardableResult
func withIsolatedAcervoState<T>(
  _ body: () async throws -> T
) async rethrows -> T {
  let savedBaseDirectory = Acervo.customBaseDirectory
  let savedDescriptors = ComponentRegistry.shared.allComponents()
  defer {
    Acervo.customBaseDirectory = savedBaseDirectory
    ComponentRegistry.shared.removeAll()
    for descriptor in savedDescriptors {
      ComponentRegistry.shared.replace(descriptor)
    }
  }
  return try await body()
}

/// Synchronous variant of `withIsolatedAcervoState`.
@discardableResult
func withIsolatedAcervoStateSync<T>(
  _ body: () throws -> T
) rethrows -> T {
  let savedBaseDirectory = Acervo.customBaseDirectory
  let savedDescriptors = ComponentRegistry.shared.allComponents()
  defer {
    Acervo.customBaseDirectory = savedBaseDirectory
    ComponentRegistry.shared.removeAll()
    for descriptor in savedDescriptors {
      ComponentRegistry.shared.replace(descriptor)
    }
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
