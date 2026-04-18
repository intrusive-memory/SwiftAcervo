# CDN_ARCHITECTURE.md — How CDN Downloads Work

**For**: Understanding the security model, integrity verification, and technical details of how SwiftAcervo downloads models.

---

## Overview

All SwiftAcervo downloads come exclusively from a private Cloudflare R2 CDN. Every file is verified with per-file SHA-256 checksums before being moved to the destination directory. Redirects to non-CDN domains are rejected.

**CDN Base URL**: `https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/`

---

## Download Flow (7 Steps)

When you call `Acervo.ensureAvailable(modelId, files: [...])`, this happens internally:

### Step 1: Fetch Manifest from CDN

```
GET https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/{slug}/manifest.json
```

The manifest is a JSON file describing all files available for the model:

```json
{
  "manifestVersion": 1,
  "modelId": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "slug": "mlx-community_Qwen2.5-7B-Instruct-4bit",
  "updatedAt": "2026-03-22T00:00:00Z",
  "files": [
    {"path": "config.json", "sha256": "abc123...", "sizeBytes": 1234},
    {"path": "model.safetensors", "sha256": "def456...", "sizeBytes": 4567890123}
  ],
  "manifestChecksum": "sha256-of-sorted-concatenated-file-checksums"
}
```

### Step 2: Validate Manifest Version

Verify `manifestVersion == 1` (current format). Future versions will be supported with migration logic.

### Step 3: Validate Manifest Integrity

Compute SHA-256-of-checksums:
1. Sort files by path
2. Concatenate all file checksums in order
3. Compute SHA-256 of that concatenation
4. Compare against `manifestChecksum`

If mismatch → throw `AcervoError.manifestChecksumMismatch`

**Why?** Ensures the manifest itself hasn't been tampered with or corrupted during transmission.

### Step 4: Verify Requested Files Exist in Manifest

For each requested file (e.g., `config.json`, `model.safetensors`):
- Check that file is listed in manifest
- Throw `AcervoError.fileNotInManifest` if not

**Why?** Fail fast if the consumer requests a file the model doesn't have.

### Step 5: Download Each File via SecureDownloadSession

For each requested file:

```
GET https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/{slug}/{fileName}
```

**SecureDownloadSession** (custom URLSession wrapper):
- Accepts 200 OK responses
- **Rejects redirects to any domain except the CDN**
- Streams response body in 4MB chunks

**Why reject redirects?** Prevents attacker-in-the-middle from redirecting downloads to a malicious server.

### Step 6: Verify File Size and SHA-256

As the file streams:
- Accumulate bytes downloaded
- Incrementally compute SHA-256 hash via CryptoKit
- Compare final file size against manifest `sizeBytes`
- Compare final SHA-256 against manifest `sha256`

If mismatch → throw `AcervoError.checksumMismatch` or `AcervoError.downloadSizeMismatch`

**Streaming verification**: Reads in 4MB chunks, hashes incrementally. No need to load entire file into memory.

### Step 7: Move to Destination Atomically

Once all verifications pass:
1. Download to temporary location (e.g., `/tmp/acervo_download_xyz/`)
2. All files verified
3. Move entire temporary directory to final destination (atomic filesystem operation)

**Why atomic?** Ensures a partially-downloaded model never appears valid (no partial `config.json` on disk).

---

## Manifest Format

```json
{
  "manifestVersion": 1,
  "modelId": "org/repo",
  "slug": "org_repo",
  "updatedAt": "2026-03-22T00:00:00Z",
  "files": [
    {
      "path": "config.json",
      "sha256": "abcd1234...",
      "sizeBytes": 1234
    },
    {
      "path": "model.safetensors",
      "sha256": "efgh5678...",
      "sizeBytes": 4567890123
    },
    {
      "path": "tokenizer.json",
      "sha256": "ijkl9012...",
      "sizeBytes": 567890
    }
  ],
  "manifestChecksum": "mnop3456..."
}
```

**Manifest Checksum Computation**:

```
1. Sort files by path: ["config.json", "model.safetensors", "tokenizer.json"]
2. Concatenate checksums: "abcd1234...efgh5678...ijkl9012..."
3. SHA-256 hash: "mnop3456..."
```

---

## URL Structure

```
{cdnBase}/{slug}/{fileName}

Example:
https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/mlx-community_Qwen2.5-7B-Instruct-4bit/model.safetensors
```

- `{cdnBase}` = `https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/`
- `{slug}` = Model ID with `/` replaced by `_` (e.g., `mlx-community_Qwen2.5-7B-Instruct-4bit`)
- `{fileName}` = File path from manifest (e.g., `model.safetensors`, `speech_tokenizer/config.json`)

**Nested paths** work:
- File: `speech_tokenizer/config.json`
- URL: `https://.../mlx-community_Qwen3-TTS-12Hz-1.7B-Base-bf16/speech_tokenizer/config.json`

---

## Security Properties

### Integrity
- **Per-file SHA-256**: Every file independently verified
- **Manifest integrity**: Manifest checksums can't be modified without detection
- **Atomic downloads**: Partial files never become valid

### Authenticity
- **CDN-only downloads**: Private R2 with restricted access
- **Redirect rejection**: SecureDownloadSession blocks redirects
- **HTTPS required**: All communications encrypted in transit

### Non-repudiation
- **Manifest as audit trail**: `updatedAt` timestamp on manifest
- **Per-file checksums**: Reproducible from manifest

---

## Concurrent Downloads

When downloading multiple files for the same model:

```swift
try await Acervo.ensureAvailable(modelId, files: [
    "config.json",
    "model.safetensors",
    "tokenizer.json"
])
```

1. Manifest fetched and verified (once)
2. Files downloaded **concurrently** via `TaskGroup`
3. Each file's SHA-256 verified **independently**
4. All files must complete successfully before move
5. If one fails, entire download fails (all or nothing)

**Progress tracking**: Combined progress from 0.0 to 1.0 across all files.

---

## Retry Logic

The download client (SwiftAcervo) does not implement automatic retries. Transient failures (network timeout, 503 Service Unavailable) are thrown immediately.

**Best practice for consumers**:
```swift
var attempts = 0
while attempts < 3 {
    do {
        try await Acervo.ensureAvailable(modelId, files: files)
        break  // Success
    } catch let error as AcervoError {
        attempts += 1
        if attempts >= 3 {
            throw error
        }
        try await Task.sleep(nanoseconds: 5_000_000_000)  // 5 second backoff
    }
}
```

---

## Bandwidth and Quotas

The CDN has **no advertised per-download quotas or rate limits** for SwiftAcervo users. However:

- Large downloads (models > 100 GB) should be tested in CI before production
- Concurrent downloads of the same model are serialized (per-model locking via `AcervoManager`)
- Different models download in parallel

---

## What's NOT Verified

- **File paths**: Downloaded files are not sandboxed. Any path in the manifest will be downloaded.
- **Timestamp authenticity**: `updatedAt` is informational only, not signed.
- **Model owner identity**: No verification that `mlx-community/Qwen...` actually came from mlx-community.

These are acceptable tradeoffs for a semi-trusted CDN within the intrusive-memory ecosystem.

---

## Troubleshooting

### Download Fails: "Redirect rejected"

**Cause**: SecureDownloadSession blocked a redirect to a non-CDN domain.

**Check**: The model URL may have been tampered with. Verify the file is in the manifest and the CDN endpoint is correct.

### Download Fails: "Checksum mismatch"

**Cause**: File was corrupted during download or tampered with.

**Action**: Delete local partial files and retry. SwiftAcervo should resume automatically.

### Download Fails: "File not in manifest"

**Cause**: You requested a file that the model doesn't have.

**Check**: Call `Acervo.modelInfo(modelId)` to list available files:
```swift
let model = try Acervo.modelInfo(modelId)
for file in model.files {
    print(file.path)
}
```

### Manifest Download Fails: "404"

**Cause**: Model slug doesn't exist on CDN or manifest was deleted.

**Check**: Verify model ID is correct and has been uploaded to R2.

---

## See Also

- **[CDN_UPLOAD.md](CDN_UPLOAD.md)** — How to upload models to the CDN
- **[API_REFERENCE.md](API_REFERENCE.md)** — Download methods and error types
- **[USAGE.md](USAGE.md)** — Integration examples
