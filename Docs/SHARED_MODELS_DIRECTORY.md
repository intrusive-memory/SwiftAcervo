# SHARED_MODELS_DIRECTORY.md — Canonical Model Storage Location

**For**: Developers who need to understand where models are stored and why.

**CRITICAL**: All intrusive-memory projects MUST use SwiftAcervo's `sharedModelsDirectory` for model storage. Never hardcode a different path.

---

## Canonical Path

```
~/Library/Group Containers/<app-group-id>/SharedModels/
```

The same path applies to UI apps (where the OS mounts the App Group container into the sandbox at this location) and CLI tools (which read/write the directory directly via filesystem permissions). This is what makes cross-process model sharing work — every consumer lands at the same directory.

### Resolving the App Group identifier

SwiftAcervo learns the App Group ID at runtime in two ways:

1. **`ACERVO_APP_GROUP_ID` environment variable** — used by CLI tools, scripts, test runners, and anything else without an entitlements file. Typically set in `~/.zprofile`:
   ```sh
   export ACERVO_APP_GROUP_ID=group.intrusive-memory.models
   ```
2. **`com.apple.security.application-groups` entitlement** — read off the running binary via `SecTaskCopyValueForEntitlement`. Used by signed UI apps. SwiftAcervo takes the **first** group in the array.

The env var wins if both are set.

**There is no fallback path.** If neither source supplies a value, `Acervo.sharedModelsDirectory` calls `fatalError`. A per-process `Application Support/...` fallback is exactly the divergence App Groups exist to prevent: a CLI and a UI app would land at different paths and stop sharing.

### Getting the Path

```swift
import SwiftAcervo

let sharedDir = Acervo.sharedModelsDirectory
// macOS: ~/Library/Group Containers/<group-id>/SharedModels/
// iOS:   <App Group Container>/SharedModels/ (mounted into the app sandbox)
```

**Never hardcode this path.** Always use `Acervo.sharedModelsDirectory`.

---

## Directory Structure

```
<App Group Container>/SharedModels/
├── mlx-community_Qwen2.5-7B-Instruct-4bit/
│   ├── config.json                    ← Validity marker
│   ├── tokenizer.json
│   ├── tokenizer_config.json
│   └── model.safetensors              ← Sharded or single file
├── mlx-community_Qwen3-TTS-12Hz-1.7B-Base-bf16/
│   ├── config.json                    ← Validity marker
│   ├── model.safetensors
│   └── speech_tokenizer/
│       ├── config.json
│       └── model.safetensors
├── mlx-community_snac_24khz/
│   ├── config.json                    ← Validity marker
│   └── model.safetensors
└── (more models...)
```

### Key Rules

1. **Directory naming**: Model ID with `/` replaced by `_`
   - Model ID: `mlx-community/Qwen2.5-7B-Instruct-4bit`
   - Directory: `mlx-community_Qwen2.5-7B-Instruct-4bit`

2. **No type subdirectories**: LLM, TTS, Audio are all peers
   - ❌ WRONG: `SharedModels/LLM/mlx-community_Qwen.../`
   - ✅ CORRECT: `SharedModels/mlx-community_Qwen.../`

3. **Validity marker**: `config.json` must be present
   - ✅ A directory with `config.json` is a valid model
   - ❌ A directory without `config.json` is invalid/incomplete

4. **No hardcoded paths**: Every project uses `Acervo.sharedModelsDirectory`
   - ❌ WRONG: `~/Library/Caches/myapp/models/`
   - ✅ CORRECT: `Acervo.sharedModelsDirectory.appendingPathComponent("model_id")`

5. **Flat structure**: No sub-typing or categorization
   - Models are organized by model ID, not by type or function

---

## Model Families and Variants

SwiftAcervo groups similar models into families for discovery:

```swift
let families = try Acervo.modelFamilies()
// Returns: [String: [AcervoModel]]
// Example:
// "mlx-community/Qwen2.5" → [4bit variant, 8bit variant, full precision variant]
// "mlx-community/Qwen3-TTS" → [1.7B variant, 0.6B variant]
```

**Base name extraction** (automatic):
- Full ID: `mlx-community/Qwen2.5-7B-Instruct-4bit`
- Base name: `Qwen2.5` (quantization/size/variant suffixes removed)
- Family name: `mlx-community/Qwen2.5` (org + base name)

**Usage**:
```swift
for (family, variants) in families {
    print("\(family): \(variants.count) variant(s)")
    for variant in variants {
        print("  \(variant.id) (\(variant.formattedSize))")
    }
}
```

---

## Model Discovery

### Check Local Availability

```swift
if Acervo.isModelAvailable("mlx-community/Qwen2.5-7B-Instruct-4bit") {
    let dir = try Acervo.modelDirectory(for: "mlx-community/Qwen2.5-7B-Instruct-4bit")
    // Load model from dir
}
```

### List All Models

```swift
let allModels = try Acervo.listModels()
for model in allModels {
    print("\(model.id): \(model.formattedSize)")
}
```

### Find Models by Name

```swift
// Substring search (case-insensitive)
let qwenModels = try Acervo.findModels(matching: "Qwen")

// Fuzzy search (tolerates typos)
let fuzzyMatches = try Acervo.findModels(fuzzyMatching: "Qwen2.5-7B-Instrct")

// Single best match
if let closest = try Acervo.closestModel(to: "Qwen2.5") {
    print("Did you mean: \(closest.id)?")
}
```

---

## Shared Ownership

**Critical for the ecosystem**: Any app can download a model, and all apps immediately see it.

### Example: Two Apps, One Model

**Setup**:
- App 1: SwiftBruja (LLM inference)
- App 2: SwiftVoxAlta (voice processing)
- Both in App Group: `group.intrusive-memory.models`

**Scenario**:
1. User opens SwiftBruja, downloads `mlx-community/Qwen2.5-7B-Instruct-4bit`
2. Model stored in: `<App Group Container>/SharedModels/mlx-community_Qwen2.5-7B-Instruct-4bit/`
3. User opens SwiftVoxAlta, calls `Acervo.listModels()`
4. SwiftVoxAlta sees the model immediately (same container)
5. Zero re-download

**Benefits**:
- **Disk savings**: 4.2 GB model appears once, used by two apps
- **Automatic sharing**: No explicit coordination needed
- **User experience**: Fast, seamless

---

## Storage Location by Platform

### iOS

All apps in the same App Group see the same models:

```swift
let container = FileManager.default.containerURL(
    forSecurityApplicationGroupIdentifier: "group.intrusive-memory.models"
)!
let modelsDir = container.appendingPathComponent("SharedModels")
```

**Prerequisites**:
- Signing: App must be signed with the `group.intrusive-memory.models` capability
- Provisioning profile: Must include the group

### macOS

Same as iOS (App Groups are supported):

```swift
let container = FileManager.default.containerURL(
    forSecurityApplicationGroupIdentifier: "group.intrusive-memory.models"
)!
let modelsDir = container.appendingPathComponent("SharedModels")
```

### Fallback

There isn't one. Calling `Acervo.sharedModelsDirectory` without a configured App Group identifier traps with `fatalError`. A `Application Support/SwiftAcervo/SharedModels` fallback used to exist but was removed because it caused unsigned CLI tools and signed UI apps to write to different directories — exactly the bug the App Group container exists to prevent.

If you need to read or write models from a non-app context (CLI, script, CI), set `ACERVO_APP_GROUP_ID` in the shell environment.

---

## Storage Quotas

No explicit quotas are enforced, but consider:

- **Typical model size**: 1–10 GB per model
- **Typical device storage**: 128 GB–1 TB
- **Typical iCloud backup**: Excludes App Group containers
- **iCloud Storage Optimization**: Models not synced to cloud

**Best practices**:
1. Warn users before large downloads
2. Provide a way to delete unused models
3. Check available disk space before downloading

```swift
// Check available disk space
let attributes = try FileManager.default.attributesOfFileSystem(forPath: dir.path)
let availableBytes = attributes[.systemFreeSize] as? Int64 ?? 0

if modelSizeBytes > availableBytes {
    showError("Not enough disk space. Need \(modelSizeBytes / 1024 / 1024) MB")
}
```

---

## Migration from Legacy Paths

Before SwiftAcervo, models were scattered:

```
~/Library/Caches/intrusive-memory/Models/
├── LLM/
│   └── mlx-community_Qwen2.5-7B-Instruct-4bit/
├── TTS/
│   └── mlx-community_Qwen3-TTS-12Hz-1.7B-Base-bf16/
├── Audio/
│   └── mlx-community_snac_24khz/
└── VLM/
```

**Migrate to SwiftAcervo**:

```swift
import SwiftAcervo

// At app startup
let migrated = try Acervo.migrateFromLegacyPaths()
if !migrated.isEmpty {
    print("Migrated \(migrated.count) model(s) to SharedModels")
}
```

**What happens**:
1. Scans legacy directories (LLM, TTS, Audio, VLM)
2. Finds valid models (those with `config.json`)
3. Moves to `SharedModels/{slug}/`
4. Old directories are preserved (you can delete manually)

**Idempotent**: Running migration multiple times is safe. Already-migrated models are skipped.

---

## Permissions and Sandboxing

### iOS / macOS (Sandboxed)

**Required capability**:
```
com.apple.security.application-groups
✓ group.intrusive-memory.models
```

**In Xcode**:
1. Select target
2. Signing & Capabilities
3. **+ Capability** → App Groups
4. Add: `group.intrusive-memory.models`

**Without this capability**: `Acervo.sharedModelsDirectory` traps with `fatalError`. Add the entitlement (or, for non-app contexts, export `ACERVO_APP_GROUP_ID`).

### macOS (Unsigned or Disabled Sandbox)

App Groups work without special configuration. Capability is optional.

---

## Cleaning Up Models

### Delete a Single Model

```swift
try Acervo.deleteModel("mlx-community/Qwen2.5-7B-Instruct-4bit")
```

**What it does**:
- Removes entire model directory
- Frees disk space immediately
- Safe to call (no other app actively loading model)

### List and Delete Multiple Models

```swift
let allModels = try Acervo.listModels()
for model in allModels {
    let sizeGB = Double(model.sizeBytes) / (1024 * 1024 * 1024)
    print("\(model.id): \(String(format: "%.1f", sizeGB)) GB")
}

// User selects which to delete
try Acervo.deleteModel("mlx-community/Qwen2.5-7B-Instruct-4bit")
```

### Empty Entire Directory

```swift
let dir = Acervo.sharedModelsDirectory
try FileManager.default.removeItem(at: dir)
```

**Caution**: This breaks all apps that use shared models. Only do as a last resort (cleanup during uninstall).

---

## Troubleshooting

### "App Group Container Not Accessible"

**Cause**: App is not signed with `group.intrusive-memory.models` capability.

**Fix**:
1. Select target in Xcode
2. Signing & Capabilities
3. Add App Groups capability
4. Add: `group.intrusive-memory.models`
5. Rebuild and run

### "Models Invisible Between Apps"

**Cause**: Apps are not in the same App Group.

**Verify**:
- SwiftBruja: Does it have `group.intrusive-memory.models` capability?
- SwiftVoxAlta: Does it have `group.intrusive-memory.models` capability?

If both have it, models should be shared automatically.

### "Models Disappeared"

**Possible causes**:
1. **User deleted them**: Check `Acervo.listModels()` — is the directory empty?
2. **App update removed capability**: Rebuild with App Groups capability
3. **Disk cleanup**: OS may delete inaccessible files

**Recovery**: Re-download models with `Acervo.ensureAvailable()`

### "Storage Almost Full"

**Check disk usage**:
```bash
du -sh ~/Library/Containers/group.intrusive-memory.models/
```

**Cleanup**:
```swift
let allModels = try Acervo.listModels()
for model in allModels {
    let sizeGB = Double(model.sizeBytes) / (1024 * 1024 * 1024)
    if sizeGB > 5.0 {  // Delete models > 5 GB
        try Acervo.deleteModel(model.id)
    }
}
```

---

## See Also

- **[USAGE.md](USAGE.md)** — Integration patterns
- **[API_REFERENCE.md](API_REFERENCE.md)** — Method reference
- **[README.md](README.md)** — User overview
