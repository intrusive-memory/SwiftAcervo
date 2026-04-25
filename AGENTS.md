# AGENTS.md — Documentation Hub for AI Agents

This file serves as a navigation hub for AI agents working with the SwiftAcervo codebase.

**Current Version**: 0.8.2 (April 2026)

**For detailed documentation**, see the focused guides below. **For consuming library integration**, start with **[USAGE.md](USAGE.md)**.

---

## What is SwiftAcervo?

SwiftAcervo solves a critical problem: AI applications on macOS and iOS each manage their own model storage, resulting in:
- **Disk duplication** — The same 4GB model downloaded by SwiftBruja and mlx-audio-swift takes 8GB total
- **Invisible to others** — A model downloaded by one app can't be found by another
- **Fragile paths** — Every project hardcodes its own cache directory

**Solution**: One canonical directory in the App Group container (`group.intrusive-memory.models`). Models downloaded by any app are immediately visible to all others.

SwiftAcervo provides:
- **Discovery** — Find models by name or fuzzy search
- **Downloading** — From a private Cloudflare R2 CDN with per-file SHA-256 verification
- **Thread-safe access** — Per-model locking via `AcervoManager`
- **CLI tool** (`acervo`) — Upload and manage models on the CDN

SwiftAcervo does **NOT** load models — that's the consumer's job (MLX, Core ML, etc.).

---

## Manifest-Driven File Selection (v0.8.0)

A consuming library does not know what files exist inside a model until the CDN manifest comes back. The manifest is the only authoritative source; consumer-supplied file names are validated against it, and files not present throw `AcervoError.fileNotInManifest`. Three consumption levels — all manifest-driven — cover the common cases:

1. **`ModelDownloadManager.ensureModelsAvailable(_:progress:)`** — batch, highest level. Give it model IDs; it fetches manifests and downloads everything.
2. **`Acervo.ensureAvailable(_, files: [], progress:)`** — single model with empty `files:` array, which means "download whatever the manifest lists."
3. **`Acervo.ensureComponentReady(_, progress:)`** on a bare `ComponentDescriptor`** — registered components auto-hydrate from the manifest on first call.

Hard-coding a specific `files: [...]` array is supported as an escape hatch (pre-release models, explicit subset downloads) but should not be the default. See [USAGE.md](USAGE.md) for details and runnable examples.

---

## Documentation Map

### 🎯 For Consuming Libraries (**Start Here**)

- **[USAGE.md](USAGE.md)** — Integration guide, quick start, examples, FAQ
  - How to add SwiftAcervo to your project
  - Common patterns and best practices
  - Error handling
  - Real-world examples: SwiftBruja, mlx-audio-swift, SwiftVoxAlta, Produciesta

### 📚 Complete API Reference

- **[API_REFERENCE.md](API_REFERENCE.md)** — All methods, types, and error cases
  - `Acervo` static API
  - `AcervoManager` actor API
  - `ModelDownloadManager` for batch downloads
  - Supporting types (AcervoModel, AcervoError, ComponentDescriptor, etc.)

### 🌐 Model Storage and Discovery

- **[SHARED_MODELS_DIRECTORY.md](SHARED_MODELS_DIRECTORY.md)** — Where models live
  - Canonical path: `<App Group Container>/SharedModels/`
  - Directory structure and naming conventions
  - Validity marker (`config.json`)
  - Migration from legacy paths
  - Troubleshooting and permissions

### 🛠️ Building, Testing, and CLI

- **[BUILD_AND_TEST.md](BUILD_AND_TEST.md)** — Build commands and acervo CLI
  - Make targets (build, test, lint, clean)
  - `acervo` CLI tool for CDN operations
  - Unit tests (no network) vs integration tests
  - CI/CD (GitHub Actions)
  - Troubleshooting

### 🌐 CDN Operations

- **[CDN_UPLOAD.md](CDN_UPLOAD.md)** — How to upload models to the CDN
  - Full pipeline: `acervo ship --model-id "org/repo"`
  - Step-by-step commands (download, manifest, verify, upload)
  - Environment variables and credentials
  - Troubleshooting and best practices

- **[CDN_ARCHITECTURE.md](CDN_ARCHITECTURE.md)** — How downloads work internally
  - 7-step download flow with verification
  - Manifest format and manifest checksum
  - Security properties (integrity, authenticity, non-repudiation)
  - Concurrent downloads and retry logic

### 🏗️ Architecture and Design

- **[DESIGN_PATTERNS.md](DESIGN_PATTERNS.md)** — Why SwiftAcervo is designed this way
  - Static API + Actor pattern
  - CDN-only downloads
  - Per-file manifest verification
  - Streaming SHA-256 verification
  - Per-model locking
  - Atomic downloads
  - Zero external dependencies

- **[PROJECT_STRUCTURE.md](PROJECT_STRUCTURE.md)** — How the code is organized
  - File layout (Sources/, Tests/, Tools/)
  - Module purposes and dependencies
  - Library vs CLI vs tests
  - Package configuration

- **[REQUIREMENTS.md](REQUIREMENTS.md)** — Component registry specification (draft)
  - v2 design for declarative model registration
  - ComponentDescriptor types
  - Deduplication across plugins

- **[ARCHITECTURE.md](ARCHITECTURE.md)** — Ecosystem dependency map
  - Where SwiftAcervo fits
  - What other packages depend on it
  - Interface contracts for plugins

### 📖 General Information

- **[README.md](README.md)** — User-facing overview
  - Installation (Homebrew, SPM)
  - Quick start examples
  - Thread safety guarantees
  - Design principles

- **[CONTRIBUTING.md](CONTRIBUTING.md)** — Development guidelines
  - How to contribute
  - Code conventions
  - PR process

- **[CLAUDE.md](CLAUDE.md)** — AI agent reference (this project's special instructions)
  - Quick reference for Claude Code
  - Critical rules for SwiftAcervo development

---

## Quick API Summary

### Static API: `Acervo`

```swift
import SwiftAcervo

// Availability
Acervo.isModelAvailable("mlx-community/Qwen2.5-7B-Instruct-4bit")

// Manifest-first download (empty files: = download whole manifest)
try await Acervo.ensureAvailable(
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    files: []
)

// Registered components (auto-hydrated from manifest on first use)
try await Acervo.ensureComponentReady("qwen2.5-3b-instruct-4bit")
try await Acervo.hydrateComponent("qwen2.5-3b-instruct-4bit")  // manifest only, no download

// Raw manifest access
let byId = try await Acervo.fetchManifest(for: "mlx-community/Qwen2.5-7B-Instruct-4bit")
let byComponent = try await Acervo.fetchManifest(forComponent: "qwen2.5-3b-instruct-4bit")

// Discovery
let models = try Acervo.listModels()
let matches = try Acervo.findModels(matching: "Qwen")
```

**Full reference**: [API_REFERENCE.md](API_REFERENCE.md)

### Actor API: `AcervoManager`

```swift
// Thread-safe downloads (per-model locking)
try await AcervoManager.shared.download(modelId, files: [...])

// Exclusive access during reads
let config = try await AcervoManager.shared.withModelAccess(modelId) { dir in
    // Access files safely, lock held
}
```

**Full reference**: [API_REFERENCE.md](API_REFERENCE.md)

### Multi-Model Downloads: `ModelDownloadManager`

```swift
// Batch download multiple models with progress
try await ModelDownloadManager.shared.ensureModelsAvailable([
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"
]) { progress in
    print("[\(progress.model)] \(Int(progress.fraction * 100))%")
}
```

**Full reference**: [API_REFERENCE.md](API_REFERENCE.md)

### CLI Progress Bars in Consumer Tools

Command-line utilities that drive SwiftAcervo downloads should surface a live progress bar via the callbacks every download entry point already exposes. SwiftAcervo itself has zero terminal dependencies — the callback gives consumers everything they need to render whatever bar they want.

**Callback types** (both `Sendable`):

- `AcervoDownloadProgress` — passed to `Acervo.download` / `Acervo.ensureAvailable` / `AcervoManager.download`. Fields: `fileName`, `bytesDownloaded`, `totalBytes`, `fileIndex`, `totalFiles`, `overallProgress` (`0.0...1.0`, byte-accurate).
- `ModelDownloadProgress` — passed to `ModelDownloadManager.ensureModelsAvailable`. Fields: `model`, `fraction` (`0.0...1.0`, cumulative across the batch), `bytesDownloaded`, `bytesTotal`, `currentFileName`.

**Minimal zero-dep pattern** (works in any Swift CLI):

```swift
import SwiftAcervo

func renderBar(_ fraction: Double, label: String) {
    let width = 30
    let filled = Int((fraction * Double(width)).rounded())
    let bar = String(repeating: "█", count: filled)
               + String(repeating: "·", count: width - filled)
    print("\r\(label) [\(bar)] \(Int(fraction * 100))%", terminator: "")
    fflush(stdout)
}

try await Acervo.ensureAvailable(modelId, files: [...]) { p in
    renderBar(p.overallProgress, label: p.fileName)
}
print()
```

**Conventions consumer CLIs should follow:**

1. **TTY guard** — skip the bar when `isatty(fileno(stdout)) == 0`. ANSI escapes belong in terminals, not log files.
2. **`--quiet` / `-q` flag** — suppress the bar; errors still go to stderr. Pass `nil` for the callback when quiet to avoid doing callback work you will discard.
3. **Background execution** — the callback fires from the download task; keep it `Sendable`-safe (no UI state, no non-`Sendable` captures).
4. **Line-based fallback** — when not a TTY, either emit per-file lines (`"downloaded config.json"`) or stay silent.

**Reference implementation**: the `acervo` CLI in this repo uses [Progress.swift](https://github.com/jkandzi/Progress.swift) through a thin `ProgressReporter` wrapper that encodes all four conventions above. See `Sources/acervo/ProgressReporter.swift` and its use in `Sources/acervo/Commands/DownloadCommand.swift`. Consumers that want the richer renderer (elapsed time, ETA, throughput) can take the same dependency; consumers that want to stay dependency-free can use the minimal pattern above. **The SwiftAcervo library itself never pulls in Progress.swift** — that dependency lives in the CLI target only.

---

## Common Questions

**Q: How do I integrate SwiftAcervo into my app?**
→ Start with [USAGE.md](USAGE.md)

**Q: What methods are available?**
→ See [API_REFERENCE.md](API_REFERENCE.md)

**Q: Where are models stored?**
→ See [SHARED_MODELS_DIRECTORY.md](SHARED_MODELS_DIRECTORY.md)

**Q: How do I upload a model to the CDN?**
→ See [CDN_UPLOAD.md](CDN_UPLOAD.md)

**Q: How do downloads work internally?**
→ See [CDN_ARCHITECTURE.md](CDN_ARCHITECTURE.md)

**Q: Why is SwiftAcervo designed this way?**
→ See [DESIGN_PATTERNS.md](DESIGN_PATTERNS.md)

**Q: How do I build and test SwiftAcervo?**
→ See [BUILD_AND_TEST.md](BUILD_AND_TEST.md)

---

## Key Principles

1. **Zero external dependencies** — Foundation + CryptoKit only
2. **CDN-only downloads** — All from private Cloudflare R2
3. **Per-file verification** — SHA-256 manifest integrity checking
4. **Shared models** — One App Group container for all intrusive-memory projects
5. **Not a model loader** — SwiftAcervo finds and downloads; consumers load
6. **iOS 26.0+ and macOS 26.0+ only** — No legacy platform support
7. **Swift 6 strict concurrency** — `@Sendable` closures, actors, no data races

---

## See Also

- **[CLAUDE.md](CLAUDE.md)** for AI agent development guidance
- **[README.md](README.md)** for user overview
- **[CONTRIBUTING.md](CONTRIBUTING.md)** for development guidelines
