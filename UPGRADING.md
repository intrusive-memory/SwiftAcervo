# Upgrading SwiftAcervo

Per-version migration guide for SwiftAcervo. Targeted at **agents reading consumer code** — the patterns below are concrete enough to drive grep-and-replace decisions without further interpretation.

For design context behind each change, see [`CHANGELOG.md`](CHANGELOG.md) and [`Docs/MODEL_AVAILABILITY_PATH.md`](Docs/MODEL_AVAILABILITY_PATH.md). This file is the operational how-to.

---

## Upgrading to 0.14.0 (from 0.13.x)

0.14.0 introduces a three-state availability API and tightens the semantics of `Acervo.isModelAvailable(_:)`. The change is **source-breaking by behavior, not by signature**: every existing call to `isModelAvailable` still compiles, but a non-trivial fraction of them will return a different value. This guide enumerates the call patterns and gives an explicit disposition for each.

### TL;DR

| Old call                                  | What it actually meant | What it now returns | Action |
|-------------------------------------------|------------------------|---------------------|--------|
| `Acervo.isModelAvailable(modelId)` (consumer wanted "is the model usable") | "`config.json` exists at the model root" | `true` only if every manifest file is present at recorded size | **No change needed.** The new semantics is what you actually wanted. |
| `Acervo.isModelAvailable(modelId)` (consumer only wanted to probe for `config.json`) | "`config.json` exists at the model root" | Same as above (now stricter) | **Migrate to `Acervo.isModelConfigPresent(modelId)`** — verbatim old behavior. |
| Test code: synthesize model dir by writing only `config.json`, then assert `isModelAvailable == true` | Same as above | Returns `false` after upgrade — test breaks. | Either (a) write a manifest too, or (b) switch the assertion to `isModelConfigPresent`. |
| Consumer wants to show a downloading-progress UI | No clean way before; consumers had to poll their own state | `await Acervo.availability(modelId)` returns `.notAvailable \| .downloading(progress:) \| .available` | **Adopt `availability(_:)`** for any UI that distinguishes "absent" from "in progress". |
| Concurrent `Acervo.ensureAvailable(modelId, ...)` callers wrapped in caller-side locks | Independent downloads, wasted bandwidth | Library now dedups via `InFlightDownloads`; concurrent callers share one download | **Remove caller-side locks** wrapping `ensureAvailable` for the same `modelId`. |

If you read nothing else, read the table above.

---

### Step 1 — Find every call site

In each consumer repository that depends on SwiftAcervo:

```bash
rg -n "Acervo\.isModelAvailable" --type swift
rg -n "AcervoManager.*isModelAvailable" --type swift
```

Catalog every hit. For each, run **Step 2** — disposition the call based on intent.

If you also want to find places that could *benefit* from the new three-state API:

```bash
rg -n "isModelAvailable|isModelDownloading|downloadProgress" --type swift
```

Any of those that drives a UI state machine is a candidate for migration to `availability(_:)`.

---

### Step 2 — Disposition each `isModelAvailable` call site

For every hit found in Step 1, the disposition is one of three:

#### 2a. Disposition: **Keep as `isModelAvailable`** (the test really wanted "model is usable")

If the call lives in production code that gates whether the model can be loaded for inference (e.g., guarding an MLX load call, deciding whether to show "Open" vs "Download" in UI), the new strict semantics is exactly what you want. Leave the call as-is. The check is now stronger and prevents the class of bug where `config.json` exists but the weights file is truncated or missing.

**No code change needed.** Verify by running the consumer's test suite against 0.14.0; if a test that previously passed now fails because the synthesized fixture is incomplete, see **Step 3**.

#### 2b. Disposition: **Migrate to `isModelConfigPresent`** (the call only wanted the old loose semantics)

If the call is asking literally "does a `config.json` file exist at the model root, regardless of completeness?" — for example, deciding whether to display a half-populated row in a model picker — switch to the explicit escape hatch:

```swift
// Before (0.13.x):
if Acervo.isModelAvailable(modelId) { showRow(...) }

// After (0.14.0):
if Acervo.isModelConfigPresent(modelId) { showRow(...) }
```

`isModelConfigPresent` carries the pre-0.14.0 behavior verbatim. It exists for exactly this case.

**Note:** `isModelConfigPresent` is intentionally documented as "does NOT imply usability." If you find yourself reaching for it in production code that gates inference or download, you almost certainly want `availability(_:)` (Step 4) instead.

#### 2c. Disposition: **Migrate to `availability(_:)`** (the call drives UI that needs three states)

If the call is asking "what state is this model in, so I can render the right view?" — and the consumer currently maintains its own `isDownloading` flag alongside `isModelAvailable` — collapse both into a single `await Acervo.availability(modelId)` call. See **Step 4**.

---

### Step 3 — Fix tests that synthesize models by writing only `config.json`

This is the most common breakage. A test pattern that worked under loose semantics:

```swift
// 0.13.x — passes (loose semantics)
let modelDir = tempDir.appendingPathComponent("org_repo")
try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
try Data().write(to: modelDir.appendingPathComponent("config.json"))
#expect(Acervo.isModelAvailable("org/repo", in: tempDir) == true)
```

Fails under 0.14.0 because there is no `.acervo-manifest.json` in `modelDir` and no manifest-declared files on disk. Two fixes, depending on what the test is actually checking:

#### 3a. The test wants to assert "config.json exists" (loose-check semantics)

Switch the assertion target:

```swift
// 0.14.0 — migrated
#expect(Acervo.isModelConfigPresent("org/repo", in: tempDir) == true)
```

#### 3b. The test wants to assert "the model is fully downloaded and usable"

Seed a self-consistent manifest plus the files it declares:

```swift
// 0.14.0 — fixture properly synthesized
import CryptoKit

let modelDir = tempDir.appendingPathComponent("org_repo")
try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

let configData = Data()
try configData.write(to: modelDir.appendingPathComponent("config.json"))

// Build a manifest matching the on-disk file set.
let manifest = CDNManifest(
    files: [
        CDNManifestFile(
            path: "config.json",
            sizeBytes: Int64(configData.count),
            sha256: SHA256.hash(data: configData).hex
        )
    ],
    // ... other CDNManifest fields per the type definition
)
try AcervoDownloader.persistManifest(manifest, in: tempDir)

#expect(Acervo.isModelAvailable("org/repo", in: tempDir) == true)
```

`AcervoDownloader.persistManifest` is internal-visible and writes the manifest to `.acervo-manifest.json` at the model root with a deterministic sorted-keys encoding.

The SwiftAcervo test suite itself follows this pattern post-migration — see `Tests/SwiftAcervoTests/ModelDownloadManagerTests.swift` (the `seedFakeModel` helper) for a reference implementation.

---

### Step 4 — Adopt the three-state UI pattern (optional but recommended)

If the consumer renders model state in UI, replace the two-flag pattern with a single `availability(_:)` call.

#### Before (0.13.x — two flags, race-prone)

```swift
@State var isDownloading: Bool = false
@State var downloadProgress: Double = 0.0

var body: some View {
    if isDownloading {
        ProgressView(value: downloadProgress)
    } else if Acervo.isModelAvailable(modelId) {
        Button("Open") { open() }
    } else {
        Button("Download") {
            isDownloading = true
            Task {
                try await Acervo.ensureAvailable(modelId) { p in
                    downloadProgress = p.overallProgress
                }
                isDownloading = false
            }
        }
    }
}
```

#### After (0.14.0 — single source of truth)

```swift
@State var state: ModelAvailability = .notAvailable

var body: some View {
    switch state {
    case .notAvailable:
        Button("Download") { Task { await startDownload() } }
    case .downloading(let progress):
        ProgressView(value: progress)
    case .available:
        Button("Open") { open() }
    }
}

func refresh() async {
    state = await Acervo.availability(modelId)
}

func startDownload() async {
    Task { try? await Acervo.ensureAvailable(modelId) }
    // Poll `availability(_:)` every ~250ms to observe `.downloading(progress:)`,
    // OR observe `InFlightDownloads.shared` directly if you want push-style updates.
    while case .downloading = await Acervo.availability(modelId) {
        await refresh()
        try? await Task.sleep(for: .milliseconds(250))
    }
    await refresh()
}
```

`availability(_:)` is `async`, non-throwing, and performs zero network I/O. It is safe to call from any context, including hot UI paths.

Behavior contract:

| Condition | Returned value |
|-----------|----------------|
| `InFlightDownloads.shared` has an entry for `modelId` | `.downloading(progress: <last published value, clamped 0.0…1.0>)` |
| No in-flight download AND every manifest file is on disk at recorded size | `.available` |
| Otherwise (including "manifest is on disk but a file is missing" and "no manifest cached") | `.notAvailable` |

A `.part` file on its own does **not** report `.downloading` — `.downloading` strictly means "a Task is in flight in this process." After a hard process kill, a model with a `.part` file but no in-flight Task returns `.notAvailable`. This is intentional: the three-state API reflects in-process intent, not on-disk artifacts.

---

### Step 5 — Remove caller-side locks around `ensureAvailable` (optional)

If your consumer wrapped concurrent `Acervo.ensureAvailable(modelId, ...)` calls in a per-model lock or actor to avoid duplicate downloads, that wrapper is now redundant.

`Acervo.ensureAvailable` is backed by the `InFlightDownloads` actor: two concurrent calls for the same `modelId` share a single underlying download task. Both callers observe the same outcome (success or thrown error). The dedup key is `modelId` alone — a joiner that passes a different `files` subset rides on the originator's set. Production code that passes `files: []` (the default — everything in the manifest) is unaffected by this trade-off.

You can safely delete:
- `actor ModelDownloadCoordinator` (or equivalent) wrappers whose sole purpose was call deduplication.
- `lazy var downloadTasks: [String: Task<Void, Error>]` caches built around `ensureAvailable`.
- Any `NSLock` / `os_unfair_lock` guarding `ensureAvailable` entry points.

Keep:
- Wrappers that do anything *beyond* deduplication (telemetry, retry policy, cancellation routing).
- Per-model locks that guard *file access* after download (e.g., the `withModelAccess(_:perform:)` pattern in `AcervoManager`) — those serve a different purpose and remain necessary.

---

### Decision tree (quick reference)

```
You have a call to Acervo.isModelAvailable(modelId).
│
├─ Is the calling code gating model load / inference?
│  └─ Yes → KEEP. The new strict semantics is correct.
│
├─ Is the calling code in a test that synthesizes a fixture by writing only config.json?
│  ├─ Test wants "config.json exists"        → migrate to isModelConfigPresent (Step 3a).
│  └─ Test wants "model is fully usable"     → write a manifest fixture too (Step 3b).
│
├─ Is the calling code asking a literal "does config.json exist?" question for non-load reasons
│  (e.g., showing a partially-populated row in a picker)?
│  └─ migrate to isModelConfigPresent (Step 2b).
│
└─ Is the calling code rendering a UI state machine that needs to distinguish
   "absent" from "downloading"?
   └─ migrate to availability(_:) and remove your own isDownloading flag (Step 4).
```

```
You have a concurrent-download wrapper (lock, actor, or task cache) around ensureAvailable.
│
├─ Does the wrapper do anything besides deduplicate calls for the same modelId?
│  ├─ No  → DELETE. InFlightDownloads handles it (Step 5).
│  └─ Yes → KEEP. Deduplicate dedup, keep the rest.
```

---

### Cross-reference

- [`CHANGELOG.md`](CHANGELOG.md) § `[0.14.0]` — release-note view of these changes.
- [`Docs/MODEL_AVAILABILITY_PATH.md`](Docs/MODEL_AVAILABILITY_PATH.md) — design doc behind the three-state surface.
- [`Docs/API_REFERENCE.md`](Docs/API_REFERENCE.md) — full method signatures and parameter contracts.
- [`Docs/USAGE.md`](Docs/USAGE.md) — high-level usage patterns for consumers.

Verified consumer projects (used as migration witnesses):

- **SwiftBruja** — gates MLX model load on `isModelAvailable`. Disposition: keep (Step 2a).
- **mlx-audio-swift** — same pattern. Disposition: keep (Step 2a).
- **SwiftVoxAlta** — renders a model picker; uses both `isModelAvailable` and a custom `isDownloading` flag. Disposition: migrate to `availability(_:)` (Step 4).

If your consumer is not listed, run Step 1's `rg` patterns to enumerate call sites and apply Step 2's disposition.

---

## Upgrading to earlier versions

For migrations to 0.13.0 and earlier, see the **Migration** sections in [`CHANGELOG.md`](CHANGELOG.md) per release.
