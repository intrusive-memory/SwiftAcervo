---
type: reference
---

# Canonical test-gating convention

Every model-dependent integration test must gate on **model presence**, not on
whether it's running in CI. The cache is primed in CI, so a presence gate runs
the test for real in CI and skips cleanly on a local machine that hasn't primed
the model. This replaces all the divergent patterns found across repos:

| Anti-pattern (remove) | Why it's wrong |
|---|---|
| `@Suite(.disabled(if: !(env["CI"] ?? "").isEmpty))` | Inverted — runs only locally, **skips in CI**. The exact opposite of what we want. |
| `if isCI { runMock() } else { runReal() }` | Never exercises real inference in CI. |
| `MLXAUDIO_NIGHTLY_RUN=1` / repo-specific env gates | Bespoke per repo; the model either is on disk or isn't. |
| `Issue.record("skipping…")` then continue | Records a failure-ish event but doesn't actually skip; noisy. |
| Hard precondition that `fatalError`s / fails on missing model | A dev without the model gets a red suite instead of a skip. |

## swift-testing

Gate at the suite or test level with `.enabled(if:)`. `Acervo.isModelAvailable`
is synchronous and does only local I/O (size check against the on-disk
manifest), so it is safe to evaluate as a trait condition.

```swift
import Testing
import SwiftAcervo

private let kModel = "flux2-klein-4b"

@Suite("FLUX.2 generation", .enabled(if: Acervo.isModelAvailable(kModel)), .serialized)
struct Flux2IntegrationTests {
    @Test func generatesAnImage() async throws {
        // Model is guaranteed present here. In CI it was primed; locally the
        // whole suite is skipped if you haven't primed it.
        ...
    }
}
```

`.serialized` is recommended for GPU/MLX suites — MLX shares a global Metal
context and parallel suites collide.

## XCTest

Gate per test method with `XCTSkipUnless` (preferred over `XCTSkipIf` so the
condition reads as "run only when available"):

```swift
import XCTest
import SwiftAcervo

final class GenerationIntegrationTests: XCTestCase {
    private let model = "flux2-klein-4b"

    func testGeneratesAnImage() async throws {
        try XCTSkipUnless(
            Acervo.isModelAvailable(model),
            "Model \(model) not cached — prime via .github/scripts/acervo-ci-prime.sh or run in CI"
        )
        ...
    }
}
```

## Do NOT call `ensureAvailable` from the test body in CI

With `ACERVO_OFFLINE=1` set in CI, `Acervo.ensureAvailable` will throw if the
model isn't already complete — which is what we want as a *safety net*, but the
**gate** must be `isModelAvailable` (local, sync, no throw). Priming happens in
the workflow step, not inside the test. Calling `ensureAvailable` in the body is
fine as a redundant assertion but must not be relied on to download.
