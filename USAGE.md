# USAGE.md — Integration Guide for Consuming Libraries

**For**: App and library developers integrating SwiftAcervo for model discovery and downloading.

**The principle**: A consuming library does not know what files exist inside a model until the CDN manifest comes back. The manifest is the only authoritative source. You may *request* a file by name, but that request is validated against the manifest; asking for a file that isn't there throws `AcervoError.fileNotInManifest`. Build for the manifest-first flow; fall back to pinning a file subset only when you genuinely need to.

---

## Quick Start

### 1. Add SwiftAcervo to Package.swift

```swift
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MyApp",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/intrusive-memory/SwiftAcervo.git", from: "0.8.2")
    ],
    targets: [
        .target(
            name: "MyApp",
            dependencies: ["SwiftAcervo"]
        )
    ]
)
```

Or add via Xcode: **File > Add Package Dependencies** → enter repository URL.

### 2. Tell SwiftAcervo where its App Group lives (REQUIRED)

SwiftAcervo stores every model under `~/Library/Group Containers/<your-app-group-id>/SharedModels/` on macOS and inside the App Group container on iOS. The path is identical for UI apps and CLIs once the group ID is configured, which is what makes cross-process sharing work. **There is no fallback** — `Acervo.sharedModelsDirectory` calls `fatalError` if no App Group ID can be resolved, on purpose, because a per-process fallback path is exactly the divergence App Groups exist to prevent.

SwiftAcervo learns the App Group identifier in two ways:

1. **`ACERVO_APP_GROUP_ID` environment variable** — used by CLI tools, scripts, test runners, and anything else without an entitlements file.
2. **`com.apple.security.application-groups` entitlement** — read at runtime via `SecTaskCopyValueForEntitlement`. Used by signed UI apps. SwiftAcervo takes the **first** group in the array.

The env var wins if both are set.

#### For UI apps (macOS / iOS)

Declare the App Group in your `.entitlements` file. **Xcode setup** (do this for every target that calls into SwiftAcervo, including extensions):

1. Select the target → **Signing & Capabilities**.
2. Click **+ Capability** → **App Groups**.
3. Check (or add) `group.intrusive-memory.models` (or your own group ID).
4. Rebuild.

**Manual `.entitlements` file** (for non-Xcode builds):

```xml
<!-- MyApp.entitlements -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.intrusive-memory.models</string>
    </array>
</dict>
</plist>
```

**Provisioning profile**: the profile must include the App Group. When Xcode manages signing automatically, this is handled for you; for manual profiles, regenerate after adding the group in the Apple Developer portal.

#### For CLI tools, scripts, and test runners

Export `ACERVO_APP_GROUP_ID` in your shell. The standard place is `~/.zprofile` so every interactive shell on the machine inherits it:

```sh
# ~/.zprofile
export ACERVO_APP_GROUP_ID=group.intrusive-memory.models
```

For CI, set the same variable in the job environment (GitHub Actions `env:`, `.envrc`, etc.). Without it, every Acervo path-resolution call traps with a `fatalError` and the message tells you exactly what to do.

#### Verifying the wiring

At startup, print `Acervo.sharedModelsDirectory`. The path should contain your App Group identifier:

```
~/Library/Group Containers/group.intrusive-memory.models/SharedModels
```

If you get a `fatalError` with the message `SwiftAcervo: no App Group identifier configured.`, your UI app is missing the entitlement or your CLI shell is missing the env var.

See **[SHARED_MODELS_DIRECTORY.md](SHARED_MODELS_DIRECTORY.md)** for the full directory layout and troubleshooting.

### 3. Ensure models are available — no file list required

The preferred startup path is `ModelDownloadManager.ensureModelsAvailable`. It fetches each model's manifest and downloads whatever the manifest says is in the model. You don't need to know in advance what files are there:

```swift
import SwiftAcervo

try await ModelDownloadManager.shared.ensureModelsAvailable([
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"
]) { progress in
    let percent = Int(progress.fraction * 100)
    let mb = progress.bytesDownloaded / (1024 * 1024)
    print("[\(progress.model)] \(percent)% (\(mb) MB) — \(progress.currentFileName)")
}
```

### 4. Load models from disk

```swift
let modelDir = try Acervo.modelDirectory(for: "mlx-community/Qwen2.5-7B-Instruct-4bit")
// Pass modelDir to your framework (MLX, etc.)
```

---

## Integration Checklist

- [ ] Add SwiftAcervo dependency to `Package.swift`.
- [ ] **Configure the App Group identifier on every consumer**: UI apps declare `com.apple.security.application-groups` in their `.entitlements` file; CLI tools / scripts / CI export `ACERVO_APP_GROUP_ID` (see step 2 above). Verify at runtime by printing `Acervo.sharedModelsDirectory` — a `fatalError` with `no App Group identifier configured` means neither source supplied a value.
- [ ] Decide your consumption level (see "Three Ways to Avoid Naming Files" below).
- [ ] Call `ModelDownloadManager.shared.ensureModelsAvailable()` (or a lower-level equivalent) at app startup, typically behind an `await`.
- [ ] Provide progress feedback via the callback.
- [ ] Handle `AcervoError` cases and convert to app-specific errors.
- [ ] Call `Acervo.modelDirectory(for:)` to get the path for loading.
- [ ] Test offline (already-present models must load without network).

---

## Three Ways to Avoid Naming Files

Every approach below delegates "what files exist" to the CDN manifest. Pick the one that matches how your caller talks about models.

### Level 1 — Batch, highest level: `ModelDownloadManager.ensureModelsAvailable`

Best default for apps. Give it a list of model IDs; it fetches each manifest, downloads everything, and reports cumulative progress across the batch.

```swift
import SwiftAcervo

try await ModelDownloadManager.shared.ensureModelsAvailable([
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    "mlx-community/snac_24khz"
]) { progress in
    // progress.fraction is cumulative across the whole batch, 0.0...1.0
    // progress.currentFileName tells you which file is downloading right now
    print("\(progress.model): \(Int(progress.fraction * 100))%")
}
```

Internally this calls `Acervo.ensureAvailable(modelId, files: [])` — the empty array means "the whole manifest."

### Level 2 — Single model: `Acervo.ensureAvailable(_, files: [])`

When you want one model and still don't want to name files, pass an empty `files:` array. Same contract: the manifest drives the download.

```swift
try await Acervo.ensureAvailable(
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    files: []
) { progress in
    // progress.overallProgress is byte-accurate for this one model
    print("\(progress.fileName): \(Int(progress.overallProgress * 100))%")
}
```

This is today's killer feature for consumers that want to download exactly what's published, no file bookkeeping required.

### Level 3 — Registered components: `Acervo.ensureComponentReady`

When your library offers a curated catalog of models (named components with type, display name, minimum memory, arbitrary metadata), register bare `ComponentDescriptor` values and let Acervo hydrate them on first use.

```swift
import SwiftAcervo

// One-time registration — no `files:` array needed.
let descriptor = ComponentDescriptor(
    id: "qwen2.5-3b-instruct-4bit",
    type: .languageModel,
    displayName: "Qwen2.5 3B Instruct (4-bit MLX)",
    repoId: "mlx-community/Qwen2.5-3B-Instruct-4bit",
    minimumMemoryBytes: 2_400_000_000
)
Acervo.register(descriptor)

// First call hydrates the descriptor from the CDN manifest, then downloads.
try await Acervo.ensureComponentReady("qwen2.5-3b-instruct-4bit") { progress in
    print("\(progress.fileName): \(Int(progress.overallProgress * 100))%")
}

// After this call, the descriptor's .files property is populated.
let dir = try Acervo.modelDirectory(for: "mlx-community/Qwen2.5-3B-Instruct-4bit")
```

`ensureComponentReady` auto-hydrates transparently; callers never see the manifest fetch. If you want to hydrate without downloading (e.g., a model picker that needs sizes), call `Acervo.hydrateComponent(_:)` first.

---

## Enumerating Files Before Acting

Sometimes you want to look at what's in the manifest before deciding what to do — for example, to present a size estimate in UI, or to implement a custom catalog. Three entry points cover this.

### `Acervo.fetchManifest(for: modelId)` — raw manifest by model ID

Takes an `org/repo` string. Bypasses the component registry. Use this for one-off lookups, CI verification tools, and cache warmers.

```swift
let manifest = try await Acervo.fetchManifest(
    for: "mlx-community/Qwen2.5-7B-Instruct-4bit"
)
for file in manifest.files {
    print("\(file.path) — \(file.sizeBytes) bytes, sha256=\(file.sha256)")
}
```

> The outer parameter label is `for:` but the inner parameter is now `modelId`. A companion `fetchManifest(forComponent:)` exists for the registry-aware case.

### `Acervo.fetchManifest(forComponent: componentId)` — raw manifest via registry

When you already have a component registered, skip the repoId lookup.

```swift
let manifest = try await Acervo.fetchManifest(
    forComponent: "qwen2.5-3b-instruct-4bit"
)
print("Total size: \(manifest.files.reduce(0) { $0 + $1.sizeBytes }) bytes")
```

Throws `AcervoError.componentNotRegistered` if the component ID is unknown.

### `Acervo.hydrateComponent(componentId)` — populate the descriptor, no download

Fetches the manifest and rewrites the registered descriptor with the full file list. No bytes downloaded beyond the manifest itself.

```swift
try await Acervo.hydrateComponent("qwen2.5-3b-instruct-4bit")

// Now the registry has the full file list and size
let component = Acervo.component("qwen2.5-3b-instruct-4bit")!
print("\(component.files.count) files, \(component.estimatedSizeBytes) bytes total")
```

Concurrent hydration calls for the same component coalesce into a single in-flight fetch.

---

## The Contract

Keep these facts in mind when you design against SwiftAcervo:

1. **Before hydration, you do not know what files exist.** An un-hydrated `ComponentDescriptor` has `files == []` and `isHydrated == false`. A raw `modelId` has no local representation at all.
2. **The manifest is the only authoritative source.** If your declared file list disagrees with the manifest, the manifest wins. Acervo emits a drift warning to stderr (`[SwiftAcervo] Manifest drift detected for <id>: declared N files, manifest has M files. Using manifest.`) and rebuilds the descriptor with `replace` semantics.
3. **Requests for non-existent files throw.** Passing `files: ["no-such-file.bin"]` to `ensureAvailable` or `download` raises `AcervoError.fileNotInManifest(fileName:modelId:)`. Every file in the `files:` array is checked against the manifest before any download begins.
4. **Downloads are verified end-to-end.** Every file downloaded through Acervo is SHA-256 verified against the manifest entry; size mismatches and checksum mismatches fail the download.
5. **`config.json` is the local validity marker.** `Acervo.isModelAvailable(_:)` returns `true` when `config.json` exists in the model's directory. This is orthogonal to the manifest — it just means "something was downloaded here."

---

## Pinning a Specific Subset (Escape Hatch)

There are real cases where a consumer genuinely needs a subset of the files in the manifest and is willing to hard-code that knowledge. Examples: startup latency budgets where the extra shards will be lazily fetched later, or pre-release models where the consumer wants to download a stable subset while the rest of the repo churns.

When you take this path, you are opting out of the manifest-first contract for this one call. The manifest is still fetched and still validates each name you pass — you are only narrowing the download to a subset.

```swift
// Advanced: pin a specific file subset.
try await Acervo.ensureAvailable(
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    files: [
        "config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "model.safetensors"
    ]
) { progress in
    print("\(progress.fileName): \(Int(progress.overallProgress * 100))%")
}
```

Equivalent form using a registered `ComponentDescriptor` with a declared file list (the v0.7-era pattern, still supported):

```swift
let descriptor = ComponentDescriptor(
    id: "qwen2.5-7b-instruct-4bit-pinned",
    type: .languageModel,
    displayName: "Qwen2.5 7B Instruct (pinned subset)",
    repoId: "mlx-community/Qwen2.5-7B-Instruct-4bit",
    files: [
        ComponentFile(relativePath: "config.json"),
        ComponentFile(relativePath: "tokenizer.json"),
        ComponentFile(relativePath: "tokenizer_config.json"),
        ComponentFile(relativePath: "model.safetensors"),
    ],
    estimatedSizeBytes: 4_400_000_000,
    minimumMemoryBytes: 5_000_000_000
)
Acervo.register(descriptor)
try await Acervo.ensureComponentReady("qwen2.5-7b-instruct-4bit-pinned")
```

**Rule of thumb**: if the repo on the CDN is yours or stable, prefer the manifest-first forms. Reach for `files: [...]` when you actually need to narrow the download — not because you want to feel safer about what gets fetched.

---

## Error Handling

Catch `AcervoError` and convert to app-specific errors:

```swift
import SwiftAcervo

do {
    try await ModelDownloadManager.shared.ensureModelsAvailable(modelIds) { _ in }
} catch let error as AcervoError {
    switch error {
    case .modelNotFound(let id):
        showError("Model '\(id)' not found on CDN")

    case .manifestDownloadFailed(let statusCode):
        showError("Manifest unavailable (HTTP \(statusCode))")

    case .manifestIntegrityFailed:
        showError("Manifest is corrupt; aborting.")

    case .downloadFailed(let fileName, let statusCode):
        showError("Download failed for \(fileName) (HTTP \(statusCode))")

    case .integrityCheckFailed(let file, _, _):
        showError("File '\(file)' failed SHA-256 verification.")

    case .downloadSizeMismatch(let fileName, let expected, let actual):
        showError("File '\(fileName)' size mismatch (\(actual) vs \(expected) bytes)")

    case .fileNotInManifest(let fileName, let modelId):
        showError("Model '\(modelId)' does not include '\(fileName)'")

    case .componentNotRegistered(let id):
        showError("Unknown component '\(id)'")

    default:
        showError("SwiftAcervo error: \(error.localizedDescription)")
    }
} catch {
    showError("Unexpected error: \(error.localizedDescription)")
}
```

### Best Practices

1. **Prefer manifest-first APIs.** Hard-coded file lists go stale — `files: []` always matches the published model.
2. **Validate disk space first.** `ModelDownloadManager.validateCanDownload(_:)` returns the total byte count before any download starts.
3. **Show aggregate progress.** `ModelDownloadProgress.fraction` is cumulative across the batch; that's usually what a user wants to see.
4. **Handle transient network failures gracefully.** Offer retry; partial downloads resume on next call.
5. **Serialize same-model downloads.** `AcervoManager` and `ModelDownloadManager` already handle this for you.

---

## Thread Safety

`AcervoManager` is a singleton actor that serializes concurrent operations on the same model while letting different models proceed in parallel.

```swift
// Different models run concurrently
async let llm: Void = AcervoManager.shared.download(
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    files: []   // manifest-first: download everything
)
async let tts: Void = AcervoManager.shared.download(
    "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16",
    files: []
)
try await llm
try await tts
```

Use `withModelAccess` when you need exclusive access to a model directory while reading — no other task can download or mutate that directory while the closure is running:

```swift
let configData = try await AcervoManager.shared.withModelAccess(
    "mlx-community/Qwen2.5-7B-Instruct-4bit"
) { modelDir in
    let configURL = modelDir.appendingPathComponent("config.json")
    return try Data(contentsOf: configURL)
}
```

### Local Path Access

`withLocalAccess(_:perform:)` gives scoped access to a caller-supplied local file or directory — for example, a user-supplied LoRA adapter or a fine-tuned weight file that Acervo did not download. Acervo validates the URL exists, then hands back a `LocalHandle` for path-agnostic file resolution:

```swift
let loraURL = URL(filePath: "/path/to/my-lora-adapter")

let weights = try await AcervoManager.shared.withLocalAccess(loraURL) { handle in
    let fileURL = try handle.url(matching: ".safetensors")
    return try Data(contentsOf: fileURL)
}
```

`LocalHandle` provides `url(for:)`, `url(matching:)`, and `urls(matching:)` for looking up files within the scoped root. If the URL doesn't exist on disk, `AcervoError.localPathNotFound(url:)` is thrown.

---

## Testing Your Code Against SwiftAcervo

Two pieces of SwiftAcervo state are process-wide and can race across parallel test suites:

- **`ACERVO_APP_GROUP_ID` environment variable** — drives `Acervo.sharedModelsDirectory`. Tests that need an isolated model directory set it to a unique value (e.g. `"group.acervo.test.<uuid>"`) so the resolved path becomes `~/Library/Group Containers/group.acervo.test.<uuid>/SharedModels/`, distinct from the production directory. Restore the prior value (or unset) on exit.
- **`ACERVO_OFFLINE` environment variable** — when set to `"1"`, every download path throws `AcervoError.offlineModeActive`. Like the App Group var, it's read on every Acervo call, so any test that sets it briefly will trip the gate for any concurrent test that fetches a manifest or a file.

Swift Testing runs `@Suite` types in parallel by default. The two patterns that work reliably are:

### 1. Serialize all env-mutating tests under a single parent

If your tests set `ACERVO_APP_GROUP_ID` or `ACERVO_OFFLINE`, nest them under a single `.serialized` parent suite — and put the *readers* there too. Anything that calls `Acervo.download`, `Acervo.fetchManifest`, `Acervo.ensureAvailable`, `Acervo.modelDirectory(for:)`, or `Acervo.sharedModelsDirectory` is a reader.

```swift
@Suite("My Acervo Tests", .serialized)
struct MyAcervoTests {

    @Test("download writes into a per-test App Group container")
    func usesIsolatedGroup() async throws {
        let testGroupID = "group.mytests.acervo.\(UUID().uuidString.lowercased())"
        let previous = ProcessInfo.processInfo.environment["ACERVO_APP_GROUP_ID"]
        setenv("ACERVO_APP_GROUP_ID", testGroupID, 1)
        defer {
            if let previous {
                setenv("ACERVO_APP_GROUP_ID", previous, 1)
            } else {
                unsetenv("ACERVO_APP_GROUP_ID")
            }
            // Clean up the per-test container directory.
            let groupRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Group Containers")
                .appendingPathComponent(testGroupID)
            try? FileManager.default.removeItem(at: groupRoot)
        }

        try await Acervo.download(modelId: "org/repo", files: [])
        // ... assertions ...
    }
}
```

The `.serialized` trait orders all tests *within* the suite. Tests in *sibling* suites still run in parallel with this one, so they must not touch the same env vars.

### 2. Don't read the global at all

Path-construction logic that depends on `sharedModelsDirectory` should use the `in: baseDirectory` overloads where they exist (e.g. `Acervo.isModelAvailable(_:in:)`, `Acervo.listModels(in:)`). They take the base directory as an explicit parameter and never touch the env var, so they're race-immune by construction.

```swift
let tempBase = FileManager.default.temporaryDirectory
    .appendingPathComponent("my-test-\(UUID())")
try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tempBase) }

// No global read — fully isolated, safe to run in parallel.
let models = try Acervo.listModels(in: tempBase)
#expect(models.isEmpty)
```

For pure path helpers, `Acervo.slugify(_:)` is a pure function and is always safe to call from any context.

### What goes wrong without isolation

The classic flake mode: test A sets `ACERVO_APP_GROUP_ID` to its per-test value, reads `Acervo.sharedModelsDirectory`, expecting its own path. Concurrent test B overwrites the env var between A's set and read. A receives B's path and the assertion fails. The same shape applies to `ACERVO_OFFLINE`: an unrelated test that briefly sets it can cause a sibling test's `Acervo.fetchManifest` call to throw `offlineModeActive` instead of completing.

If you see intermittent CI failures asserting on a path component or catching `offlineModeActive` unexpectedly, the cause is almost always cross-suite env-var contention — not a bug in Acervo's behavior.

---

## Real-World Examples

### Reference implementation: SwiftBruja (MLX + Tokenizers)

[SwiftBruja](https://github.com/intrusive-memory/SwiftBruja) is the canonical consumer. Its `BrujaDownloadManager` is a thin actor that delegates to SwiftAcervo with manifest-first semantics, and its `BrujaModelManager` loads the result with `MLXLLM.LLMModelFactory`. The core call sequence:

```swift
import SwiftAcervo
import MLXLLM           // For LLMModelFactory
import MLXLMCommon      // For ModelContainer
import MLXLMTokenizers  // For the tokenizer loader overload

let modelId = "mlx-community/Qwen2.5-7B-Instruct-4bit"

// 1. Ensure the full model is on disk. No files: array — the manifest decides.
try await Acervo.ensureAvailable(modelId, files: []) { progress in
    let percentage = Int(progress.overallProgress * 100)
    print("\r\u{1B}[KDownload progress: \(percentage)%", terminator: "")
    fflush(stdout)
}

// 2. Guard on the local validity marker before loading.
guard Acervo.isModelAvailable(modelId) else {
    throw BrujaError.modelNotFound(
        "Model '\(modelId)' not found at \(Acervo.sharedModelsDirectory.path)"
    )
}

// 3. Resolve the directory and load with MLX.
let modelDir = try Acervo.modelDirectory(for: modelId)
let container: ModelContainer = try await LLMModelFactory.shared.loadContainer(
    from: modelDir
)
```

SwiftBruja's public surface (`Bruja.query(_:model:)`) wraps this sequence: it guards with `Acervo.isModelAvailable`, calls `Acervo.modelDirectory(for:)`, and hands the URL to `LLMModelFactory`. Downloads go through `BrujaDownloadManager.downloadModel(_:force:progress:)`, which calls `Acervo.ensureAvailable(modelId, files: [])` — i.e. manifest-driven, empty file list. See `Sources/SwiftBruja/Core/BrujaDownloadManager.swift` and `Sources/SwiftBruja/Core/BrujaModelManager.swift` for the full implementation.

The `bruja` CLI (`Sources/bruja/BrujaCLI.swift`) mirrors the same pattern from the command line, including a `--force` flag that calls `Acervo.deleteModel(_:)` before re-downloading.

### mlx-audio-swift (Text-to-Speech)

```swift
import SwiftAcervo

let ttsModelId = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"
let codecModelId = "mlx-community/snac_24khz"

// Batch the TTS stack; let each model's manifest drive its own download.
try await ModelDownloadManager.shared.ensureModelsAvailable(
    [ttsModelId, codecModelId]
) { progress in
    print("[\(progress.model)] \(Int(progress.fraction * 100))%")
}

let ttsDir = try Acervo.modelDirectory(for: ttsModelId)
let codecDir = try Acervo.modelDirectory(for: codecModelId)
```

### SwiftVoxAlta (Voice Processing)

```swift
import SwiftAcervo

let voiceModelId = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"

// Thread-safe download. `files: []` = "whatever the manifest says".
try await AcervoManager.shared.download(voiceModelId, files: []) { progress in
    print("Voice model: \(Int(progress.overallProgress * 100))%")
}

// Exclusive access while reading the model's config.
let voiceConfig = try await AcervoManager.shared.withModelAccess(voiceModelId) { dir in
    let configURL = dir.appendingPathComponent("config.json")
    return try Data(contentsOf: configURL)
}
```

### Produciesta (Production App)

```swift
import SwiftAcervo

// At app launch: migrate legacy paths if any, then warm the cache.
let migrated = try Acervo.migrateFromLegacyPaths()
if !migrated.isEmpty {
    print("Migrated \(migrated.count) model(s) to SharedModels")
}
try await AcervoManager.shared.preloadModels()

// Show the user what's on disk. This is purely local — no manifest fetches.
let available = try Acervo.listModels()
let families = try Acervo.modelFamilies()
for (family, variants) in families {
    print("\(family): \(variants.count) variant(s)")
}

// When the user picks a model to use, ensure it's present with the manifest-first form.
try await ModelDownloadManager.shared.ensureModelsAvailable(
    [selectedModelId]
) { progress in
    // render a progress bar
}
```

---

## CLI Progress Bars

`AcervoDownloadProgress` and `ModelDownloadProgress` are both `Sendable` and byte-accurate. A minimal renderer with a TTY guard:

```swift
import SwiftAcervo
#if canImport(Darwin)
import Darwin
#endif

func renderBar(_ fraction: Double, label: String) {
    guard isatty(fileno(stdout)) != 0 else { return }   // no ANSI in log files
    let width = 30
    let filled = Int((fraction * Double(width)).rounded())
    let bar = String(repeating: "█", count: filled)
            + String(repeating: "·", count: width - filled)
    print("\r\(label) [\(bar)] \(Int(fraction * 100))%", terminator: "")
    fflush(stdout)
}

try await ModelDownloadManager.shared.ensureModelsAvailable(modelIds) { p in
    renderBar(p.fraction, label: p.model)
}
print()
```

A few conventions worth following so your CLI behaves well in pipes, CI logs, and `--quiet` invocations:

- **TTY guard.** Skip the bar when stdout isn't a terminal.
- **`--quiet` / `-q` flag.** Suppresses the bar; errors still go to stderr. Pass `nil` for the progress callback when quiet.
- **Don't capture UI state in the callback.** It fires from a background task and must remain `Sendable`-safe.

The `acervo` CLI in this repo uses [Progress.swift](https://github.com/jkandzi/Progress.swift) through a `ProgressReporter` wrapper that encodes all of the above. See `Sources/acervo/ProgressReporter.swift` for the wiring. SwiftAcervo itself pulls in no terminal dependencies.

---

## FAQ

### Q: Do I have to list files in `ensureAvailable` or `download`?

No. Pass `files: []` to download the whole manifest. That's the preferred default. Listing files is an escape hatch for when you genuinely need to narrow the download.

### Q: What happens if I list a file that isn't in the manifest?

`AcervoError.fileNotInManifest(fileName:modelId:)` is thrown before any download begins. Validation happens after the manifest is fetched and parsed.

### Q: How do I see what files a model has without downloading it?

Call `Acervo.fetchManifest(for: modelId)` (or `fetchManifest(forComponent: componentId)` if you have it registered). Iterate `manifest.files` for paths, sizes, and SHA-256s.

### Q: Can I register a component without knowing its file list?

Yes. Use the bare `ComponentDescriptor.init(id:type:displayName:repoId:minimumMemoryBytes:metadata:)`. `Acervo.ensureComponentReady(_:)` hydrates the descriptor on first call; you can also call `Acervo.hydrateComponent(_:)` yourself to populate without downloading.

### Q: What if I want a pre-hydration size estimate for UI?

Use the full `ComponentDescriptor` init with a placeholder `estimatedSizeBytes`. The declared value is shown until hydration completes, at which point the registry replaces it with the manifest's actual total.

### Q: Can multiple apps share the same downloaded model?

Yes. All intrusive-memory projects use the App Group container `group.intrusive-memory.models`. A model downloaded by any one tool is immediately visible to all others.

### Q: What if a download fails partway through?

Partial files remain on disk. The next call to `ensureAvailable` / `download` resumes — it skips files that already exist at the right size and re-downloads corrupt or missing ones.

### Q: Can I cancel a download?

Cancel the calling `Task`. SwiftAcervo uses `URLSession` with cooperative cancellation; in-flight child tasks stop, and partial files remain for resume on next attempt.

### Q: Is `isComponentReady` sync or async?

Both. The sync version (`Acervo.isComponentReady(_:)`) returns `false` for un-hydrated descriptors — it can't do a network fetch. After hydration (or for descriptors declared with explicit `files:`), it's accurate. Use `Acervo.isComponentReadyAsync(_:)` if you need a correct answer regardless of hydration state.

---

## See Also

- **[API_REFERENCE.md](API_REFERENCE.md)** — Complete method reference
- **[DESIGN_PATTERNS.md](DESIGN_PATTERNS.md)** — Per-model locking, streaming verification, etc.
- **[SHARED_MODELS_DIRECTORY.md](SHARED_MODELS_DIRECTORY.md)** — Where models are stored
- **[README.md](README.md)** — User-facing overview
