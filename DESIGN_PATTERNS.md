# DESIGN_PATTERNS.md — Architectural Decisions and Core Patterns

**For**: Understanding the "why" behind SwiftAcervo's design and the patterns used throughout.

---

## Static API + Actor Pattern

### Problem

Model discovery and downloading are stateless operations, but concurrent access to the same model needs serialization (to prevent two tasks from simultaneously downloading the same model). Swift concurrency (actors) is ideal for serialization, but stateless operations don't need an actor.

### Solution

Two complementary APIs:

- **`Acervo` (static enum)**: Stateless, namespace for discovery and one-liners
  - Thread-safe via Foundation's `FileManager` and `URLSession`
  - No locks, no actor overhead
  - Ideal for simple calls like `isModelAvailable()`, `listModels()`

- **`AcervoManager` (singleton actor)**: Wraps `Acervo` with per-model locking
  - Two concurrent downloads of the **same** model: serialized
  - Two concurrent downloads of **different** models: parallel
  - Exclusive access to a model during reads via `withModelAccess(_:perform:)`

**Analogy**: `Acervo` is a library catalog (anyone can read simultaneously). `AcervoManager` is a librarian who ensures two people don't check out the same book at the same time.

---

## CDN-Only Downloads

### Problem

Models are large (gigabytes to terabytes). Distributing from multiple sources (HuggingFace, GitHub, S3) introduces:
- Fragmentation (different models on different hosts)
- Inconsistent availability (one source goes down, models become inaccessible)
- Security complexity (verifying multiple endpoints)

### Solution

**All downloads come from a single private Cloudflare R2 CDN.**

- **Centralized**: One CDN endpoint for all models
- **Predictable**: Same URL structure, same verification rules
- **Secure**: Private endpoint, no public exposure
- **Fast**: CDN edge caching closer to end users

Models are uploaded to R2 once (via `acervo ship`), then downloaded millions of times via SwiftAcervo.

---

## Per-File Manifest Verification

### Problem

Large file downloads (100 MB+) can fail partway through:
- Network interruptions
- Disk corruption
- Malicious tampering

How do we know if a downloaded file is complete and unmodified?

### Solution

Every model comes with a `manifest.json` listing all files plus SHA-256 checksums:

```json
{
  "files": [
    {"path": "config.json", "sha256": "abc...", "sizeBytes": 1234},
    {"path": "model.safetensors", "sha256": "def...", "sizeBytes": 4567890123}
  ],
  "manifestChecksum": "ghi..."  // SHA-256-of-checksums
}
```

**Verification steps**:
1. Download manifest from CDN
2. Verify manifest itself (SHA-256-of-checksums matches)
3. For each file: verify file size and SHA-256 against manifest
4. If all checks pass, files are safe to use

**Double verification**: The manifest is also verified (via manifest checksum) to prevent tampering with the manifest itself.

---

## Streaming SHA-256

### Problem

Large models (100 GB+) can't be loaded entirely into memory for verification. Computing a single SHA-256 hash requires loading the entire file.

### Solution

**Incremental, streaming verification**:

1. Download file in 4 MB chunks
2. Hash each chunk incrementally with CryptoKit
3. Accumulate bytes downloaded
4. After last chunk, compare final hash against manifest

**Memory overhead**: Constant (just the hash state), not proportional to file size.

**Performance**: Hashing happens during download (zero extra I/O pass).

---

## Concurrent File Downloads

### Problem

Models often have multiple files (config.json, model.safetensors, tokenizer.json, ...). Downloading sequentially is slow.

### Solution

**Download multiple files concurrently via TaskGroup**:

```swift
try await withThrowingTaskGroup(of: Void.self) { group in
    for file in requestedFiles {
        group.addTask { try await downloadFile(file) }
    }
    try await group.waitForAll()
}
```

**Guarantees**:
- All files must complete successfully (all or nothing)
- Progress is cumulative (one global 0.0–1.0, not per-file)
- If one fails, others are cancelled

**Per-model serialization** (via `AcervoManager`) ensures concurrent downloads of the **same** model don't race.

---

## Per-Model Locking

### Problem

If two tasks simultaneously download the same model:
- Both download the same files twice (wasted bandwidth)
- Downloaded files might collide (one might overwrite the other mid-operation)
- Manifest might be fetched twice

### Solution

**`AcervoManager` maintains one lock per model ID**:

```swift
let locks: [String: NSLock] = [:]  // One lock per model

func download(modelId: String) async {
    async let _ = locks[modelId].lock()
    defer { locks[modelId].unlock() }
    
    // Two concurrent calls for same modelId: second waits for first
    // Two concurrent calls for different modelIds: both proceed in parallel
}
```

**Tradeoff**: Small latency cost (locking) for consistency and efficiency.

---

## Atomic Downloads

### Problem

If a download is interrupted partway through:
- Partial files remain on disk
- Future discovery scans find incomplete models
- Model appears "valid" (has `config.json`) but is actually broken

### Solution

**Three-phase atomic operation**:

1. **Download**: Write to temporary directory (e.g., `/tmp/acervo_xyz/`)
2. **Verify**: All files pass SHA-256 checks
3. **Move**: Atomic rename of temp directory to final destination

If any step fails, the temp directory is cleaned up. Final destination is never touched.

**Filesystem guarantee**: The move is atomic (on POSIX systems, `rename()` is atomic).

---

## config.json as Validity Marker

### Problem

How do we distinguish a valid model from a directory that happens to exist?

Some model types:
- LLMs: Have config.json + model.safetensors
- TTS: Have config.json + multiple subdirectories
- Vision: Have config.json + image encoders

No single universal file structure.

### Solution

**Every valid model must have `config.json`, regardless of type.**

```swift
func isModelAvailable(_ modelId: String) -> Bool {
    let configPath = modelDirectory(for: modelId).appendingPathComponent("config.json")
    return FileManager.default.fileExists(atPath: configPath.path)
}
```

**Universal across all types**: LLMs, TTS, vision, audio — all check the same marker.

**Rationale**: `config.json` is standard in HuggingFace models. If a model doesn't have it, it's likely not a valid ML model.

---

## Zero External Dependencies

### Problem

Every external dependency:
- Adds compile time
- Increases bundle size
- Introduces security vulnerabilities
- Creates maintenance burden (updating transitive deps)

### Solution

**SwiftAcervo uses only Foundation and CryptoKit (system frameworks).**

- `Foundation`: FileManager, URLSession, JSON decoding
- `CryptoKit`: SHA-256 hashing

**Benefits**:
- Tiny bundle size
- Fast compilation
- Zero transitive dependency updates
- Can be vendored without external registry

**Tradeoff**: No external model hub libraries (HuggingFace SDK, etc.), but that's intentional — SwiftAcervo is a download layer, not a model hub client.

---

## Strict Concurrency (Swift 6)

### Problem

Concurrent code without type safety leads to data races:
- Two tasks modify the same model directory simultaneously
- Progress callback is called from multiple threads
- Closure captures are not guaranteed to be thread-safe

### Solution

**Swift 6 strict concurrency mode enforces safety**:

- All closures are `@Sendable` (can be safely sent across task boundaries)
- `AcervoManager` is an actor (protects shared state)
- Progress callbacks are `@Sendable` (safe to call from any thread)
- `AcervoDownloadProgress` conforms to `Sendable` (safe to capture)

**Compiler catches data races at compile time**, not runtime.

---

## Redirect Rejection (SecureDownloadSession)

### Problem

URLSession by default follows redirects:

```swift
// Attacker redirects download from:
// https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/xyz/model.safetensors
// To:
// https://attacker.com/malicious-model.safetensors
```

Consumer unwittingly downloads from untrusted source.

### Solution

**`SecureDownloadSession` wraps URLSession and rejects redirects**:

```swift
func urlSession(_ session: URLSession, 
                willPerformHTTPRedirection response: HTTPURLResponse,
                newRequest: URLRequest) async -> URLRequest? {
    // Only allow redirects within CDN domain
    guard let host = newRequest.url?.host,
          host.contains("pub-8e049ed02be340cbb18f921765fd24f3.r2.dev") else {
        throw AcervoError.redirectRejected
    }
    return newRequest
}
```

**Assumption**: The CDN is trusted. If a model is on the CDN, it's legitimate.

---

## Local Path Access (withLocalAccess)

### Problem

Consuming libraries sometimes need to access user-supplied files (LoRA adapters, fine-tuned weights) that SwiftAcervo didn't download.

Challenges:
- File might not exist
- File might be a directory (need to traverse)
- Path safety (no escaping the directory)

### Solution

**`withLocalAccess(_:perform:)` wraps local URLs**:

```swift
let handle = try await AcervoManager.shared.withLocalAccess(userLoRAURL) { handle in
    // Safe to access files within handle
    let weights = try handle.url(matching: ".safetensors")
    return try Data(contentsOf: weights)
}
```

**Benefits**:
- Validates path exists before access
- Provides `LocalHandle` for safe file resolution
- Scoped access (handle is invalid after closure)
- Same API as `ComponentHandle` (consistency)

---

## Component Registry

### Problem

Different model plugins need to register what they provide:
- pixart-swift-mlx: Registers encoder, backbone, VAE decoder
- SwiftVoxAlta: Registers TTS models
- mlx-audio-swift: Registers vocoder

How do we:
1. Avoid duplication (same model registered twice)?
2. Coordinate across plugins (who registered what)?
3. Support dynamic discovery (list all components)?

### Solution

**Global component registry in `ComponentRegistry`**:

```swift
// In pixart-swift-mlx at import time
Acervo.register([
    ComponentDescriptor(id: "t5-encoder", type: .encoder, ...),
    ComponentDescriptor(id: "dit-backbone", type: .backbone, ...)
])

// In SwiftVoxAlta at import time
Acervo.register([
    ComponentDescriptor(id: "qwen3-tts", type: .languageModel, ...)
])

// Later: discover what exists
let components = Acervo.registeredComponents()
```

**Deduplication**: Same ID + repo + files = silent no-op. Same ID + different repo = warning + last-one-wins.

**Consistency**: All plugins follow the same registration pattern.

---

## Why These Patterns?

| Pattern | Solves |
|---------|--------|
| Static + Actor | Simplicity + concurrency safety |
| CDN-only | Centralization + security |
| Per-file verification | Integrity + tamper detection |
| Streaming SHA-256 | Memory efficiency + performance |
| Concurrent downloads | Speed |
| Per-model locking | Consistency + efficiency |
| Atomic operations | Partial failure safety |
| config.json marker | Universal validity across model types |
| Zero dependencies | Bundle size + maintainability |
| Strict concurrency | Compile-time data race detection |
| Redirect rejection | Man-in-the-middle protection |
| Local path access | LoRA / user-supplied weights support |
| Component registry | Plugin coordination + discovery |

---

## See Also

- **[CDN_ARCHITECTURE.md](CDN_ARCHITECTURE.md)** — Technical details of downloads
- **[API_REFERENCE.md](API_REFERENCE.md)** — Method signatures
- **[USAGE.md](USAGE.md)** — Integration examples
