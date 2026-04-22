# USAGE.md — Integration Guide for Consuming Libraries

**For**: App and library developers integrating SwiftAcervo for model discovery and downloading.

**TL;DR**: Add SwiftAcervo to your `Package.swift`, call `Acervo.ensureAvailable()` or `ModelDownloadManager.shared.ensureModelsAvailable()` at startup with your required models, and you're done. Models downloaded by any app are immediately available to all others.

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
        .package(url: "https://github.com/intrusive-memory/SwiftAcervo.git", from: "0.7.3")
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

### 2. Ensure Models Are Available

**For single models**, use `Acervo.ensureAvailable()`:

```swift
import SwiftAcervo

try await Acervo.ensureAvailable(
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    files: ["config.json", "tokenizer.json", "model.safetensors"]
) { progress in
    let percent = Int(progress.overallProgress * 100)
    print("Download: \(percent)%")
}
```

**For multiple models**, use `ModelDownloadManager`:

```swift
try await ModelDownloadManager.shared.ensureModelsAvailable([
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"
]) { progress in
    let percent = Int(progress.fraction * 100)
    print("[\(progress.model)] \(percent)% (\(progress.bytesDownloaded / 1024 / 1024) MB)")
}
```

### 3. Load Models from Disk

```swift
let modelDir = try Acervo.modelDirectory(for: "mlx-community/Qwen2.5-7B-Instruct-4bit")
// Pass modelDir to your framework (MLX, etc.)
```

---

## Integration Checklist

- [ ] Add SwiftAcervo dependency to `Package.swift`
- [ ] Define which files your model needs (e.g., `config.json`, `model.safetensors`)
- [ ] Call `Acervo.ensureAvailable()` or `ModelDownloadManager.shared.ensureModelsAvailable()` at app startup
- [ ] Provide progress feedback to users via the progress callback
- [ ] Handle download errors (`AcervoError`) and convert to app-specific errors
- [ ] Call `Acervo.modelDirectory(for:)` to get the path for loading
- [ ] Test offline (ensure local models can still load without network)

---

## Real-World Examples

### SwiftBruja (MLX Inference)

```swift
import SwiftAcervo
import SwiftBruja

let modelId = "mlx-community/Qwen2.5-7B-Instruct-4bit"

// Ensure the model is downloaded
try await Acervo.ensureAvailable(modelId, files: [
    "config.json",
    "tokenizer.json",
    "tokenizer_config.json",
    "model.safetensors"
])

// Get the local directory and load with MLX
let modelDir = try Acervo.modelDirectory(for: modelId)
let engine = try BrujaEngine(modelPath: modelDir)
let response = try await engine.generate(prompt: "Explain quantum computing")
```

### mlx-audio-swift (Text-to-Speech)

```swift
import SwiftAcervo

let ttsModelId = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"
let codecModelId = "mlx-community/snac_24khz"

// Ensure both TTS and codec models are available
try await Acervo.ensureAvailable(ttsModelId, files: [
    "config.json",
    "model.safetensors",
    "speech_tokenizer/config.json"
])
try await Acervo.ensureAvailable(codecModelId, files: [
    "config.json",
    "model.safetensors"
])

// Both model directories are now ready
let ttsDir = try Acervo.modelDirectory(for: ttsModelId)
let codecDir = try Acervo.modelDirectory(for: codecModelId)
```

### SwiftVoxAlta (Voice Processing)

```swift
import SwiftAcervo

let voiceModelId = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"

// Thread-safe download with progress tracking
try await AcervoManager.shared.download(voiceModelId, files: [
    "config.json",
    "model.safetensors",
    "speech_tokenizer/config.json"
]) { progress in
    print("Voice model: \(Int(progress.overallProgress * 100))%")
}

// Exclusive access while reading model configuration
let voiceConfig = try await AcervoManager.shared.withModelAccess(voiceModelId) { dir in
    let configURL = dir.appendingPathComponent("config.json")
    return try Data(contentsOf: configURL)
}
```

### Produciesta (Production App)

```swift
import SwiftAcervo

// At app launch: migrate any models from the old cache structure
let migrated = try Acervo.migrateFromLegacyPaths()
if !migrated.isEmpty {
    print("Migrated \(migrated.count) model(s) to SharedModels")
}

// Preload the cache so model lookups are fast throughout the session
try await AcervoManager.shared.preloadModels()

// Check which models the user has available
let available = try Acervo.listModels()
let families = try Acervo.modelFamilies()
for (family, variants) in families {
    print("\(family): \(variants.count) variant(s)")
}
```

---

## Common Patterns

### Pattern 1: Validate CDN Availability Before Downloading

Check if a model exists on the CDN and has all required files **without downloading**, then optionally download with user feedback:

```swift
import SwiftAcervo

func validateAndEnsureModel(
    modelId: String, 
    requiredFiles: [String]
) async throws {
    // Step 1: Check local availability (fast path)
    if Acervo.isModelAvailable(modelId) {
        return  // Already downloaded, skip validation
    }
    
    // Step 2: Validate on CDN without downloading (read-only)
    let model = try Acervo.modelInfo(modelId)
    
    // Step 3: Verify all required files exist in manifest
    let manifestFiles = Set(model.files.map { $0.path })
    let requiredSet = Set(requiredFiles)
    
    guard requiredSet.isSubset(of: manifestFiles) else {
        let missing = Array(requiredSet.subtracting(manifestFiles))
        throw YourError.missingFiles(missing)
    }
    
    // Step 4: Download if validation passed
    try await Acervo.ensureAvailable(modelId, files: requiredFiles) { progress in
        let percent = Int(progress.overallProgress * 100)
        let mb = progress.completedUnitCount / (1024 * 1024)
        print("Downloading: \(percent)% (\(mb) MB)")
    }
}
```

**Use case**: Loading a model that requires specific files (e.g., "I need a tokenizer.json, not just config.json").

### Pattern 2: Multi-Model Download with Validation

```swift
import SwiftAcervo

func ensureAllModelsAvailable(_ modelIds: [String]) async throws {
    // Validate disk space first
    let totalBytes = try await ModelDownloadManager.shared.validateCanDownload(modelIds)
    let totalMB = totalBytes / (1024 * 1024)
    print("Will download \(totalMB) MB total")
    
    // Download with aggregate progress
    try await ModelDownloadManager.shared.ensureModelsAvailable(modelIds) { progress in
        let percent = Int(progress.fraction * 100)
        let mb = progress.bytesDownloaded / (1024 * 1024)
        let total = progress.bytesTotal / (1024 * 1024)
        print("\r[\(progress.model)] \(percent)% (\(mb)/\(total) MB)", terminator: "")
        fflush(stdout)
    }
    
    print("\nAll models ready!")
}
```

**Use case**: App startup, multiple models, user-visible progress bar.

### Pattern 3: Thread-Safe Access During Inference

```swift
import SwiftAcervo

// In your inference engine
async func generateResponse(prompt: String) async throws -> String {
    return try await AcervoManager.shared.withModelAccess(
        "mlx-community/Qwen2.5-7B-Instruct-4bit"
    ) { modelDir in
        // Load model from modelDir
        let engine = try loadEngine(from: modelDir)
        
        // Inference runs while holding the lock
        // No other task can download or modify this model
        let response = try await engine.generate(prompt: prompt)
        
        return response
    }
}
```

**Use case**: Concurrent inference requests, need exclusive model access.

### Pattern 4: Custom LoRA Adapter Access

```swift
import SwiftAcervo

let baseModelId = "mlx-community/Qwen2.5-7B-Instruct-4bit"
let loraURL = URL(filePath: "/path/to/my-lora-adapter")

// Download base model
try await Acervo.ensureAvailable(baseModelId, files: ["config.json", "model.safetensors"])

// Access base model + custom LoRA with scoped handles
let baseModelDir = try Acervo.modelDirectory(for: baseModelId)
let loraWeights = try await AcervoManager.shared.withLocalAccess(loraURL) { loraHandle in
    let loraFile = try loraHandle.url(matching: ".safetensors")
    return try Data(contentsOf: loraFile)
}

// Load both into engine
let engine = try loadEngine(baseDir: baseModelDir, loraWeights: loraWeights)
```

**Use case**: User-supplied adapters or fine-tuned weights alongside downloaded base models.

---

## Error Handling

### AcervoError Types

Catch these and convert to app-specific errors:

```swift
import SwiftAcervo

do {
    try await Acervo.ensureAvailable(modelId, files: files)
} catch let error as AcervoError {
    switch error {
    case .modelNotFound(let id):
        showError("Model '\(id)' not found on CDN")
    
    case .manifestChecksumMismatch(let id):
        showError("Model '\(id)' manifest is corrupted")
    
    case .downloadFailed(let reason):
        showError("Download failed: \(reason) (try again later)")
    
    case .checksumMismatch(let fileName):
        showError("File '\(fileName)' corrupted during download")
    
    case .fileNotInManifest(let fileName, let modelId):
        showError("Model '\(modelId)' doesn't include '\(fileName)'")
    
    case .downloadSizeMismatch(let fileName, let expected, let actual):
        showError("File '\(fileName)' size mismatch (\(actual) vs \(expected) bytes)")
    
    default:
        showError("Unknown error: \(error.localizedDescription)")
    }
} catch {
    showError("Unexpected error: \(error.localizedDescription)")
}
```

### Best Practices

1. **Always validate disk space first** — Call `ModelDownloadManager.validateCanDownload()` before user-initiated downloads
2. **Show aggregate progress** — Display total MB downloaded, not per-model percentages
3. **Handle network errors gracefully** — Transient failures are common; offer retry
4. **Distinguish model types** — Include model name/type in progress output ("TTS model: 45%", not just "45%")
5. **Serialize model downloads** — `ModelDownloadManager` handles this for you
6. **Cache availability checks** — Don't repeatedly call `isModelAvailable()` in hot loops

---

## FAQ

### Q: What files does my model need?

Check the model's directory after downloading:

```bash
ls -la ~/Library/Containers/group.intrusive-memory.models/SharedModels/mlx-community_Qwen2.5-7B-Instruct-4bit/
```

Or fetch metadata from CDN without downloading:

```swift
let model = try Acervo.modelInfo("mlx-community/Qwen2.5-7B-Instruct-4bit")
for file in model.files {
    print("\(file.path) (\(file.sizeBytes) bytes)")
}
```

### Q: Can multiple apps share the same downloaded model?

Yes! All intrusive-memory projects use `group.intrusive-memory.models` (the App Group container). A model downloaded by SwiftBruja is immediately available to mlx-audio-swift, SwiftVoxAlta, etc.

### Q: What if the download fails partway through?

Partial files remain on disk. The next call to `ensureAvailable()` or `download()` will retry from where it left off (or re-download the corrupted file).

### Q: Can I use this in async contexts?

Yes. Both `Acervo.ensureAvailable()` and `AcervoManager.shared.download()` are `async/await` native. They're safe to call from any async context.

### Q: Do I need to check if a model exists before calling `ensureAvailable()`?

No. `ensureAvailable()` is idempotent — it checks locally first, skips the download if already present, and only downloads if needed.

### Q: What if my model is a single large file instead of multiple shards?

Just specify one file:

```swift
try await Acervo.ensureAvailable(modelId, files: ["config.json", "model.safetensors"])
```

SwiftAcervo handles both single-file and multi-shard models transparently.

### Q: How do I handle downloads in the background?

Use `AcervoManager` for thread-safe operations:

```swift
Task(priority: .background) {
    try await AcervoManager.shared.download(modelId, files: files)
}
```

Different models download in parallel; the same model is serialized.

### Q: Can I cancel a download?

Not directly. SwiftAcervo uses URLSession, which respects task cancellation. If you cancel the calling task, the download stops (and partial files remain for resume on next attempt).

---

## See Also

- **[API_REFERENCE.md](API_REFERENCE.md)** — Complete method reference
- **[DESIGN_PATTERNS.md](DESIGN_PATTERNS.md)** — Per-model locking, streaming verification, etc.
- **[SHARED_MODELS_DIRECTORY.md](SHARED_MODELS_DIRECTORY.md)** — Where models are stored
- **[README.md](README.md)** — User-facing overview
