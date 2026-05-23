# CDN_UPLOAD.md — Uploading Models to the CDN

**For**: Release engineers and maintainers uploading new models to the R2 CDN.

---

## Architecture Overview

The upload surface is layered:

- **Library API** (`Acervo.publishModel`, `Acervo.deleteFromCDN`, `Acervo.recache`) — the
  authoritative surface. All CDN mutation logic lives here. The library drives S3 traffic
  directly via native SigV4 signing; no external tools are required.
- **`acervo` CLI** (`ship`, `upload`, `delete`, `recache`) — a thin wrapper. Each command
  resolves credentials from environment variables, invokes the corresponding library method,
  and maps `AcervoPublishProgress` / `AcervoDeleteProgress` events back to the familiar
  `CHECK N passed` output lines.

There is no `aws` CLI in the path. Credentials are consumed directly by the library via
`AcervoCDNCredentials`.

---

## Quick Start

```bash
# Set credentials (no aws configure needed)
export HF_TOKEN="hf_..."
export R2_ACCESS_KEY_ID="..."
export R2_SECRET_ACCESS_KEY="..."
export R2_ENDPOINT="https://<accountid>.r2.cloudflarestorage.com"
export R2_PUBLIC_URL="https://pub-<id>.r2.dev"

# Full pipeline: download from HuggingFace → generate manifest → verify → upload to CDN
acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit

# Done! Model is now available on CDN.
```

---

## Prerequisites

### Required Tools

Only one external CLI is needed:

```bash
brew install huggingface-hub
```

The `hf` tool is used by `acervo ship` and `acervo download` to fetch model files from
HuggingFace. CDN uploads use the library's native SigV4 client — no `aws` CLI required.

### Required Credentials

Set these environment variables:

```bash
export HF_TOKEN="hf_..."                          # HuggingFace API token (ship/download only)
export R2_ACCESS_KEY_ID="..."                     # Cloudflare R2 access key ID
export R2_SECRET_ACCESS_KEY="..."                 # Cloudflare R2 secret access key
export R2_ENDPOINT="https://..."                  # S3-compatible endpoint URL
export R2_PUBLIC_URL="https://pub-..."            # Public CDN base URL (CHECK 5/6 reads)
```

### Optional Configuration

```bash
export R2_BUCKET="intrusive-memory-models"       # (default: "intrusive-memory-models")
export R2_REGION="auto"                          # (default: "auto" for Cloudflare R2)
export STAGING_DIR="/path/to/staging"            # (default: /tmp/acervo-staging)
```

---

## Full Pipeline: acervo ship

**One command does everything:**

```bash
acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit
```

**Download phase (CHECKs 0–1)**:
1. Shells out to `hf download` into the staging directory.
2. CHECK 0: Verifies every file HF advertises is present at the expected size.
3. CHECK 1: Verifies each file's SHA-256 against the HuggingFace LFS API.

**Upload phase (CHECKs 2–6 + orphan prune)**:
All CDN-side work is delegated to `Acervo.publishModel(...)`:
- CHECK 2: Refuses manifest generation if any staged file is zero bytes.
- CHECK 3: Re-reads and verifies the manifest checksum after writing.
- CHECK 4: Re-hashes every staged file against the manifest before uploading.
- PUTs every file to the CDN; manifest.json is PUT LAST.
- CHECK 5: Fetches manifest.json from the public CDN URL and verifies its checksum.
- CHECK 6: Downloads config.json (or the first manifest entry) and verifies its SHA-256.
- Orphan prune: deletes CDN keys not referenced by the new manifest (see below).

**Key flags**:

```
--no-verify          Skip HuggingFace LFS SHA-256 verification (CHECK 1)
--dry-run            Generate and verify the manifest, then print a
                     "would upload N files (X bytes total)" summary without
                     contacting the CDN
--keep-orphans       Skip the orphan-prune step (see Orphan Prune section below)
--output PATH        Override staging directory root
--token TEXT         HuggingFace token (falls back to $HF_TOKEN)
--bucket TEXT        R2 bucket name (falls back to $R2_BUCKET)
--endpoint URL       R2 endpoint (falls back to $R2_ENDPOINT)
```

---

## Upload Only: acervo upload

If you already have model files staged locally (e.g. from a prior `acervo download`),
skip the HF download phase:

```bash
acervo upload mlx-community/Qwen2.5-7B-Instruct-4bit /tmp/acervo-staging/mlx-community_Qwen2.5-7B-Instruct-4bit
```

This runs CHECKs 2–6 and the orphan prune identically to the upload phase of `ship`.

---

## Orphan Prune (default) and `--keep-orphans`

**Default behavior**: After a successful publish (CHECKs 5 and 6 pass), `acervo ship` and
`acervo upload` delete any CDN keys under `models/<slug>/` that are not referenced by the
new manifest. This is the "manifest-truth" model: the CDN exactly reflects the new manifest,
with no leftover files from prior versions.

**`--keep-orphans`**: Pass this flag to skip the prune step and preserve the previous
additive-only behavior. CDN keys not in the new manifest are left untouched.

```bash
# Prune orphans (default — recommended for production)
acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit

# Preserve orphans from prior versions
acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit --keep-orphans
acervo upload mlx-community/Qwen2.5-7B-Instruct-4bit /tmp/staging --keep-orphans
```

> **Operator upgrade note**: Prior versions of `acervo ship` and `acervo upload` used an
> additive-only upload strategy — existing CDN keys were never deleted. If you have scripts
> that relied on this behavior (e.g. to preserve a previous model version's files alongside
> a new upload), add `--keep-orphans` to preserve it. The default changed in v0.14.x.

---

## Programmatic API (CI Scripts)

You can call `Acervo.publishModel(...)` directly from Swift without going through the CLI.
This is useful in CI scripts that already operate in Swift, or in test harnesses that need
to publish models programmatically.

```swift
import SwiftAcervo

let credentials = AcervoCDNCredentials(
    accessKeyId: ProcessInfo.processInfo.environment["R2_ACCESS_KEY_ID"]!,
    secretAccessKey: ProcessInfo.processInfo.environment["R2_SECRET_ACCESS_KEY"]!,
    region: "auto",                  // default for Cloudflare R2
    bucket: "intrusive-memory-models",
    endpoint: URL(string: ProcessInfo.processInfo.environment["R2_ENDPOINT"]!)!,
    publicBaseURL: URL(string: ProcessInfo.processInfo.environment["R2_PUBLIC_URL"]!)!
)

let stagingDir = URL(fileURLWithPath: "/tmp/acervo-staging/mlx-community_Qwen2.5-7B-Instruct-4bit")

// Publish with orphan prune (default)
let manifest = try await Acervo.publishModel(
    modelId: "mlx-community/Qwen2.5-7B-Instruct-4bit",
    directory: stagingDir,
    credentials: credentials,
    keepOrphans: false           // prune by default
) { event in
    switch event {
    case .generatingManifest:
        print("Generating manifest...")
    case .uploadingFile(let name, let bytesSent, let bytesTotal):
        print("Uploading \(name): \(bytesSent)/\(bytesTotal) bytes")
    case .complete:
        print("Publish complete.")
    default:
        break
    }
}
print("Published \(manifest.files.count) files.")
```

For a full re-fetch + publish pipeline (equivalent to `acervo ship` but caller-supplied
fetch closure), use `Acervo.recache(...)`:

```swift
let manifest = try await Acervo.recache(
    modelId: "mlx-community/Qwen2.5-7B-Instruct-4bit",
    stagingDirectory: stagingDir,
    credentials: credentials,
    fetchSource: { modelId, into in
        // populate `into` with the model files however you like
    },
    keepOrphans: false
)
```

---

## Delete from CDN

```bash
acervo delete mlx-community/Qwen2.5-7B-Instruct-4bit
```

Or via the API:

```swift
try await Acervo.deleteFromCDN(
    modelId: "mlx-community/Qwen2.5-7B-Instruct-4bit",
    credentials: credentials
) { event in
    switch event {
    case .deletingBatch(let count, let deletedSoFar):
        print("Deleted \(count) keys (\(deletedSoFar) total so far)")
    case .complete:
        print("Delete complete.")
    default:
        break
    }
}
```

Delete is idempotent: if the prefix is already empty, the call returns without issuing
any `DeleteObjects` requests.

---

## Troubleshooting

### "Required tool not found on PATH: hf"

```bash
brew install huggingface-hub
```

`hf` is the only external tool required. CDN uploads use the native SigV4 path; no
`aws` CLI is needed.

### "HF_TOKEN not set" or "Authentication failed"

```bash
# Check if token is set
test -n "$HF_TOKEN" && echo "set" || echo "not set"

# Login to HuggingFace
hf login
```

### "R2_ACCESS_KEY_ID not set" or "Access denied"

```bash
# Check if credentials are set
test -n "$R2_ACCESS_KEY_ID" && echo "set" || echo "not set"
test -n "$R2_SECRET_ACCESS_KEY" && echo "set" || echo "not set"
```

Get credentials from the Cloudflare dashboard under R2 → API Tokens. Ensure the token
has `Object:Write` permission on the target bucket.

### "Upload failed: 403 Forbidden"

Check that:
1. R2 bucket exists and is correct (`$R2_BUCKET`)
2. API token has `Object:Write` permission
3. `$R2_ENDPOINT` URL is correct (format: `https://<accountid>.r2.cloudflarestorage.com`)

### "Manifest checksum mismatch"

The staging directory may contain a stale or corrupted manifest. Delete it and retry:

```bash
rm /tmp/acervo-staging/mlx-community_Qwen2.5-7B-Instruct-4bit/manifest.json
acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit
```

### "Downloaded file is incomplete" / CHECK 0 failure

The HF download may have been interrupted or Xet support was not enabled. Retry:

```bash
acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit
# hf download will resume from where it left off
```

---

## Staging Directory

By default, `ship` stages files under `/tmp/acervo-staging/<slug>/`:

```
/tmp/acervo-staging/
└── mlx-community_Qwen2.5-7B-Instruct-4bit/
    ├── config.json
    ├── model.safetensors
    ├── tokenizer.json
    ├── tokenizer_config.json
    └── manifest.json
```

Override with `--output PATH` or `$STAGING_DIR`.

**Cleanup**: Staging directory is NOT automatically deleted. Delete after a successful upload:

```bash
rm -rf /tmp/acervo-staging/mlx-community_Qwen2.5-7B-Instruct-4bit/
```

---

## Manifest Format

```json
{
  "manifestVersion": 1,
  "modelId": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "slug": "mlx-community_Qwen2.5-7B-Instruct-4bit",
  "updatedAt": "2026-04-18T10:30:00Z",
  "files": [
    {
      "path": "config.json",
      "sha256": "abcd1234....",
      "sizeBytes": 1234
    },
    {
      "path": "model.safetensors",
      "sha256": "efgh5678....",
      "sizeBytes": 4567890123
    }
  ],
  "manifestChecksum": "qrst7890...."
}
```

The manifest is:
- Authoritative for consuming apps: they download only what the manifest lists.
- Uploaded LAST in the publish pipeline so CDN never serves an internally inconsistent view.
- Verified on the CDN after upload (CHECK 5).
- Not user-editable — auto-generated and verified by `ManifestGenerator`.

---

## See Also

- **[CDN_ARCHITECTURE.md](CDN_ARCHITECTURE.md)** — How downloads work
- **[BUILD_AND_TEST.md](BUILD_AND_TEST.md)** — Running acervo commands
- **[API_REFERENCE.md](API_REFERENCE.md)** — Full `publishModel` / `deleteFromCDN` / `recache` reference
- **[USAGE.md](USAGE.md)** — Integration guide for consuming libraries
