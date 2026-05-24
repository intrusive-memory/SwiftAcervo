# Upgrading SwiftAcervo

Per-version migration guide for SwiftAcervo. Targeted at **agents reading consumer code** — patterns below are concrete enough to drive grep-and-replace decisions without further interpretation.

For design context behind each change, see [`CHANGELOG.md`](CHANGELOG.md) and [`Docs/USAGE-library.md`](Docs/USAGE-library.md). This file is the operational how-to.

---

## The goal of every upgrade: stop poking the filesystem; ask the library

SwiftAcervo's design philosophy, hardened through every release since 0.13 and made first-class in 0.16, is a single rule:

> **The CDN manifest is the sole authoritative source for what a model is.** Consumers MUST NOT enumerate the model directory, hardcode `safetensors` / `tokenizer.json` / `config.json` filenames, or derive on-disk paths from an `org/repo` string by hand. Every question about a model — "is it ready?", "what files does it have?", "where do they live on disk?", "which shards are missing?", "is it downloading?" — has a `SwiftAcervo` accessor. Use it.

Why this matters operationally:

1. **The CDN can change a model's file set without changing the model ID.** Quantization swaps, shard re-tiling, vocabulary updates — all happen via manifest revisions. Consumers that hardcode filenames silently rot. Consumers that iterate `manifest.files` keep working.
2. **Multi-component models** (e.g. FLUX.2: transformer + VAE + 2 text encoders, each with its own HF repo) cannot be addressed by `org/repo` alone. The slug-keyed APIs introduced in 0.16 fan out across components inside the library; the consumer hands over a slug and gets an aggregate answer.
3. **Validity is non-trivial.** A model directory containing `config.json` and a 12-GB `model.safetensors` may still be `.partial` if a tokenizer shard went missing. The library's `ValidityOracle` checks every manifest entry by size; you cannot replicate this cheaply or correctly outside the library.
4. **Filesystem layout is not stable across hosts.** App Group containers move between iOS and macOS, and between sandboxed and CLI processes. `Acervo.modelDirectory(for:)` is the only correct way to get a URL.

**If you are writing or auditing a consumer**, every `FileManager.default.contentsOfDirectory(...)` against a SwiftAcervo-managed directory is a bug, every hardcoded file name is a bug, and every `URL(fileURLWithPath: "\(home)/SharedModels/\(slug)")` is a bug. The library APIs that replace each of these are listed in the per-version sections below.

---

## Upgrading to 0.16.0 (from 0.15.x)

0.16.0 lands two large bodies of work simultaneously: an **internal decomposition** of `Acervo.swift` (no public API change) and a **slug-keyed availability API** with a fourth `ModelAvailability` case (`partial`). The decomposition is a no-op for consumers; the new case is a switch-exhaustiveness break.

### TL;DR

| Change | Affects consumers? | Action |
|---|---|---|
| `Acervo.swift` split into 15 `Acervo+*.swift` files | No — symbols unchanged | None. Agents pattern-matching against source paths must update. |
| New `ModelAvailability.partial(missing: [String])` case | Yes — switch exhaustiveness break | Add a `case .partial` arm wherever you switch over `ModelAvailability`. |
| New `availability(slug:url:)`, `ensureAvailable(slug:url:files:progress:)`, `deleteModel(slug:url:)` | Additive | Adopt for any model addressed by a deployment slug instead of `org/repo`. |
| `CDNManifest.primaryRepo` and `CDNManifest.components` now required wire fields | Yes — old manifests on disk that lack them fail strict decode | Re-publish affected models with the current `acervo ship` (writes both fields). |
| `acervo ship` gains `--slug`, `--spec`, `--dry-run`, `--output-dir` flags | Additive (CLI) | Adopt the spec-driven workflow for multi-component uploads. |
| `Acervo.listModels()` now filters by validity (skips directories without `config.json`) | Yes — empty/orphan dirs no longer enumerate | Use `Acervo.gcEmptyModelDirectories()` to reclaim them explicitly. |

### Step 1 — Handle the new `ModelAvailability.partial` case

Every `switch` over `ModelAvailability` is now non-exhaustive. The new case fires when the model was downloaded once, then a shard went missing afterwards.

```swift
// Before (0.14.x – 0.15.x)
switch await Acervo.availability(modelId) {
case .notAvailable:
    Button("Download") { ... }
case .downloading(let p):
    ProgressView(value: p)
case .available:
    Button("Open") { ... }
}

// After (0.16.0)
switch await Acervo.availability(modelId) {
case .notAvailable:
    Button("Download") { ... }
case .downloading(let p):
    ProgressView(value: p)
case .partial(let missing):
    // The model was downloaded, but `missing` files are gone.
    // Most consumers want to re-issue ensureAvailable to refill.
    Button("Repair (\(missing.count) file\(missing.count == 1 ? "" : "s") missing)") {
        Task { try? await Acervo.ensureAvailable(modelId, files: []) }
    }
case .available:
    Button("Open") { ... }
}
```

**`partial` vs `notAvailable`.** `.notAvailable` means "never downloaded (or wholly deleted), and no download is in flight." `.partial` means "was downloaded successfully at some point; at least one declared file is missing or size-mismatched now." Treat them differently in UI: `.partial` is a *repair* action; `.notAvailable` is a *download* action.

**Detection only — remediation is yours.** The library reports `.partial` and names the missing files. It does not auto-redownload. Call `Acervo.ensureAvailable(modelId, files: [])` (empty array = "everything in manifest") to fill the gaps.

### Step 2 — Adopt slug-keyed APIs for non-`org/repo` models

If you are addressing a model by a deployment slug that does not parse as `org/repo` (e.g. `flux2-klein-4b`, internal codenames, multi-component bundles), use the new slug-keyed surface. These methods fetch the CDN manifest, discover the component list, and aggregate per-component states inside the library.

```swift
// Three new public methods, all in slug-keyed form:
let state = try await Acervo.availability(slug: "flux2-klein-4b",
                                          url: URL(string: "https://cdn.example/flux2-klein-4b/manifest.json")!)

try await Acervo.ensureAvailable(slug: "flux2-klein-4b",
                                 url: manifestURL,
                                 files: [])     // [] = every file in every component

try await Acervo.deleteModel(slug: "flux2-klein-4b", url: manifestURL)
```

**Slug + URL resolution rule (identical across all three methods):**

| Form | Behavior |
|---|---|
| Slug parses as `org/repo`, `url: nil` | Manifest URL derived from slug via the canonical CDN pattern. |
| Slug parses as `org/repo`, `url:` supplied | Supplied URL used verbatim. Slug becomes the on-disk directory key. |
| Slug does NOT parse as `org/repo`, `url: nil` | Throws `AcervoError.urlRequiredForSlug(slug)`. |
| Slug does NOT parse as `org/repo`, `url:` supplied | Supplied URL used verbatim. |

**Aggregation across components.** For a slug whose manifest declares N components, `availability(slug:url:)` fans out and aggregates:

- Every component `.available` → `.available`
- Any component `.downloading` → `.downloading(weightedAverage)` (weight = component's total bytes)
- Any component `.partial` → `.partial(missing: <union of every component's missing files>)`
- Otherwise → `.notAvailable`

You never see per-component states unless you call the per-component APIs yourself. This is the philosophy in action: the consumer asks one question, the library does the fan-out.

### Step 3 — Audit any code that reads `CDNManifest` for `primaryRepo` / `components`

These two fields were `Optional` (defaulted to single-component) in earlier patch versions; in 0.16.0 they are **required on the wire** by strict JSON decode. Manifests written by `acervo ship` 0.16.0+ always carry them. Manifests written by older `acervo` versions and still cached locally (`.acervo-manifest.json` files) will decode fine because the in-memory initializer still applies the single-component default.

**Action:** if you have CI or test fixtures that hand-write CDN manifest JSON, ensure they include `primaryRepo` and `components`. The single-component default is `primaryRepo = modelId`, `components = [modelId]`.

```swift
// Test-fixture pattern (0.16.0-correct):
let manifest = CDNManifest(
    manifestVersion: CDNManifest.supportedVersion,
    modelId: "mlx-community/Qwen2.5-7B-Instruct-4bit",
    slug: "mlx-community_Qwen2.5-7B-Instruct-4bit",
    updatedAt: ISO8601DateFormatter().string(from: Date()),
    files: files,
    manifestChecksum: CDNManifest.computeChecksum(from: files.map(\.sha256))
    // primaryRepo and components omitted → defaults to single-component
)
```

### Step 4 — Update agent-readable references after the source decomposition

`Sources/SwiftAcervo/Acervo.swift` was ~3,500 lines in 0.15; in 0.16 it is a 51-line enum shell. Symbols moved to 15 focused extensions but **public names and signatures are unchanged**. If you have:

- Tooling that greps `Acervo.swift` for a method → switch to globbing `Sources/SwiftAcervo/Acervo*.swift`.
- AGENTS.md / CLAUDE.md notes that quote a line range in `Acervo.swift` → those line refs are stale; refer to the file by name instead.
- IDE jump-to-definition behaviors that hardcode the file → no action needed; Swift's index-store still resolves the symbol correctly.

New file map (all in `Sources/SwiftAcervo/`):

| File | What's in it |
|---|---|
| `Acervo.swift` | 51-line enum shell + `version` constant |
| `Acervo+PathResolution.swift` | `sharedModelsDirectory`, `slugify`, `modelDirectory`, `ensureModelDirectory` |
| `Acervo+ManifestAccess.swift` | `fetchManifest(for:)`, `fetchManifest(forComponent:)` |
| `Acervo+Discovery.swift` | `listModels`, `modelInfo`, `modelFamilies`, `gcEmptyModelDirectories` |
| `Acervo+Search.swift` | `findModels(matching:)`, `closestModel` |
| `Acervo+Availability.swift` | repo-keyed `availability(_:)`, `isModelAvailable`, `isModelConfigPresent`, `modelFileExists` |
| `Acervo+SlugAvailability.swift` | slug-keyed `availability(slug:url:)` |
| `Acervo+EnsureAvailable.swift` | both repo- and slug-keyed `ensureAvailable` |
| `Acervo+Download.swift` | low-level `download(_:files:...)` |
| `Acervo+DeleteModel.swift` | repo- and slug-keyed `deleteModel` |
| `Acervo+ComponentCatalog.swift` | `registeredComponents`, `pendingComponents`, `totalCatalogSize`, `isComponentReady` |
| `Acervo+ComponentRegistration.swift` | `register`, `unregister` |
| `Acervo+ComponentDownloads.swift` | `downloadComponent`, `ensureComponentReady`, `ensureComponentsReady`, `deleteComponent` |
| `Acervo+ComponentIntegrity.swift` | `verifyComponent`, `verifyAllComponents` |
| `Acervo+Hydration.swift` | `hydrateComponent` |
| `Acervo+CDNMutation.swift` | `publishModel`, `deleteFromCDN`, `recache` |

### Step 5 — Replace any remaining filesystem-poking with library calls

This is the upgrade philosophy enforcement step. Sweep your consumer for the patterns below and convert each to its library equivalent. The 0.16 surface covers every case.

| Anti-pattern | Library replacement |
|---|---|
| `FileManager.default.contentsOfDirectory(at: someModelDir)` to enumerate files | `try await Acervo.fetchManifest(for: modelId).files` (CDN view) **or** iterate `manifest.files` from a previously cached manifest |
| Hardcoded `"model.safetensors"` / `"config.json"` filename literals | `manifest.file(at: pathSuffix)` returns the `CDNManifestFile` (sha + size) or `nil`. Never hardcode. |
| Hand-built `URL(fileURLWithPath: ...)` to a model directory | `try Acervo.modelDirectory(for: modelId)` |
| Custom "is the model downloaded?" check via file existence | `Acervo.isModelAvailable(modelId)` (strict, manifest-aware) |
| Polling for "downloading" via your own `isDownloading: Bool` flag | `await Acervo.availability(modelId)` returns `.downloading(progress:)` straight from the library's in-flight registry |
| Manual scan for empty / orphaned model directories | `try Acervo.gcEmptyModelDirectories()` — returns the URLs it reclaimed |
| Custom multi-component aggregation | `try await Acervo.availability(slug:url:)` does the fan-out for you |
| `glob` patterns to find safetensor shards | `manifest.files.filter { $0.path.hasSuffix(".safetensors") }` — but only after asking yourself whether you actually need this; usually iterating *all* manifest files is what you want |

If you find a case the library does not cover, file an issue rather than reaching around. The omission is the bug.

### Step 6 — Adopt the new `acervo ship` flags (CLI consumers only)

The CLI surface gained four flags:

| Flag | Use |
|---|---|
| `--slug <slug>` | Rename the model in the CDN to a deployment-friendly slug, decoupling it from the HF `org/repo`. |
| `--spec <file>` | Multi-component upload. The JSON spec declares the primary repo and an ordered component list; the CLI iterates each component. |
| `--dry-run` | Generate the manifest from local files, write it to `--output-dir`, perform no network calls. Useful for CI manifest-only verification. |
| `--output-dir <dir>` | Where to drop the generated manifest in `--dry-run` mode (defaults to the staging directory). |

```bash
# Single-component, renamed in CDN:
acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit --slug qwen-7b

# Multi-component upload from spec:
acervo ship --spec flux2-klein.json

# Dry run — manifest only, no upload:
acervo ship --spec flux2-klein.json --dry-run --output-dir ./manifest-out
```

`--keep-orphans` (introduced in 0.15) still applies.

### Cross-reference

- [`CHANGELOG.md`](CHANGELOG.md) § `[0.16.0]` — release-note view.
- [`Docs/USAGE-library.md`](Docs/USAGE-library.md) — full library API reference.
- [`Docs/USAGE-cli.md`](Docs/USAGE-cli.md) — full CLI reference (every subcommand + flag).
- [`Docs/CDN_ARCHITECTURE.md`](Docs/CDN_ARCHITECTURE.md) — manifest format + verification properties.

---

## Upgrading to 0.15.0 (from 0.14.x)

0.15.0 is a **CDN upload pipeline rewrite** with two operator-visible changes: the `aws` CLI is no longer required, and orphan keys on the CDN are now pruned by default after a successful publish.

### TL;DR

| Change | Affects you if … | Action |
|---|---|---|
| `aws` CLI removed as a runtime dependency | Your CI installs `aws` for `acervo ship` / `acervo upload` | Remove the `aws` install step. `hf` (HuggingFace CLI) is still required by `ship` / `download`. |
| Orphan prune is now default | You rely on `ship` / `upload` adding files without removing stale ones | Add `--keep-orphans` to your invocation to restore additive-only behavior. |
| `CDNUploader` (internal) deleted | You wrote a third-party tool that linked against `CDNUploader` directly | Call `Acervo.publishModel(modelId:directory:credentials:keepOrphans:progress:)` instead. |

### Step 1 — Drop the `aws` CLI from CI

If your workflow installs `aws` solely for SwiftAcervo:

```yaml
# Before (0.14.x)
- name: Install AWS CLI
  run: |
    curl ... awscliv2.zip
    unzip awscliv2.zip && sudo ./aws/install

# After (0.15.0+)
# (delete the step entirely — SwiftAcervo no longer invokes `aws`)
```

CDN uploads now go through the library's native SigV4 client (`Acervo.publishModel`), which uses `URLSession`. The `aws` binary is not checked for, not invoked, and not part of the runtime contract.

`hf` (HuggingFace CLI) is still required by `acervo ship` (for source downloads) and `acervo download`. Keep it.

### Step 2 — Decide whether you want orphan prune on or off

After a successful publish, CDN keys not referenced by the new manifest are deleted by default. This matches the manifest-truth model that `recache` already followed. The previous additive-only behavior (no deletes) is preserved via a new `--keep-orphans` flag.

```bash
# 0.15.0 default — prunes stale CDN keys after upload:
acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit

# Restore the 0.14.x additive-only behavior:
acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit --keep-orphans
```

**Operator upgrade check:** review every `ship` / `upload` invocation in CI, in cron, in deploy scripts. If you intentionally co-host multiple model versions under the same slug, add `--keep-orphans` everywhere those flows run. Otherwise the next ship will delete the prior version.

### Step 3 — If you depended on `CDNUploader`, migrate to `publishModel`

`CDNUploader` was always internal, but any third-party tool that linked SwiftAcervo for upload purposes by reaching into internals must now use the public API:

```swift
// Before (0.14.x — reached into internal type)
let uploader = CDNUploader(...)
try await uploader.sync(...)

// After (0.15.0)
try await Acervo.publishModel(
    modelId: "mlx-community/Qwen2.5-7B-Instruct-4bit",
    directory: stagingDirectoryURL,
    credentials: credentials,    // S3CDNCredentials
    keepOrphans: false,           // matches the CLI's default
    progress: { progress in ... }
)
```

`Acervo.publishModel` drives the SigV4 path end-to-end: manifest generation, file upload, post-upload manifest readback verification, and (unless `keepOrphans: true`) orphan deletion.

### Cross-reference

- [`CHANGELOG.md`](CHANGELOG.md) § `[0.15.0]` — release-note view.
- [`Docs/USAGE-cli.md`](Docs/USAGE-cli.md) — full `acervo ship` / `acervo upload` flag reference.
- [`Docs/CDN_ARCHITECTURE.md`](Docs/CDN_ARCHITECTURE.md) — SigV4 upload path and verification properties.

---

## Upgrading to 0.14.1 (from 0.14.0)

0.14.1 removed the `AcervoMigration` utility that handled the long-deprecated `intrusive-memory/Models/` cache path. This path has not been the canonical location since 0.12 (the App Group `SharedModels/` layout has been the single supported path since then).

### TL;DR

| Change | Affects you if … | Action |
|---|---|---|
| `AcervoMigration` type removed | You imported `AcervoMigration` directly | Delete the import and the call site. The path it migrated from has been dead since 0.12; consumers reaching the canonical App Group layout in any 0.12+ environment have nothing to migrate from. |

### Step 1 — Grep for any `AcervoMigration` references

```bash
rg -n "AcervoMigration" --type swift
```

If you find hits, delete them. The migration was a one-shot for users coming from the pre-0.12 layout, and any consumer that has run 0.12 / 0.13 / 0.14.0 against the canonical App Group container has already completed (or trivially no-op'd) the migration.

If a consumer is somehow on 0.14.1 without ever having touched 0.12 – 0.14.0, the dead path is empty and the migration is unnecessary.

### Cross-reference

- [`CHANGELOG.md`](CHANGELOG.md) — `[0.14.1]` entry (release notes only).

---

## Upgrading to 0.14.0 (from 0.13.x)

0.14.0 introduces a three-state availability API and tightens the semantics of `Acervo.isModelAvailable(_:)`. The change is **source-breaking by behavior, not by signature**: every existing call still compiles, but a non-trivial fraction will return a different value.

> Note for consumers leapfrogging from 0.13.x straight to 0.16.0: read 0.14.0 first (semantic break on `isModelAvailable`), then 0.16.0 (the new `.partial` case extends `availability(_:)` to four states).

### TL;DR

| Old call | What it actually meant | What it now returns | Action |
|---|---|---|---|
| `Acervo.isModelAvailable(modelId)` (consumer gates inference/load) | "`config.json` exists at the model root" | `true` only if every manifest file is present at recorded size | **No code change.** The new semantics is what you actually wanted. |
| `Acervo.isModelAvailable(modelId)` (consumer only wants to probe for `config.json`) | Same | Same as above (now stricter) | **Migrate to `Acervo.isModelConfigPresent(modelId)`** — verbatim old behavior. |
| Test code: synthesize a model dir by writing only `config.json`, then assert `isModelAvailable == true` | Same | Returns `false` after upgrade — test breaks. | Either (a) write a manifest fixture too, or (b) switch the assertion to `isModelConfigPresent`. |
| Consumer renders a "downloading" UI state | No clean way before; consumers maintained their own `isDownloading` flag | `await Acervo.availability(modelId)` returns `.notAvailable \| .downloading(progress:) \| .available` | **Adopt `availability(_:)`** for any UI that distinguishes "absent" from "in progress". |
| Concurrent `Acervo.ensureAvailable(modelId, ...)` callers | Independent downloads, wasted bandwidth | Library now dedups via `InFlightDownloads`; concurrent callers share one download | **Simplify caller-side dedup** wrappers — but read Step 5 carefully before deleting them outright. |

### Step 1 — Find every call site

```bash
rg -n "Acervo\.isModelAvailable|AcervoManager.*isModelAvailable" --type swift
rg -n "Acervo\.ensureAvailable|Acervo\.ensureComponentReady"     --type swift
rg -n "Acervo\.modelDirectory|Acervo\.modelInfo|Acervo\.listModels" --type swift
```

For each consumer in this ecosystem, here is the verified call-site inventory as of SwiftAcervo `mission/ticket-stub/01`:

| Consumer | `isModelAvailable` sites | `ensureAvailable` / `ensureComponentReady` sites | Recommended disposition |
|---|---|---|---|
| **SwiftBruja** | `Bruja.swift:46` (forwarder from `modelExists(id:)`), `BrujaModelManager.swift:63`, `BrujaQuery.swift:129`; test sites in `SwiftBrujaTests.swift:31, 342` (negative assertions, safe) | `BrujaCLI.swift:113` (`ensureAvailable`) | **Keep** all production sites (Step 2a). **Migrate** the test fixture at `SwiftBrujaTests.swift:563–578` (Step 3b). |
| **SwiftVoxAlta** | `VoxAltaModelManager.swift:301` | `VoxAltaModelManager.swift:479` (`ensureComponentReady`) | **Keep** the production site. **Simplify but do not delete** the actor wrapper at `VoxAltaModelManager.swift:203` (Step 5 — see "When NOT to delete"). |
| **SwiftVinetas** | `VinetasModelManager.swift:66`, `Flux2Engine.swift:418`, `PixArtEngine.swift:496` | `ImageClassifier.swift:156`, `FeatureExtractor.swift:141`, `PixArtEngine.swift:451` | **Keep** all (Step 2a). |
| **flux-2-swift-mlx** | `TextEncoderModelDownloader.swift:61, 242, 245` | `ModelDownloader.swift:254`; `TextEncoderModelDownloader.swift:148, 159, 202, 213` | **Keep** all (Step 2a). |
| **mlx-audio-swift** | none | `AudioModelManager.swift:340, 361, 401, 449` (all `ensureComponentReady`) | No `isModelAvailable` migration needed. |
| **SwiftProyecto**, **SwiftTuberia**, **glosa-av**, **pixart-swift-mlx**, **SwiftApoderado** | none direct | `ensureComponentReady` only (or no direct usage) | No `isModelAvailable` migration needed. |

**The dominant disposition is "keep"** — production guards on `isModelAvailable` exist to gate inference, which is exactly what the new strict semantics enforces. The interesting migrations are the test fixture in SwiftBruja and the actor wrapper in SwiftVoxAlta.

### Step 2 — Disposition each `isModelAvailable` call site

#### 2a. Disposition: **Keep as `isModelAvailable`** (production gate on model load)

The call lives in production code that decides whether the model can be loaded for inference. The new strict semantics is exactly what you want — the check is now stronger and prevents the class of bug where `config.json` exists but a weights file is truncated or missing.

**No code change needed.**

#### 2b. Disposition: **Migrate to `isModelConfigPresent`** (only need the literal config.json probe)

If the call asks literally "does a `config.json` file exist at the model root, regardless of completeness?" — e.g., displaying a half-populated row in a model picker — switch to the explicit escape hatch:

```swift
// Before (0.13.x):
if Acervo.isModelAvailable(modelId) { showPartialRow(...) }

// After (0.14.0):
if Acervo.isModelConfigPresent(modelId) { showPartialRow(...) }
```

`isModelConfigPresent` carries the pre-0.14.0 behavior verbatim.

#### 2c. Disposition: **Migrate to `availability(_:)`** (UI state machine needs three or four states)

See **Step 4** for the full rewrite pattern. In 0.16.0 the case set grew to four (`.partial` added) — handle it from the start if you are upgrading past 0.16.

### Step 3 — Fix tests that synthesize models by writing only `config.json`

#### The pattern that breaks

A test that creates a model directory and writes only `config.json` will see `isModelAvailable == false` post-upgrade because the manifest fixture is missing. **Two fixes**, depending on what the test is actually asserting.

#### 3a. The test only asserts "config.json exists"

Switch the assertion target:

```swift
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

#expect(Acervo.isModelAvailable(unregisteredRepoId, in: tempBase) == true)
try await Acervo.ensureAvailable(unregisteredRepoId, files: []) { _ in }
```

Key API references:
- `CDNManifest.init(manifestVersion:modelId:slug:updatedAt:files:manifestChecksum:primaryRepo:components:)` — full memberwise initializer; `primaryRepo` and `components` default to single-component shape.
- `CDNManifest.supportedVersion` — current schema version constant (use this rather than a literal `1` so future bumps are picked up automatically).
- `CDNManifest.computeChecksum(from: [String]) -> String` — canonical checksum-of-checksums helper.
- `AcervoDownloader.persistManifest(_:in:)` — writes `.acervo-manifest.json` to `{baseDirectory}/{slug}/` atomically.

`AcervoDownloader.persistManifest` is `internal` to the SwiftAcervo module, so it is accessible from any test target with `@testable import SwiftAcervo`.

### Step 4 — Adopt the multi-state UI pattern

Replace any two-flag pattern (`isModelAvailable` + `isDownloading`) with a single `availability(_:)` call. **If you are upgrading past 0.16.0, handle `.partial` from the start.**

```swift
@State var state: ModelAvailability = .notAvailable

var body: some View {
    switch state {
    case .notAvailable:
        Button("Download") { Task { await startDownload() } }
    case .downloading(let progress):
        ProgressView(value: progress)
    case .partial(let missing):
        Button("Repair (\(missing.count) missing)") { Task { await startDownload() } }
    case .available:
        Button("Open") { open() }
    }
}
.task { await refresh() }

func refresh() async {
    state = await Acervo.availability(modelId)
}

func startDownload() async {
    Task { try? await Acervo.ensureAvailable(modelId, files: []) }
    while case .downloading = await Acervo.availability(modelId) {
        await refresh()
        try? await Task.sleep(for: .milliseconds(250))
    }
    await refresh()
}
```

`availability(_:)` is `async`, non-throwing, and performs zero network I/O — safe to call from any context.

### Step 5 — Simplify caller-side dedup wrappers

`Acervo.ensureAvailable` is now backed by the `InFlightDownloads` actor: two concurrent calls for the same `modelId` share a single underlying download task. The dedup key is `modelId` alone.

#### When you CAN delete the wrapper

Delete only if the wrapper's sole job is to dedup the SwiftAcervo download call:

- The wrapper's protected critical section is exactly an `await Acervo.ensureAvailable(...)` call, with no further work after it inside the lock.
- The "in-flight" key the wrapper uses is `modelId` (or equivalent).
- There is no separate post-download cache (loaded model object, decoded tensors) that the wrapper is also coordinating.

#### When you must KEEP the wrapper

Example: **`SwiftVoxAlta/Sources/SwiftVoxAlta/VoxAltaModelManager.swift:203–443`** — `public actor VoxAltaModelManager` with an `inFlightLoad` member. The wrapper coordinates **both** the download (`Acervo.ensureComponentReady`) **and** the MLX-side model load (mmap of ~4 GB weights). SwiftAcervo dedups the download portion. The MLX load is still the consumer's responsibility and still needs the actor's coordination — without it, N concurrent loads each mmap N copies and the OS reclaims the process.

#### Decision matrix

```
Your wrapper's critical section is …
│
├─ … only an Acervo.ensureAvailable / ensureComponentReady call.
│  └─ DELETE the wrapper. Call Acervo directly.
│
├─ … an Acervo call + post-download work (MLX load, weight decode, GPU upload).
│  └─ KEEP the wrapper.
│
└─ … wrapping Acervo + telemetry / retry / cancellation routing.
   └─ KEEP.
```

`AcervoManager`'s `withModelAccess(_:perform:)` per-model lock is a different mechanism — it serializes *file access* after download. That lock stays; it is unrelated to download dedup.

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

### Cross-reference

- [`CHANGELOG.md`](CHANGELOG.md) § `[0.14.0]` — release-note view.
- [`Docs/USAGE-library.md`](Docs/USAGE-library.md) — full library API reference.
- [`Docs/CDN_ARCHITECTURE.md`](Docs/CDN_ARCHITECTURE.md) — manifest format + verification properties.

---

## Upgrading to earlier versions

For migrations to 0.13.x and earlier, see the **Migration** sections in [`CHANGELOG.md`](CHANGELOG.md) per release.
