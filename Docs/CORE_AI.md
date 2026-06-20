# CORE_AI.md — SwiftAcervo in the macOS 27 / iOS 27 era

**Status:** analysis & recommendation. Nothing here is implemented yet.
**Date compiled:** 2026-06-16
**Author:** compiled against the macOS 27 / iOS 27 developer beta docs (WWDC26).
**Sources:** Apple Developer docs via the `sosumi` MCP — `developer.apple.com/documentation/coreai/*`, `…/foundationmodels/*`, and WWDC26 sessions 232/241/319/326/334/339. All Core AI symbols below are marked **Beta** by Apple and may change before GA.

---

## TL;DR (the candid version)

macOS 27 / iOS 27 introduce **Core AI**, a first-party on-device inference runtime, plus an expanded **Foundation Models** framework and an Apple-curated catalog of optimized open-source models (Qwen, Mistral, SAM3, …).

**This does *not* obsolete SwiftAcervo.** Acervo's job is *acquire → verify → distribute → share* model files; it explicitly does **not** load or run models (see CLAUDE.md, "This library does NOT load models"). Core AI is the opposite: it *loads, specializes, and runs* a model it is handed, but it does **not** fetch from HuggingFace, does **not** operate a CDN, and does **not** do per-file SHA-256 integrity verification. Apple's own docs say the app "can download the `.aimodel` file over the network" and leave that entirely to the developer.

So the two are **complementary, not competitive**. The clean handoff is:

```
HuggingFace / R2 CDN ──(Acervo: fetch + verify + share)──▶ ~/…/SharedModels/<slug>/
                                                                    │
                                                                    ▼
                                              Core AI: AIModel(contentsOf:) → specialize → run
```

The one piece of Apple's design that genuinely overlaps Acervo is the **app-group shared cache** (`AIModelCache(appGroup:)`). That's not a threat — it's a validation of Acervo's architecture, and it's the single most important integration point. Details below.

**Bottom line:** Acervo needs **additive, non-breaking** changes, not a rewrite. The highest-value work is (1) treating `.aimodel` as a first-class file/component type and (2) a thin, optional "Core AI bridge" surface that stops at producing a URL + (optionally) kicking off specialization — without crossing the line into inference.

---

## 1. What actually shipped in macOS 27 / iOS 27

### 1.1 Core AI (`import CoreAI`) — the headline

A new low-level inference framework. Availability: **iOS 27.0+ / iPadOS 27.0+ / macOS 27 / Mac Catalyst 27.0+ / tvOS 27.0+ / visionOS 27.0+** (all Beta).

Core concepts relevant to us:

| Symbol | What it is | Why Acervo cares |
|---|---|---|
| **`.aimodel`** | Portable, device-agnostic model asset format. Converted from PyTorch via the open-source `coreai-torch` toolchain, or shipped pre-made. | A **new packaging format** Acervo will be asked to mirror/host alongside `.safetensors`/GGUF/MLX. |
| `AIModel(contentsOf:options:)` | Async. Loads a `.aimodel` and **specializes** it for the current device's CPU/GPU/Neural Engine. | This is the consumer's call. Acervo's job ends at handing over the URL. |
| `AIModelAsset` | Inspect a `.aimodel` without loading: `metadata` (description/author/license + creator-defined KV), `summary` (param count, storage/compute precision, op distribution), `isValid(at:)`. | Pure metadata read — **mirrors what Acervo's manifest already records.** `isValid(at:)` parallels Acervo's `config.json`-presence validity marker. |
| `AIModelCache` | Stores the **specialized** (device-specific) build so it isn't recomputed each launch. | Distinct from Acervo's store of **source** files. Complementary, see §3. |
| **`AIModelCache(appGroup:)`** | A specialized-asset cache **shared across apps/extensions in the same App Group**. | **Direct architectural twin of Acervo's `SharedModels` app-group container.** The key integration point. |
| `AIModelCache.Policy` (`.default` / `.persistent`) + `bookmarkData` | Lets an app delete the source `.aimodel` to reclaim storage and still load from the cached specialization via a bookmark. | Changes the lifecycle: a consumer may delete the source file Acervo manages. Acervo's "is it present" checks must not assume the source is permanent. |
| Ahead-of-time compilation | Heavy specialization work moved to build-time on the Mac, shrinking first-load time on device. | A `.aimodel` may ship pre-compiled variants — another artifact dimension to mirror. |

### 1.2 Foundation Models framework — expanded

Foundation Models existed in macOS 26; macOS 27 adds:

- **`LanguageModelExecutor`** (WWDC26/339) — bring a *third-party / open-source* LLM into the Foundation Models session/transcript API by implementing an executor. This is the bridge that lets a HuggingFace LLM (the kind Acervo ships) be driven through Apple's session/tool-calling/guided-generation stack.
- **`SystemLanguageModel.Adapter`** + `com.apple.developer.foundation-model-adapter` entitlement — load a custom-trained LoRA-style adapter against Apple's system model. Adapters are small files with a `compile()` step.
- **Private Cloud Compute** (`PrivateCloudComputeLanguageModel`, WWDC26/319) — larger frontier model with privacy guarantees; pure cloud, no local asset.
- **`fm` CLI + Python SDK** (WWDC26/334) — new `fm` command in macOS 27 for scripting Foundation Models, plus a Python SDK. Relevant as prior art / tonal reference for the `acervo` CLI, not a dependency.

### 1.3 Apple's curated open-source model catalog (WWDC26/326)

Apple now ships "a curated collection of popular open-source models — Qwen, Mistral, SAM3, and more — optimized for Apple silicon," with a workflow to **download, run, and benchmark** them and integrate "with just a few lines of code."

This is the part that most resembles Acervo's *discovery* role, and the one to watch. See §4 (risks).

### 1.4 MLX (WWDC26/232, 233)

Local agentic AI and multi-Mac distributed inference via MLX. No change to Acervo — MLX consumers (SwiftBruja, mlx-audio-swift) keep loading the files Acervo provides. Noted for completeness.

### 1.4a `.aimodel` vs MLX — separate runtimes, **both must be served**

A common misconception worth heading off: `.aimodel` is **not** a successor to the MLX/safetensors files Acervo ships today. They are parallel, non-interoperable paths.

- **Is `.aimodel` general-purpose?** Across model *types*, yes — the IR is a graph of tensor ops with `NDArray` I/O and covers LLMs (attention/RoPE/RMSNorm/MoE composite ops), vision (SAM3), and diffusion. But as a *format* it is **not portable**: it is a deployment/compilation target for one runtime (`AIModel`), conceptually like Core ML's MIL/`.mlpackage`, **not** an interchange format like ONNX/GGUF/safetensors. Only Core AI consumes it.
- **Is it PyTorch-specific?** No. PyTorch (`coreai-torch`, via `torch.export`) is the primary documented frontend, but the IR is frontend-agnostic and can be authored directly in Python via `coreai-core`'s `coreai.authoring`. PyTorch is *a* frontend, not *the* format.
- **Does it work with MLX?** **No.** Core AI and MLX are separate, parallel runtimes with **no documented bridge** — neither MLX→`.aimodel` nor `.aimodel`→MLX. MLX loads `.safetensors`/MLX-native weights and runs on the Metal GPU (and M5 Neural Accelerators); Core AI loads `.aimodel` and can additionally target the **Neural Engine**. Apple presents them as alternatives (WWDC26 session 232 = MLX, 324/326 = Core AI), and benchmarks treat them as competitors (~2.47× faster on a 0.6B model, only ~1.05× at 8B — *secondary-source numbers, indicative only*).

**Consequence for Acervo:**

- Acervo's current consumers (**SwiftBruja, mlx-audio-swift**) run **MLX** and load `.safetensors`/MLX weights — they are **unaffected** by Core AI and will not consume `.aimodel` unless rewritten onto a different runtime.
- Acervo must therefore keep serving MLX/safetensors/GGUF **indefinitely**. `.aimodel` support (R1) is strictly **additive**, for a *different* (Core-AI-targeting) consumer audience — never a replacement.
- An MLX model on the CDN can't be "upgraded" to `.aimodel` for free. Conversion runs from the **PyTorch source** via `coreai-torch` and produces a *distinct* artifact, while the MLX version keeps shipping. Expect **two formats of the same model serving two audiences**, not a migration.

---

## 2. Where Acervo and Core AI do **not** overlap (Acervo's durable moat)

Core AI explicitly leaves all of the following to the developer. These are exactly Acervo's responsibilities and remain unique:

1. **Acquisition from real sources.** Core AI takes a local URL. It has no HuggingFace client, no `resolve`-endpoint byte fetch, no `org/repo` concept. Acervo's `HuggingFaceClient` and CDN download path fill this gap.
2. **CDN distribution + mutation.** R2 mirroring, SigV4 publish/delete/recache — entirely Acervo's. Core AI has nothing here.
3. **Per-file SHA-256 manifest verification.** Core AI offers `AIModelAsset.isValid(at:)` (structural validity of one asset) but no cryptographic, manifest-driven integrity over an arbitrary file set. Acervo's manifest-first model and `SecureDownloadSession` (CDN-only, redirect-rejecting) are unmatched.
4. **Framework-agnostic file management.** Acervo serves MLX, GGUF, diffusion components, tokenizers, configs — not just `.aimodel`. Most models Acervo ships today are **not** `.aimodel` and won't be for a long time.
5. **Multi-component / bundle packaging.** FLUX.2 (N:1), PixArt (1:1), component registry, hydration. Core AI has no notion of a multi-file model bundle beyond a single asset.

**Conclusion:** Acervo's mission statement does not change. It is still the "auto downloader and packager." Core AI just adds one more *destination* for the files it packages.

---

## 3. The one real integration point: the App-Group shared cache

This is the most important section.

Acervo already standardizes on:
```
~/Library/Group Containers/<group-id>/SharedModels/<org>_<repo>/
```
resolved from `com.apple.security.application-groups` (UI apps) or `ACERVO_APP_GROUP_ID` (CLIs/tests).

Core AI independently arrived at the *same* sharing primitive:
```swift
guard let groupCache = AIModelCache(appGroup: groupIdentifier) else { … }
try await AIModel.specialize(contentsOf: sharedModelURL, options: .default,
                             cache: groupCache, cachePolicy: .persistent)
```

The two caches are **layered, not redundant**:

| Layer | Owner | Contents | Keyed by |
|---|---|---|---|
| **Source layer** | **Acervo** | the portable `.aimodel` (+ all other files), verified against the CDN manifest | `<org>_<repo>` slug |
| **Specialized layer** | **Core AI** | device-specific compiled build of that asset | source URL + `SpecializationOptions` |

The clean contract: **Acervo guarantees the source `.aimodel` is present and intact in the App Group container; Core AI specializes it into the App-Group specialization cache once, shared across every consumer app.** One download, one specialization, N apps.

Caveat to design around: Core AI lets a consumer **delete the source file** after capturing `bookmarkData`, then load purely from the specialized cache. If a consumer does this, Acervo's presence/validity checks for that slug will report "absent" even though the model is still runnable via the bookmark. Acervo must not treat its own presence check as authoritative about runnability, and must not "helpfully" re-download. (See recommendation R4.)

---

## 4. Risks & candid trade-offs

- **Catalog overlap (low-to-medium risk).** Apple's curated catalog (Qwen/Mistral/SAM3) overlaps Acervo's *discovery* surface for the specific models Apple blesses. But Apple's catalog is closed, Apple-hosted, `.aimodel`-only, and macOS-27+. Acervo's catalog is open (any HF repo), self-hosted on a private CDN, multi-format, and runs on macOS 26 today. The overlap is a thin sliver. **Do not** try to compete by reimplementing Apple's catalog; do interoperate (R2).
- **`.aimodel` is not yet the dominant format.** The ecosystem Acervo serves (MLX, GGUF, diffusion) is overwhelmingly *not* `.aimodel`. Treat `.aimodel` support as additive; do not refactor the core around it.
- **Don't cross the inference line.** It will be tempting to add `Acervo.loadCoreAIModel(...)` that returns a live `AIModel`. That violates the project's framework-agnostic boundary (loading is the consumer's job) and pulls `import CoreAI` — a heavy, Beta, platform-27-only dependency — into a library that must build for macOS/iOS 26. Keep any Core AI code in a **separate, conditionally-compiled, optional target/module**, and stop at producing a URL (and at most *triggering* specialization, which is arguably acquisition-adjacent, not inference). See R3.
- **Platform floor.** Core AI is 27.0+. Acervo's floor is 26.0+ and must stay there. Any Core AI surface must be behind `#available` / a separate product so the base library keeps compiling and shipping for 26.

---

## 5. Recommendations (prioritized, all additive / non-breaking)

**R1 — Treat `.aimodel` as a first-class component/file type.** *(do first; low cost)*
Make sure the manifest generator, component descriptors, and `ManifestGenerator` recognize `.aimodel` (and any sidecar/precompiled artifacts) so Acervo can mirror and verify them exactly like `.safetensors`. This is mostly "don't filter it out" + tests. No API change.

**R2 — Read `.aimodel` metadata into Acervo's model info.** *(medium cost, high value)*
`AIModelAsset.metadata`/`summary` expose author, license, param count, precision, op distribution. Surface these in `AcervoModel` / the UI (`AcervoModelsList`) when an `.aimodel` is present, so consumers can show "Core AI–ready" models with rich metadata. Read-only; can be done with a tiny parser if avoiding `import CoreAI` in the base target.

**R3 — Add an optional `SwiftAcervoCoreAI` bridge module.** *(medium cost; keep it small & isolated)*
A separate SPM product gated to 27.0+ that does *only*:
- `coreAIModelURL(for:)` → resolve the `.aimodel` path inside `SharedModels`.
- `prepare(_:into:options:)` → call `AIModel.specialize(contentsOf:cache:cachePolicy:)` against the App-Group cache (`AIModelCache(appGroup:)` using Acervo's resolved group id) so the specialization is shared and warm before first use.
- Optionally vend/persist `bookmarkData`.
It must **not** call `loadFunction`/`run` — that's the consumer's inference, which stays out of Acervo. This keeps `import CoreAI` out of the base library entirely.

**R4 — Make presence/validity checks tolerant of source-file deletion.** *(low cost; correctness)*
Document and handle the Core AI lifecycle where a consumer deletes the source `.aimodel` after bookmarking the specialized build. Acervo's `ensureComponentReady` / availability checks should not auto-re-download in that state, and the UI should distinguish "source removed but runnable via Core AI cache" from "missing." At minimum, document the interaction.

**R5 — Align the App-Group story in docs.** *(low cost)*
Add a short section to `Docs/SHARED_MODELS_DIRECTORY.md` and `Docs/ARCHITECTURE.md` describing the **source layer (Acervo) vs specialized layer (Core AI)** split from §3, and that both ride the same App-Group id. This prevents a future contributor from "deduplicating" the two caches by mistake.

**R6 — `acervo` CLI: optional `specialize`/`inspect` subcommands.** *(later; nice-to-have, macOS 27 only)*
`acervo inspect <slug>` to dump `AIModelAsset` summary/metadata; `acervo specialize <slug>` to pre-warm the Core AI cache. Gate behind a 27.0 availability check and the bridge module. Mirrors the ergonomics of Apple's new `fm` CLI without depending on it.

**Explicitly NOT recommended:**
- ❌ Rewriting Acervo around `.aimodel`.
- ❌ Reimplementing/competing with Apple's curated catalog.
- ❌ Adding inference (`run`/`loadFunction`) to Acervo.
- ❌ Raising the platform floor above 26.0.
- ❌ Pulling `import CoreAI` into the base `SwiftAcervo` library target.

---

## 5b. The `.aimodel` format vs. the Acervo manifest

**Has Apple published a format spec?** No — not at the byte/on-disk level. Apple documents the **logical schema and an inspection API**, not an encoding you could parse or reproduce. Specifically:

- `.aimodel` is a **bundle (a directory)** — `AIModelAsset.url` is "the model asset bundle on disk." The internal binary layout is **opaque/proprietary**.
- The documented surface is the `AIModelAsset` read API: `metadata` (description, author, license, creationDate, creator-defined KV), `summary` (compute/storage precision, operation distribution, param count), `FunctionDescriptor` / `ValueDescriptor` (inference-function names + input/output tensor shapes and scalar types).
- Produced by the open-source **`coreai-torch`** converter; AOT-compiled by **`coreai-build`** into per-architecture **`.aimodelc`** files.
- **No documented checksum, signature, source URL, or integrity field anywhere in the format.**

So Apple tells you *how to inspect* a `.aimodel`, not *how it's encoded*. From Acervo's perspective the bytes are an opaque blob; the metadata is a queryable surface.

### Compare & contrast

These are **not competing schemas** — they describe different layers and coexist. A `.aimodel` bundle is *one payload* that an Acervo `manifest.json` would list and hash.

| Dimension | Acervo `manifest.json` (`CDNManifest`) | `.aimodel` (+ `AIModelAsset`) |
|---|---|---|
| **Purpose** | Acquire + verify + distribute files over an untrusted network | Be inspected, specialized, and run for inference |
| **Layer** | Transport / integrity / provenance | Model semantics / execution |
| **Form** | External JSON sidecar at `{cdn}/models/{slug}/manifest.json` | Metadata **embedded inside** an opaque bundle |
| **Unit** | A *set* of arbitrary files (`CDNManifestFile[]`, nested relative paths) | A *single* self-contained artifact (N inference functions) |
| **Integrity** | Per-file SHA-256 + sorted-concat `manifestChecksum`; CDN-only redirect-rejecting session | **None documented** — only structural `isValid(at:)`; punted to Background Assets / developer |
| **Provenance** | `modelId`, `slug`, `primaryRepo`, `components`, `consumers`, `updatedAt`, `manifestVersion` | `author`, `license`, `creationDate`, creator KV — but **no source/URL, no fetch concept** |
| **Model awareness** | **Zero** — files are opaque blobs | Self-describes I/O tensors, shapes, scalar types, op distribution |
| **Mutability** | Regenerated & republished (immutable per publish on CDN) | **Mutable in place** (`updateMetadata`; Xcode saves inline) |

### Key takeaways

1. **The layers are orthogonal and complementary.** Acervo's manifest is *network/trust* metadata; `.aimodel`'s metadata is *runtime/semantic* metadata. A `.aimodel` is just a `CDNManifestFile` entry from Acervo's point of view; Acervo carries the SHA-256 the format itself lacks.
2. **Apple's AOT story is an Acervo-shaped hole.** `coreai-build` emits one `.aimodelc` *per device architecture*, and Apple's guidance is literally *"host the compiled assets remotely and download the matching variant"* via **Background Assets** (a mature framework since 2022 — see §5c). That is Acervo's job — and Acervo adds the **per-file integrity verification Background Assets lacks**. A manifest can list `MyModel.<arch>.aimodelc` entries; the consumer reads `AIModel.deviceArchitectureName`, then fetches + verifies only the matching one. This is the strongest synergy in the whole analysis.
3. **The `config.json` validity marker breaks for Core AI models** (affects R1). A `.aimodel`/`.aimodelc` model has no `config.json`; its validity marker is the bundle's own `AIModelAsset.isValid(at:)`. Acervo's universal `config.json`-presence rule must special-case Core AI assets.
4. **Hash the bundle opaque, not per-internal-file.** `.aimodel` is a directory, but since its internals are undocumented and Core AI treats it as one unit, mirroring it as a single opaque blob (one SHA-256) is simpler and loses nothing. Per-internal-file hashing buys no verifiable guarantee.

---

## 5c. Background Assets vs. Acervo's downloader

**First, a correction to avoid a common misread:** Background Assets is **not** a macOS 27 feature. It shipped at **WWDC22 (iOS 16 / macOS 13 Ventura)** and has been fully available on macOS 26 the whole time. The macOS 27 delta is *only* localization (the `**Beta**`-tagged `localizedAssetPacks`, `language`, `reconcilePreferredLanguages()` symbols). The download machinery relevant to `.aimodelc` distribution — `AssetPackManager.ensureLocalAvailability`, self-hosted `AssetPackManifest`, and the unmanaged `BADownloadManager`/`BAURLDownload` path — is stable and present on 26.

**Does it overlap Acervo's downloader?** For the narrow "move bytes from a URL to disk in the background" slice, yes. But Background Assets is **not** an in-process threaded download — and that architectural difference is the whole point.

### How Background Assets actually works

It is **OS-scheduled and out-of-process**, not a `URLSession` task you own:

- The download runs in a separate **app extension** (`BADownloaderExtension`) that a **system daemon** launches out-of-process.
- It can run **when your app isn't running** — at install time *before the user ever launches the app*, then periodically and on app updates (`BAContentRequest.install / .periodic / .update`).
- The **OS owns scheduling, power, and network policy** (cellular/Wi-Fi rules, storage allowances like `downloadWouldExceedAllowance` / `BAMaxInstallSize`, deferral, retry).
- For **managed** packs the OS owns storage placement and lifecycle (`ensureLocalAvailability`, `remove`, update tracking); packs may be **Apple-hosted** (`BAUsesAppleHosting`) and tie into App Store distribution.

Acervo, by contrast, is an in-process `actor` doing `URLSession` transfers with per-model locking, alive only while the process (app **or CLI**) runs, with all scheduling/placement/lifecycle decided in-library.

### Capability comparison

| Capability | Acervo | Background Assets |
|---|---|---|
| Source from HuggingFace (`resolve` endpoint, LFS) | ✅ | ❌ (URL / Apple-hosted only) |
| Per-file **SHA-256 + manifest checksum** integrity | ✅ | ❌ (unmanaged: byte count + TLS only) |
| Private CDN **mutation** (SigV4 publish/delete/recache) | ✅ | ❌ |
| Multi-component bundle packaging (FLUX.2 N:1, slugs) | ✅ | ❌ (flat asset packs) |
| Redirect-rejecting CDN-only secure session | ✅ | partial (domain allowances) |
| Shared dir for **non-app consumers** (CLIs, libraries, tests) | ✅ | ❌ (app + extension bound) |
| Runs **before app launch / when app not running** | ❌ | ✅ |
| OS-managed power / network / storage scheduling | ❌ | ✅ |
| No extension target / entitlement ceremony required | ✅ | ❌ (requires an extension; App-Store-oriented flows) |

### Candid assessment

The raw background-download capability **is** somewhat reinvented — if all Acervo did was move bytes on a single Apple platform for an App Store app, Background Assets (2022) was the off-the-shelf answer. But the downloader is the *least* special part of Acervo. The actual value — content-addressed SHA-256 verification, the CDN manifest, SigV4 mutation, HuggingFace sourcing, multi-component packaging, and a shared store usable by **CLIs, libraries, and tests** (not just apps + extensions) — has **no equivalent in Background Assets**.

**Possible best-of-both design:** an *optional, UI-app-only* path where Acervo delegates the **transport** to Background Assets (emit a self-hosted `AssetPackManifest`, or wrap `BAURLDownload`) to gain OS-scheduled, pre-launch, power-aware delivery — while Acervo keeps owning HF sourcing, SHA-256 verification, and CDN mutation. The hard constraint: Background Assets requires an app extension, which **kills the CLI / library / test consumers**. So this can only ever be an additive option for app consumers, never a replacement for the core in-process downloader. (Folds into the open questions below.)

---

## 5d. Apple's open-source Core AI tooling (all BSD-3-Clause)

Apple shipped a full open-source toolchain around Core AI. Verified on GitHub, June 2026:

| Repo | What it is |
|---|---|
| [`apple/coreai-torch`](https://github.com/apple/coreai-torch) | PyTorch → Core AI IR converter: `TorchConverter`, a composite-op library, custom op lowerings, inline Metal GPU kernels (`TorchMetalKernel`). |
| [`apple/coreai-optimization`](https://github.com/apple/coreai-optimization) (`coreai-opt`) | PyTorch compression for Apple silicon: quantization, palettization (codebook), pruning. |
| [`apple/coreai-models`](https://github.com/apple/coreai-models) | Export **recipes**, Python primitives, a **model registry** (`uv run coreai.model.registry --list-models`), a **Swift runtime** package (iOS/macOS 27+), and **agent skills** for Claude Code / Codex / Gemini. |
| `coreai-core` | Python `coreai.authoring` to build a graph and save/load a `.aimodel`; run inference with NumPy. |
| [`john-rocky/coreai-model-zoo`](https://github.com/john-rocky/coreai-model-zoo) *(community, not Apple)* | Qwen3.5 & Gemma 4 converted end-to-end, verified on iPhone 17 Pro, conversion gotchas. |

### The format is still not a published spec

Across all of Apple's repos you get **Python/Swift APIs to *produce* and *consume*** `.aimodel`, but **no published serialization schema** (no protobuf/FlatBuffer/MIL grammar). Open *tooling*, API-defined *format*. This strengthens §5b: treat `.aimodel` as an **opaque blob generated by Apple's converter**, never something to hand-author or parse at the byte level.

### Three facts that hit Acervo directly

1. **Official multi-file packaging validates Acervo's component model.** coreai-models states complex models produce *"a resource folder containing one or more `.aimodel` files alongside any required resources"* — tokenizers for LLMs, multiple models for diffusion pipelines. This is the same shape as Acervo's multi-component bundles (FLUX.2 N:1, PixArt). Reinforces R1.
2. **HuggingFace is upstream, but with a conversion step in between** (resolves Open Question #1). Recipes convert *"from Hugging Face and other sources,"* so the real pipeline is:
   ```
   HuggingFace ──coreai-opt──▶ compressed PyTorch ──coreai-torch──▶ .aimodel resource folder
   ```
   `.aimodel` files do **not** exist on HF to mirror directly — Acervo would have to **run the conversion** in `acervo ship`. That is a real new dependency (Python + coreai-torch + coreai-opt + the Metal toolchain, Mac-host-only). Tolerable in the CLI/CI (which already shells out to the Python `hf` CLI); must stay **out of the zero-dependency library**.
3. **Apple has a model registry and agent skills.** `coreai.model.registry` is a build-time discovery/catalog analog (not a runtime CDN). Agent skills (`working-with-coreai`, `model-authoring`, `model-compression-exploration`) install into Claude Code / Codex / Gemini.

**Directive:** do not reimplement any of this. If Acervo ships `.aimodel`, **shell out to `coreai-torch`** in the `acervo ship` pipeline (exactly as it already shells to `hf`), confine conversion to the CLI/CI, and keep Acervo owning what these repos do **not**: CDN distribution, SHA-256 manifest verification, and the shared runtime store.

---

## 6. Open questions to resolve before building

1. ~~Will the CDN host `.aimodel` files, and do they come from HF or a local conversion step?~~ **Resolved (see §5d):** `.aimodel` files don't exist on HF — they must be produced by running `coreai-torch`/`coreai-opt` on HF source weights. The open question that remains is *whether* to take on that conversion stage in `acervo ship` (Python + coreai-torch + coreai-opt + Metal toolchain, Mac-host-only), or to stay out of `.aimodel` production entirely and only mirror/verify `.aimodel` resource folders that consumers convert themselves.
2. **Specialization caching ownership:** does Acervo *trigger* specialization (R3) or stay strictly hands-off and let each consumer do it? Triggering gives "one warm cache for all apps" but nudges Acervo toward the inference boundary.
3. **Source deletion policy:** do we want consumers deleting Acervo-managed source files (Core AI's storage-reclaim pattern), or do we treat `SharedModels` as immutable-source-of-truth and tell consumers to rely on Acervo for re-fetch instead of bookmarks?
4. **Does any consumer actually need Core AI yet?** SwiftBruja/mlx-audio-swift load via MLX today. If no consumer targets 27.0, R3–R6 can wait; R1/R2/R5 are worth doing now regardless.
5. **Delegate transport to Background Assets for app consumers?** (See §5c.) Worth it for OS-scheduled, pre-launch, power-aware `.aimodelc` delivery — but it requires an app extension that excludes CLIs/libraries/tests, so it could only ever be an additive UI-app-only path, never a replacement for the core in-process downloader. Decide whether the OS-scheduling win justifies maintaining a second, app-only transport.

---

*This document is analysis only. No code in this repo has been changed. Implementing R1–R6 should follow the normal `-dev` → release flow and stay behind the macOS/iOS 26 platform floor for everything except the optional `SwiftAcervoCoreAI` bridge.*
