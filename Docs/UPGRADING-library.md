# Upgrading SwiftAcervo — Library Consumers

Per-version migration guide for code that links **`SwiftAcervo`** (the library target) — iOS / macOS apps, frameworks, and other Swift packages.

For CLI-side migrations (the `acervo` binary, its subcommands and flags), see [`UPGRADING-cli.md`](UPGRADING-cli.md). For design context behind each change, see [`../CHANGELOG.md`](../CHANGELOG.md) and [`USAGE-library.md`](USAGE-library.md). This file is the operational how-to for library callers.

> **Audience.** This file assumes you write Swift that imports `SwiftAcervo`. If you only run `acervo ship` / `acervo recache` / `acervo verify`, you want `UPGRADING-cli.md` instead.

---

## The goal of every upgrade: stop poking the filesystem; ask the library

SwiftAcervo's design philosophy, hardened through every release since 0.13 and made first-class in 0.16, is a single rule:

> **The CDN manifest is the sole authoritative source for what a model is.** Consumers MUST NOT enumerate the model directory, hardcode `safetensors` / `tokenizer.json` / `config.json` filenames, or derive on-disk paths from an `org/repo` string by hand. Every question about a model — "is it ready?", "what files does it have?", "where do they live on disk?", "which shards are missing?", "is it downloading?" — has a `SwiftAcervo` accessor. Use it.

If you are writing or auditing a consumer, every `FileManager.default.contentsOfDirectory(...)` against a SwiftAcervo-managed directory is a bug, every hardcoded file name is a bug, and every `URL(fileURLWithPath: "\(home)/SharedModels/\(slug)")` is a bug. The library APIs that replace each of these are documented in [`USAGE-library.md`](USAGE-library.md).

---

## Upgrading to 0.17.0 (from 0.16.x)

0.17.0 fixes a regression that left component-keyed downloads invisible to the UI and adds two telemetry events for diagnosing the in-flight registry. The behavior fix is the headline; the telemetry events are an `AcervoTelemetryEvent` switch-exhaustiveness break.

### TL;DR

| Change | Affects consumers? | Action |
|---|---|---|
| `Acervo.ensureComponentReady(_:)` now registers with `InFlightDownloads.shared` for the duration of the underlying download | Yes — **behavior fix**, no API change | None at the call site. UI code that polls `Acervo.availability(repoId)` will now correctly observe `.downloading(progress:)` for components mid-download. |
| Two new `AcervoTelemetryEvent` cases: `inFlightDownloadRegistered(modelID:componentID:role:)` and `inFlightDownloadCleared(modelID:componentID:outcome:)` | Yes — switch exhaustiveness break for any `switch` over `AcervoTelemetryEvent` without `@unknown default` | Add `case .inFlightDownloadRegistered`, `case .inFlightDownloadCleared` arms (or `@unknown default`) wherever you switch over `AcervoTelemetryEvent`. |
| Two new supporting enums: `AcervoTelemetryEvent.InFlightRole` (`.originator` / `.joiner`) and `AcervoTelemetryEvent.InFlightOutcome` (`.success` / `.failure`) | Additive | Use the role/outcome fields when adapting events into your own telemetry surface. |
| Internal test seam: `session: URLSession? = nil` parameter on internal overloads of `downloadComponent`, `ensureComponentReady`, `ensureComponentsReady` | No (internal only) | None. The public API is unchanged. |

### Step 1 — The behavior fix (no action required)

Through 0.16.x, `Acervo.ensureComponentReady` performed the download but never touched `InFlightDownloads.shared`. As a result, a UI that polled `Acervo.availability(repoId)` while a component download was in flight got `.partial(missing: [...])` or `.notAvailable` — never `.downloading`. Progress bars stayed at zero, polling loops keyed on `case .downloading` exited immediately, and stale `lastError` messages remained on screen for the entire multi-minute download.

0.17.0 wraps the download branch of `ensureComponentReady` in `InFlightDownloads.shared.task(for: repoId)`, publishing progress ticks through the existing `publishProgress(_:for:)` actor and clearing the registry on both the success and failure paths via `defer`. The contract documented on `InFlightDownloads` ("the source of truth for the `.downloading(progress:)` arm of `Acervo.availability(_:)`") now holds for the component-keyed path as well, not just the single-repo `ensureAvailable` path.

There is no API change. UI consumers polling `Acervo.availability(repoId)` start seeing `.downloading(progress:)` automatically once they're on 0.17.0.

**Dedup semantics match `ensureAvailable`.** Two concurrent `ensureComponentReady` calls for the same `componentId` (or any two components that share a `repoId`) converge on a single underlying Task. The joiner's caller-supplied `progress` callback does NOT receive ticks (the originator's does); UI consumers polling `availability(_:)` see the registered `.downloading` state regardless of role.

### Step 2 — Handle the new `AcervoTelemetryEvent` cases

If your code has a `switch event { ... }` over `AcervoTelemetryEvent` without `@unknown default`, it will fail to compile. Add arms for the new cases:

```swift
// Before (0.16.x)
switch event {
case .componentResolveStart(let componentID, let repoID):
    log("resolve start: \(componentID) → \(repoID)")
case .componentResolveComplete(let componentID, _, _, _, let state, _):
    log("resolve complete: \(componentID) (\(state))")
// … other cases …
}

// After (0.17.0)
switch event {
case .componentResolveStart(let componentID, let repoID):
    log("resolve start: \(componentID) → \(repoID)")
case .componentResolveComplete(let componentID, _, _, _, let state, _):
    log("resolve complete: \(componentID) (\(state))")
case .inFlightDownloadRegistered(let modelID, let componentID, let role):
    // role is .originator (this caller started the underlying Task)
    // or .joiner (this caller joined an existing in-flight Task)
    log("in-flight registered: \(modelID) componentID=\(componentID ?? "—") role=\(role)")
case .inFlightDownloadCleared(let modelID, let componentID, let outcome):
    // outcome is .success or .failure. Fires from the originator's defer block.
    log("in-flight cleared: \(modelID) componentID=\(componentID ?? "—") outcome=\(outcome)")
// … other cases …
}
```

Or, if you want to opt out of future exhaustiveness breaks across the bridge:

```swift
switch event {
case .componentResolveStart, .componentResolveComplete:
    // …
@unknown default:
    return
}
```

### Step 3 — Use the new events for download diagnostics

The two new events form a matched pair scoped to a single component download:

| Event | When | Where it fires from |
|---|---|---|
| `.inFlightDownloadRegistered(modelID, componentID, role)` | Once per `ensureComponentReady` call that performs a download (not on cache hit). | Caller's task, after `InFlightDownloads.shared.task(for:)` resolves. |
| `.inFlightDownloadCleared(modelID, componentID, outcome)` | Once per underlying Task, on both success and failure. | Detached Task launched from the originator's `defer` block. |

**Role semantics.** `.originator` is the caller whose `task(for:)` invocation actually registered the underlying Task; `.joiner` joined an already-registered Task and is awaiting its outcome without running its own download. Exactly one `.originator` event is emitted per `(modelID, in-flight registration window)` pair; zero or more `.joiner` events may follow before the matched `Cleared` event clears the registry.

**Outcome semantics.** `.success` fires when the underlying `downloadComponent` returns without throwing. `.failure` fires when it throws — for any reason (network, integrity, manifest decode, App Group resolution). The thrown error itself propagates through the caller's `try` separately; consult `errorThrown` events on the same reporter for the specific failure phase.

**Cache-hit short-circuit.** Neither `Registered` nor `Cleared` events fire when `ensureComponentReady` short-circuits on `isComponentReady` returning true. The existing `componentResolveStart` / `componentResolveComplete(cacheState: .alreadyReady)` pair covers that case.

### Why this matters operationally

Before 0.17.0, a downstream consumer asking "why does my progress bar stay at 0?" or "why does the row UI show no spinner during a 3-GB component download?" had no library-side answer — `Acervo.availability(_:)` was the contract, and it was lying for the component-keyed path. With 0.17.0 the contract holds, and the two new telemetry events let consumers verify that the in-flight registry is being entered, joined, and cleared as expected without instrumenting `InFlightDownloads.shared` directly.

---

## Older versions

For 0.16.0 and earlier migrations (slug-keyed APIs, `ModelAvailability.partial(missing:)`, `CDNManifest.primaryRepo` / `.components` required-on-the-wire, `Acervo.swift` decomposition, etc.) see [`../UPGRADING.md`](../UPGRADING.md). That file remains the canonical reference for pre-0.17 library migrations and will be folded into this file as future versions ship.
