# SwiftAcervo — Architecture (Ecosystem Interface Reference)

**Companion to**: [`REQUIREMENTS.md`](REQUIREMENTS.md)
**Role in ecosystem**: Leaf dependency. Zero external dependencies. Every other package depends on Acervo.

---

## Dependency Position

```
pixart-swift-mlx ──▶ SwiftTubería ──▶ SwiftAcervo
SwiftVinetas ──────▶ SwiftTubería ──▶ SwiftAcervo
SwiftVoxAlta ──────▶ SwiftTubería ──▶ SwiftAcervo
pixart-swift-mlx ──────────────────▶ SwiftAcervo  (direct, for registration)
SwiftVoxAlta ──────────────────────▶ SwiftAcervo  (direct, for registration)
```

Acervo depends on **nothing**. Foundation only.

---

## Exported Types (Consumed by Other Packages)

### Core Registry Types

| Type | Consumed By | Purpose |
|---|---|---|
| `ComponentDescriptor` | pixart-swift-mlx, SwiftVoxAlta, TuberíaCatalog | Declare downloadable components |
| `ComponentType` | pixart-swift-mlx, SwiftVoxAlta, TuberíaCatalog | Classify components (.encoder, .backbone, .decoder, .languageModel, etc.) |
| `ComponentFile` | pixart-swift-mlx, SwiftVoxAlta, TuberíaCatalog | Declare individual files within a component |
| `ComponentHandle` | SwiftTubería (WeightLoader) | Scoped file access during weight loading |

### Static API (on `Acervo`)

| Method | Primary Consumer | Purpose |
|---|---|---|
| `register(_:)` / `register([_])` | Model plugins at import time | Declare components |
| `registeredComponents()` | UI layers, CLI tools | "What exists?" |
| `isComponentReady(_:)` | SwiftTubería, SwiftVinetas | "Is it downloaded?" |
| `ensureComponentReady(_:)` | SwiftTubería (loadModels) | Download if needed |
| `ensureComponentsReady([_])` | SwiftTubería (recipe download) | Batch download |
| `downloadComponent(_:)` | CLI tools | Explicit download |
| `component(_:)` | SwiftVoxAlta | Look up descriptor by ID |
| `deleteComponent(_:)` | UI layers | Remove cached files |

### Actor API (on `AcervoManager.shared`)

| Method | Primary Consumer | Purpose |
|---|---|---|
| `withComponentAccess(_:perform:)` | SwiftTubería WeightLoader | Scoped file access for weight loading |
| `withModelAccess(_:perform:)` | Legacy consumers (v1 API) | Backward-compatible path access |

---

## Interface Contracts

### ComponentDescriptor (authored by model plugins)

```swift
ComponentDescriptor(
    id: String,                    // Globally unique: "pixart-sigma-xl-dit-int4"
    type: ComponentType,           // .encoder, .backbone, .decoder, .languageModel, etc.
    displayName: String,           // Human-readable
    huggingFaceRepo: String,       // "intrusive-memory/pixart-sigma-xl-dit-int4-mlx"
    files: [ComponentFile],        // Required files with optional checksums
    estimatedSizeBytes: Int64,     // Advisory download size
    minimumMemoryBytes: Int64,     // RAM needed to load (used by MemoryManager)
    metadata: [String: String]     // "quantization": "int4", "deprecated": "true", etc.
)
```

### ComponentHandle (consumed by WeightLoader)

```swift
handle.url(for: "model.safetensors")    → URL     // Single file by relative path
handle.url(matching: ".safetensors")    → URL     // First file matching suffix
handle.urls(matching: ".safetensors")   → [URL]   // All files matching suffix (sharded)
handle.availableFiles()                 → [String] // List all files
```

URLs valid **only** within `withComponentAccess` closure scope.

### Registration Pattern (used by all model plugins)

```swift
public enum MyComponents {
    public static let registered: Bool = {
        Acervo.register([
            ComponentDescriptor(id: "my-component-id", ...)
        ])
        return true
    }()
}
// Defensive trigger at pipeline assembly: _ = MyComponents.registered
```

### Deduplication Rules

- Same `id` + same `huggingFaceRepo` + same `files` → silent no-op
- Same `id` + different repo/files → warning logged, last registration wins
- `metadata` merged (newer overwrites on conflict)
- `estimatedSizeBytes` / `minimumMemoryBytes` → max of both values

---

## Error Types (new in v2)

```swift
case componentNotRegistered(String)
case componentNotDownloaded(String)
case integrityCheckFailed(file: String, expected: String, actual: String)
case componentFileNotFound(component: String, file: String)
```

---

## Storage Layout

```
~/Library/SharedModels/
├── intrusive-memory_t5-xxl-int4-mlx/          # Shared encoder
│   ├── config.json                             # Validity marker
│   ├── model.safetensors
│   ├── tokenizer.json
│   └── tokenizer_config.json
├── intrusive-memory_pixart-sigma-xl-dit-int4-mlx/  # PixArt backbone
├── intrusive-memory_sdxl-vae-fp16-mlx/         # Shared VAE
└── intrusive-memory_Qwen3-TTS-1.7B-mlx/        # VoxAlta TTS
```

Slugification: `org/repo` → `org_repo`. All paths managed by Acervo — consumers never construct these.

---

## Registered Components (Ecosystem-Wide)

| Acervo ID | Type | Registered By | Size |
|---|---|---|---|
| `t5-xxl-encoder-int4` | .encoder | TuberíaCatalog + pixart-swift-mlx | ~1.2 GB |
| `sdxl-vae-decoder-fp16` | .decoder | TuberíaCatalog + pixart-swift-mlx | ~160 MB |
| `pixart-sigma-xl-dit-int4` | .backbone | pixart-swift-mlx | ~300 MB |
| `qwen3-tts-base-1.7b` | .languageModel | SwiftVoxAlta | ~3.4 GB |
| `qwen3-tts-base-0.6b` | .languageModel | SwiftVoxAlta | ~1.2 GB |
| `qwen3-tts-custom-1.7b` | .languageModel | SwiftVoxAlta | ~3.4 GB |
| `qwen3-tts-custom-0.6b` | .languageModel | SwiftVoxAlta | ~1.2 GB |
| `qwen3-tts-voicedesign-1.7b` | .languageModel | SwiftVoxAlta | ~3.4 GB |
| `qwen3-tts-base-1.7b-8bit` | .languageModel | SwiftVoxAlta | ~1.7 GB |
