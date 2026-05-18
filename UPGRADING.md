# Upgrading SwiftAcervo

Per-version migration guide for SwiftAcervo. Targeted at **agents reading consumer code** — patterns below are concrete enough to drive grep-and-replace decisions without further interpretation.

For design context behind each change, see [`CHANGELOG.md`](CHANGELOG.md) and [`Docs/MODEL_AVAILABILITY_PATH.md`](Docs/MODEL_AVAILABILITY_PATH.md). This file is the operational how-to.

---

## Upgrading to 0.14.0 (from 0.13.x)

0.14.0 introduces a three-state availability API and tightens the semantics of `Acervo.isModelAvailable(_:)`. The change is **source-breaking by behavior, not by signature**: every existing call still compiles, but a non-trivial fraction will return a different value.

### TL;DR

| Old call                                  | What it actually meant | What it now returns | Action |
|-------------------------------------------|------------------------|---------------------|--------|
| `Acervo.isModelAvailable(modelId)` (consumer gates inference/load) | "`config.json` exists at the model root" | `true` only if every manifest file is present at recorded size | **No code change.** The new semantics is what you actually wanted. |
| `Acervo.isModelAvailable(modelId)` (consumer only wants to probe for `config.json`) | Same | Same as above (now stricter) | **Migrate to `Acervo.isModelConfigPresent(modelId)`** — verbatim old behavior. |
| Test code: synthesize a model dir by writing only `config.json`, then assert `isModelAvailable == true` | Same | Returns `false` after upgrade — test breaks. | Either (a) write a manifest fixture too, or (b) switch the assertion to `isModelConfigPresent`. |
| Consumer renders a "downloading" UI state | No clean way before; consumers maintained their own `isDownloading` flag | `await Acervo.availability(modelId)` returns `.notAvailable \| .downloading(progress:) \| .available` | **Adopt `availability(_:)`** for any UI that distinguishes "absent" from "in progress". |
| Concurrent `Acervo.ensureAvailable(modelId, ...)` callers | Independent downloads, wasted bandwidth | Library now dedups via `InFlightDownloads`; concurrent callers share one download | **Simplify caller-side dedup** wrappers — but read Step 5 carefully before deleting them outright. |

---

### Step 1 — Find every call site

```bash
rg -n "Acervo\.isModelAvailable|AcervoManager.*isModelAvailable" --type swift
rg -n "Acervo\.ensureAvailable|Acervo\.ensureComponentReady"     --type swift
rg -n "Acervo\.modelDirectory|Acervo\.modelInfo|Acervo\.listModels" --type swift
```

For each consumer in this ecosystem, here is the verified call-site inventory as of SwiftAcervo `mission/ticket-stub/01`:

| Consumer | `isModelAvailable` sites | `ensureAvailable` / `ensureComponentReady` sites | Recommended disposition |
|----------|--------------------------|--------------------------------------------------|-------------------------|
| **SwiftBruja** | `Bruja.swift:46` (forwarder from `modelExists(id:)`), `BrujaModelManager.swift:63`, `BrujaQuery.swift:129`; test sites in `SwiftBrujaTests.swift:31, 342` (negative assertions, safe) | `BrujaCLI.swift:113` (`ensureAvailable`) | **Keep** all production sites (Step 2a). **Migrate** the test fixture at `SwiftBrujaTests.swift:563–578` (Step 3b). |
| **SwiftVoxAlta** | `VoxAltaModelManager.swift:301` | `VoxAltaModelManager.swift:479` (`ensureComponentReady`) | **Keep** the production site. **Simplify but do not delete** the actor wrapper at `VoxAltaModelManager.swift:203` (Step 5 — see "When NOT to delete"). |
| **SwiftVinetas** | `VinetasModelManager.swift:66`, `Flux2Engine.swift:418`, `PixArtEngine.swift:496` | `ImageClassifier.swift:156`, `FeatureExtractor.swift:141`, `PixArtEngine.swift:451` | **Keep** all (Step 2a). |
| **flux-2-swift-mlx** | `TextEncoderModelDownloader.swift:61, 242, 245` | `ModelDownloader.swift:254`; `TextEncoderModelDownloader.swift:148, 159, 202, 213` | **Keep** all (Step 2a). |
| **mlx-audio-swift** | none | `AudioModelManager.swift:340, 361, 401, 449` (all `ensureComponentReady`) | No `isModelAvailable` migration needed. |
| **SwiftProyecto**, **SwiftTuberia**, **glosa-av**, **pixart-swift-mlx**, **SwiftApoderado** | none direct | `ensureComponentReady` only (or no direct usage) | No `isModelAvailable` migration needed. |

**The dominant disposition is "keep"** — production guards on `isModelAvailable` exist to gate inference, which is exactly what the new strict semantics enforces. The interesting migrations are the test fixture in SwiftBruja and the actor wrapper in SwiftVoxAlta.

---

### Step 2 — Disposition each `isModelAvailable` call site

#### 2a. Disposition: **Keep as `isModelAvailable`** (production gate on model load)

The call lives in production code that decides whether the model can be loaded for inference. The new strict semantics is exactly what you want — the check is now stronger and prevents the class of bug where `config.json` exists but a weights file is truncated or missing.

**No code change needed.**

Verified examples in the ecosystem (already correct under 0.14.0):

- `SwiftBruja/Sources/SwiftBruja/Core/BrujaModelManager.swift:63` — guards `loadModel` entry.
- `SwiftBruja/Sources/SwiftBruja/Bruja.swift:46` — public `modelExists(id:)` forwarder.
- `SwiftVoxAlta/Sources/SwiftVoxAlta/VoxAltaModelManager.swift:301` — guards `loadModel(repo:)`.
- `SwiftVinetas/Sources/.../VinetasModelManager.swift:66`, `Flux2Engine.swift:418`, `PixArtEngine.swift:496` — preflight before pipeline execution.
- `flux-2-swift-mlx/Sources/.../TextEncoderModelDownloader.swift:61, 242, 245` — gate text-encoder load.

Each of these is genuinely asking "is the model fully downloaded and usable?" — and the answer is now more reliable, not different in intent.

#### 2b. Disposition: **Migrate to `isModelConfigPresent`** (only need the literal config.json probe)

If the call asks literally "does a `config.json` file exist at the model root, regardless of completeness?" — e.g., displaying a half-populated row in a model picker — switch to the explicit escape hatch:

```swift
// Before (0.13.x):
if Acervo.isModelAvailable(modelId) { showPartialRow(...) }

// After (0.14.0):
if Acervo.isModelConfigPresent(modelId) { showPartialRow(...) }
```

`isModelConfigPresent` carries the pre-0.14.0 behavior verbatim.

**No known consumers in this ecosystem need 2b.** All production `isModelAvailable` call sites surveyed gate inference, so they fall under 2a. Document the option for callers outside the ecosystem; expect to use it rarely.

#### 2c. Disposition: **Migrate to `availability(_:)`** (UI state machine needs three states)

See **Step 4** for the full rewrite pattern. Candidate consumers in this ecosystem: any with a `@State var isDownloading: Bool` paired with `isModelAvailable`. (None of the surveyed consumers had this pattern in production — most maintain download progress through their own progress callbacks rather than separate state flags.)

---

### Step 3 — Fix tests that synthesize models by writing only `config.json`

#### The pattern that breaks

Verified breaking test in this ecosystem: **`SwiftBruja/Tests/SwiftBrujaTests/SwiftBrujaTests.swift:563–578`**:

```swift
// Seed the per-test SharedModels directory so Acervo.isModelAvailable returns true
// (avoids real CDN download while still exercising the call boundary).
let tempBase = Acervo.sharedModelsDirectory
try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
let slug = Acervo.slugify(unregisteredRepoId)
let modelDir = tempBase.appendingPathComponent(slug)
try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
try "{}".write(
  to: modelDir.appendingPathComponent("config.json"),
  atomically: true,
  encoding: .utf8
)

// `Acervo.ensureAvailable` must NOT throw when model is already available (force: false)
try await Acervo.ensureAvailable(unregisteredRepoId, files: []) { _ in }
```

Under 0.14.0, `Acervo.isModelAvailable` returns `false` because there is no `.acervo-manifest.json` in `modelDir`. `ensureAvailable` then proceeds to download — which fails in the test environment. **Two fixes**, depending on what the test is actually asserting.

#### 3a. The test only asserts "config.json exists"

Switch the assertion target:

```swift
// 0.14.0 — migrated to the explicit loose-check API
#expect(Acervo.isModelConfigPresent(unregisteredRepoId, in: tempBase) == true)
```

Use this if the test's intent is "the config file is present" — not "the model is downloaded and usable."

#### 3b. The test needs the model to look "fully downloaded"

Seed a self-consistent manifest alongside the file set. Use the real `CDNManifest` and `CDNManifestFile` initializers:

```swift
import CryptoKit
import SwiftAcervo

let modelDir = tempBase.appendingPathComponent(slug)
try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

// 1. Write each declared file with deterministic content so SHA + size are stable.
let configData = Data("{}".utf8)
try configData.write(to: modelDir.appendingPathComponent("config.json"))

let configEntry = CDNManifestFile(
    path: "config.json",
    sha256: SHA256.hash(data: configData).map { String(format: "%02x", $0) }.joined(),
    sizeBytes: Int64(configData.count)
)

// 2. Build a manifest whose manifestChecksum self-validates.
let manifest = CDNManifest(
    manifestVersion: CDNManifest.supportedVersion,
    modelId: unregisteredRepoId,
    slug: slug,
    updatedAt: ISO8601DateFormatter().string(from: Date()),
    files: [configEntry],
    manifestChecksum: CDNManifest.computeChecksum(from: [configEntry.sha256])
)

// 3. Persist it to disk where Acervo.isModelAvailable looks for it.
try AcervoDownloader.persistManifest(manifest, in: tempBase)

// Now isModelAvailable returns true:
#expect(Acervo.isModelAvailable(unregisteredRepoId, in: tempBase) == true)
try await Acervo.ensureAvailable(unregisteredRepoId, files: []) { _ in }
```

Key API references:
- `CDNManifest.init(manifestVersion:modelId:slug:updatedAt:files:manifestChecksum:)` — full memberwise initializer.
- `CDNManifest.supportedVersion` — current schema version constant (use this rather than a literal `1` so future bumps are picked up automatically).
- `CDNManifest.computeChecksum(from: [String]) -> String` — canonical checksum-of-checksums helper. Pass the list of file `sha256` values in any order; the helper sorts internally.
- `AcervoDownloader.persistManifest(_:in:)` — writes `.acervo-manifest.json` to `{baseDirectory}/{slug}/` atomically.

`AcervoDownloader.persistManifest` is `internal` to the SwiftAcervo module, so it is accessible from any test target with `@testable import SwiftAcervo`. Test targets that already `import SwiftAcervo` non-testable should add `@testable` for the migrated fixture.

SwiftAcervo's own `ModelDownloadManagerTests.swift` `seedFakeModel` helper is the reference implementation if you want a copy-paste-ready version.

---

### Step 4 — Adopt the three-state UI pattern (optional)

Replace any two-flag pattern (`isModelAvailable` + `isDownloading`) with a single `availability(_:)` call.

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
.task { await refresh() }

func refresh() async {
    state = await Acervo.availability(modelId)
}

func startDownload() async {
    Task { try? await Acervo.ensureAvailable(modelId) }
    // Poll availability(_:) every ~250ms while the download is in flight.
    while case .downloading = await Acervo.availability(modelId) {
        await refresh()
        try? await Task.sleep(for: .milliseconds(250))
    }
    await refresh()
}
```

`availability(_:)` is `async`, non-throwing, and performs zero network I/O — safe to call from any context.

Behavior contract:

| Condition | Returned value |
|-----------|----------------|
| `InFlightDownloads.shared` has an entry for `modelId` (an `ensureAvailable` task is in flight in this process) | `.downloading(progress: <last published value, clamped 0.0…1.0>)` |
| No in-flight download AND every manifest file is on disk at recorded size | `.available` |
| Otherwise (manifest missing, file missing, size mismatch) | `.notAvailable` |

A `.part` file on its own does **not** report `.downloading` — `.downloading` strictly means "a Task is in flight in *this* process." After a hard process kill, a model with a `.part` file but no in-flight Task returns `.notAvailable`. This is intentional: the three-state API reflects in-process intent, not on-disk artifacts.

---

### Step 5 — Simplify caller-side dedup wrappers

`Acervo.ensureAvailable` is now backed by the `InFlightDownloads` actor: two concurrent calls for the same `modelId` share a single underlying download task. Both observers receive the same outcome. The dedup key is `modelId` alone — a joiner that passes a different `files` subset rides on the originator's set.

This **does not mean** every caller-side dedup wrapper can be deleted. The wrapper may dedup the *download* step alone (which is now redundant), OR it may dedup the download plus *post-download work* like model decoding, MLX mmap, or GPU upload (which SwiftAcervo cannot know about). Read the wrapper's scope before touching it.

#### When you CAN delete the wrapper

Delete only if the wrapper's sole job is to dedup the SwiftAcervo download call. Markers of this case:

- The wrapper's protected critical section is exactly an `await Acervo.ensureAvailable(...)` call, with no further work after it inside the lock.
- The "in-flight" key the wrapper uses is `modelId` (or equivalent — repo ID, component ID).
- There is no separate post-download cache (loaded model object, decoded tensors) that the wrapper is also coordinating.

If all three hold, the wrapper is redundant. Delete the lock and call `Acervo.ensureAvailable` directly.

#### When you must KEEP the wrapper (but can simplify it)

Verified example in this ecosystem: **`SwiftVoxAlta/Sources/SwiftVoxAlta/VoxAltaModelManager.swift:203–443`** — `public actor VoxAltaModelManager` with an `inFlightLoad: (repo: String, task: Task<LoadedModelBox, Error>)?` member at line 229. The wrapper's purpose is documented at lines 221–228:

```swift
/// In-flight load coordination. Concurrent callers requesting the same
/// repo await this Task instead of each starting their own load.
///
/// Without this, actor reentrancy across the awaits inside `loadModel`
/// (e.g. `Acervo.ensureComponentReady`) lets every concurrent caller pass
/// the cache check before any one finishes, multiplying the model's memory
/// footprint by N. With N envelope-driven calls each mmapping a ~4 GB
/// model, virtual footprint reaches tens of GB and the OS reclaims us.
```

The wrapper coordinates **both** the download (via `Acervo.ensureComponentReady` at line 479) **and** the MLX-side model load (mmap of ~4 GB weights). SwiftAcervo 0.14.0 dedups the download portion. The MLX load is still SwiftVoxAlta's job and still needs the actor's `inFlightLoad` coordination — without it, N concurrent loads each mmap N copies and the OS reclaims the process.

**Disposition for SwiftVoxAlta:** keep the actor wrapper unchanged. The `inFlightLoad` member is still load-bearing for the MLX side. You may add a doc-comment noting that the `Acervo.ensureComponentReady` portion is now also dedup'd at the library layer, but the wrapper's critical-section coverage of `mmap` + load is the actual reason it exists.

#### Decision matrix

```
Your wrapper's critical section is …
│
├─ … only an Acervo.ensureAvailable / ensureComponentReady call.
│  └─ DELETE the wrapper. Call Acervo directly.
│
├─ … an Acervo call + post-download work (MLX load, weight decode, GPU upload).
│  └─ KEEP the wrapper. The post-download work still needs coordination.
│     Optionally annotate that the Acervo portion is now library-dedup'd too.
│
└─ … wrapping Acervo + telemetry / retry / cancellation routing.
   └─ KEEP. Dedup is incidental; you'd be deleting unrelated infrastructure.
```

`AcervoManager`'s `withModelAccess(_:perform:)` per-model lock is a different mechanism — it serializes *file access* after download. That lock stays; it is unrelated to download dedup.

---

### Decision tree (quick reference)

```
You have a call to Acervo.isModelAvailable(modelId).
│
├─ Is the calling code gating model load / inference?
│  └─ Yes → KEEP. The new strict semantics is correct.
│
├─ Is the calling code in a test that synthesizes a fixture by writing only config.json?
│  ├─ Test wants "config.json exists"     → migrate to isModelConfigPresent (Step 3a).
│  └─ Test wants "model is fully usable"  → write a manifest fixture too (Step 3b).
│
├─ Is the calling code asking a literal "does config.json exist?" question for non-load reasons?
│  └─ migrate to isModelConfigPresent (Step 2b).
│
└─ Is the calling code rendering a UI state machine that distinguishes "absent" from "downloading"?
   └─ migrate to availability(_:) and remove your own isDownloading flag (Step 4).

You have a concurrent-download wrapper around ensureAvailable / ensureComponentReady.
│
├─ Critical section is ONLY the Acervo call → DELETE wrapper (Step 5).
├─ Critical section spans download + post-download work → KEEP wrapper (Step 5).
└─ Wrapper also handles telemetry / retry → KEEP wrapper.
```

---

### Cross-reference

- [`CHANGELOG.md`](CHANGELOG.md) § `[0.14.0]` — release-note view.
- [`Docs/MODEL_AVAILABILITY_PATH.md`](Docs/MODEL_AVAILABILITY_PATH.md) — design doc behind the three-state surface.
- [`Docs/API_REFERENCE.md`](Docs/API_REFERENCE.md) — full method signatures.
- [`Docs/USAGE.md`](Docs/USAGE.md) — high-level usage patterns.

Verified consumer call-site inventory (as of the dev→main PR landing 0.13.2 + 0.14.0): see the table in Step 1. If your consumer is not listed, run Step 1's `rg` patterns to enumerate call sites and apply Step 2's disposition.

---

## Upgrading to earlier versions

For migrations to 0.13.0 and earlier, see the **Migration** sections in [`CHANGELOG.md`](CHANGELOG.md) per release.
