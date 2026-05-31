---
title: Public test-models directory override for unentitled runners
status: proposed
audience: SwiftAcervo maintainers + downstream consumers (SwiftTuberia, SwiftVinetas)
created: 2026-05-31
component: Acervo+PathResolution
---

# Public test-models directory override for unentitled runners

## Summary

The SwiftAcervo **v2 path resolution surface** (`withComponentAccess` /
`withModelAccess` + `ComponentHandle`) has no public way to point an
**unentitled process** — most importantly an `xctest` runner — at model
weights that live outside the App Group container. Before the v2 migration,
downstream `SwiftTuberia` carried its own MACF-bypass redirect in
`WeightLoader`; v2 correctly moved path ownership into SwiftAcervo but did
**not** carry that escape hatch across. The result: every GPU/integration
test in SwiftVinetas/SwiftTuberia that loads real weights crashes or fails,
because all loads now funnel through `Acervo.sharedModelsDirectory` → the
App Group container, which the macOS sandbox (MACF) blocks for an unentitled
runner.

This proposal adds a single public, opt-in override at the one chokepoint all
v2 paths already pass through.

## Background — why the current surface can't run in tests

`xctest` bundles built by SwiftPM do not carry the
`com.apple.security.application-groups` entitlement. macOS MACF therefore
blocks `fopen()` on files inside
`~/Library/Group Containers/group.intrusive-memory.models/SharedModels/…`,
even though those exact files are readable from an entitled shell. Observed
failure when loading the PixArt T5 component:

```
NSCocoaErrorDomain Code=513 "You don't have permission to save the file
config.json in the folder intrusive-memory_t5-xxl-int4-mlx."
  → NSPOSIXErrorDomain Code=1 "Operation not permitted"
```

The established workaround (still encoded in SwiftVinetas's `Makefile` via
`link-test-models`) is to **hardlink** the weights from the App Group
container into `/tmp/...` from an entitled shell, then have the runner read
from `/tmp`. This worked while `SwiftTuberia.WeightLoader` owned the redirect
(`VINETAS_TEST_MODELS_DIR`, commits `6e7820a`, `6fdd796`, `2353bfa`). Tuberia
v0.3.9 (`3b29002`, "SwiftAcervo v2 integration") delegated path resolution to
Acervo and removed the redirect — but Acervo never grew a public equivalent,
so the hardlink mirror is now orphaned (nothing reads it).

### What already exists in Acervo

`AcervoManager` already has an **internal** test seam that proves the design
is intended:

```swift
// public — hardcodes the sandboxed path
func withComponentAccess(_ id, perform:)            // → Acervo.sharedModelsDirectory

// internal — "enables testing with temporary directories without touching
// the real sharedModelsDirectory"
func withComponentAccess(_ id, in baseDirectory:, perform:)
```

That internal overload resolves `baseDirectory.appendingPathComponent(slugify(repoId))`.
The SwiftVinetas Makefile already hardlinks into exactly that slug layout
(`intrusive-memory_t5-xxl-int4-mlx`, etc.), so the only thing missing is a
**public, cross-process way to supply the base directory.**

## Decision

Add an environment-variable override consulted at the top of
`Acervo.sharedModelsDirectory`. Chosen over the alternatives because:

- `sharedModelsDirectory` is the **single chokepoint** every v2 API funnels
  through (`withComponentAccess`, `withModelAccess`, downloads, integrity
  checks). One change covers all consumers.
- **Zero downstream code changes.** SwiftTuberia's `WeightLoader` and
  SwiftVinetas's `FeatureExtractor`/`ImageClassifier` already call
  `withComponentAccess`; they inherit the override for free. (The
  explicit-`in:`-parameter route would require threading a base dir through
  every call site in two repos.)
- Cross-process by nature, which the `xctest` boundary requires — a global
  variable can't be set from the parent Makefile into the runner; an env var
  can (xcodebuild forwards `TEST_RUNNER_*`-prefixed vars).

## Proposed change (drafted)

A draft of this change is already applied to the working tree of the
`development` branch (uncommitted) in
`Sources/SwiftAcervo/Acervo+PathResolution.swift`:

1. New public constant:

   ```swift
   /// Environment variable that overrides `sharedModelsDirectory` with an
   /// explicit filesystem path, bypassing App Group resolution entirely.
   /// Intended for test runners / CLI tools that cannot reach the App Group
   /// container. Do not set in production.
   public static let modelsDirectoryOverrideVariable = "ACERVO_MODELS_DIR"
   ```

2. Override check at the top of `sharedModelsDirectory` (before the App Group
   `fatalError` guard, so the group identifier is not required when the
   override is in effect):

   ```swift
   public static var sharedModelsDirectory: URL {
     if let override = ProcessInfo.processInfo.environment[modelsDirectoryOverrideVariable],
       !override.isEmpty
     {
       return URL(fileURLWithPath: override, isDirectory: true)
     }
     guard let groupID = resolvedAppGroupIdentifier else { fatalError(…) }
     … // unchanged
   }
   ```

The override directory must use the normal layout: one `slugify(<org>/<repo>)`
subdirectory per component. The existing SwiftVinetas hardlink mirror already
satisfies this.

## Semantics & safety

- **Opt-in only.** Sandboxed UI apps never set the variable, so production
  behavior is unchanged.
- **Bypasses the App Group requirement** when set — useful for unentitled
  CLI tooling as well as tests. The `fatalError` for a missing App Group id
  is only reached when the override is absent.
- **Integrity preserved.** Hardlinks share inode content, so `sha256`
  integrity checks in `withComponentAccess` pass against the mirror.
- **Naming.** `ACERVO_MODELS_DIR` is library-neutral (the old name
  `VINETAS_TEST_MODELS_DIR` leaked a downstream consumer's name into the
  library). The override is read raw; the `TEST_RUNNER_` prefix is purely an
  xcodebuild forwarding convention applied by the consumer's test scheme.

## Downstream follow-ups (not in this repo)

- **SwiftVinetas `Makefile`:** rename the forwarded var
  `TEST_RUNNER_VINETAS_TEST_MODELS_DIR` → `TEST_RUNNER_ACERVO_MODELS_DIR`
  in `test-gpu`, `test-integration`, `test-pixart-repro`,
  `test-telemetry-debug`. The hardlink layout in `link-test-models` is
  already correct and needs no change.
- **SwiftTuberia:** no change required.
- The SwiftVinetas test files currently gate on the presence of
  `VINETAS_TEST_MODELS_DIR`; update those skip-guards to the new name (or
  keep a thin alias) so the suites stop self-skipping.

## Acceptance criteria

- With `ACERVO_MODELS_DIR=/tmp/vinetas-test-models` set, an unentitled
  `xctest` runner loads PixArt + FLUX.2 weights without the MACF
  `Operation not permitted` error.
- `make test-gpu` / `make test-integration` in SwiftVinetas run to
  completion (pass/fail on assertions, not on weight-load access errors).
- Production/UI behavior unchanged when the variable is unset
  (existing tests stay green).
- A unit test in SwiftAcervo asserts `sharedModelsDirectory` returns the
  override path when the variable is set and falls back to App Group
  resolution when it is unset.

## Notes

- This is distinct from the PixArt **garbage-output** bug
  (SwiftVinetas issue #39). That requires weights that successfully load,
  which only happens via the entitled `vinetas` CLI today; the broken test
  harness can't even reach the code path that reproduces #39. Landing this
  override is a prerequisite for ever gating #39 with an automated test.
- The drafted code change has **not** been compile-verified in this session
  (XcodeBuildMCP not connected; `swift build` is disallowed by project
  policy). Build via `xcodebuild` before committing.
