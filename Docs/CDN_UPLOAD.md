# CDN_UPLOAD.md — Uploading Models to the CDN

**For**: Release engineers and maintainers uploading new models to the R2 CDN.

---

## Quick Start

```bash
# Set credentials
export HF_TOKEN="hf_..."
export R2_ACCESS_KEY_ID="..."
export R2_SECRET_ACCESS_KEY="..."

# Full pipeline: download from HuggingFace → generate manifest → verify → upload to R2
acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit

# Done! Model is now available on CDN.

# Dry-run first (no credentials needed) to verify manifest shape:
acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit --dry-run --output-dir /tmp/manifests
```

---

## Prerequisites

### Required Tools

Install from Homebrew:

```bash
brew install awscli huggingface-hub
```

### Required Credentials

Set these environment variables:

```bash
export HF_TOKEN="hf_..."                          # HuggingFace API token
export R2_ACCESS_KEY_ID="..."                     # Cloudflare R2 access key ID
export R2_SECRET_ACCESS_KEY="..."                 # Cloudflare R2 secret access key
```

### Optional Configuration

```bash
export R2_BUCKET="models"                         # (default: "models")
export R2_ENDPOINT="https://..."                  # (default: intrusive-memory R2)
export R2_PUBLIC_URL="https://pub-..."           # (default: intrusive-memory CDN)
export STAGING_DIR="/path/to/staging"            # (default: ./models/staging)
```

---

## Full Pipeline: acervo ship

**One command does everything:**

```bash
acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit
```

**Steps**:
1. **Download** from HuggingFace LFS
2. **Generate manifest** with SHA-256 checksums
3. **Verify integrity** (all 6 checks)
4. **Upload** to R2 CDN
5. **Verify uploaded files** match manifest

**Options**:
```
<modelId>                  HuggingFace model ID in org/repo format (required
                           unless --spec is used)
--slug <slug>              Override manifest modelId with this slug. The
                           uploaded manifest will have modelId=<slug>,
                           primaryRepo=<modelId>, components=[<modelId>].
--spec <path>              Path to a multi-component spec JSON (see below).
--dry-run                  Generate manifests and write to --output-dir;
                           skip R2 upload. No credentials required.
--output-dir <path>        Where to write manifests in dry-run mode
                           (default: a unique tempdir, path printed on stdout).
--output <path>            Override staging directory root.
```

**Example — single component**:
```bash
acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit
```

**Example — single component with explicit slug**:
```bash
# Uploaded manifest will have:
#   modelId: "qwen-7b-4bit"
#   primaryRepo: "mlx-community/Qwen2.5-7B-Instruct-4bit"
#   components: ["mlx-community/Qwen2.5-7B-Instruct-4bit"]
acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit --slug qwen-7b-4bit
```

---

## Multi-Component Models: `--spec`

For models that consist of multiple HuggingFace repos (e.g. Flux2 Klein 4B with
transformer + VAE + text-encoder), create a spec JSON file and pass it via `--spec`.

### Spec File Format

```json
{
  "modelId": "flux2-klein-4b",
  "primaryRepo": "black-forest-labs/FLUX.2-klein-4B",
  "components": [
    "black-forest-labs/FLUX.2-klein-4B",
    "black-forest-labs/FLUX.2-vae",
    "google/t5-v1_1-xxl"
  ]
}
```

**Fields**:
- `modelId` — The shared slug-level identifier written into every component manifest.
  Consumers use this to address the model (e.g. `Acervo.availability("flux2-klein-4b")`).
- `primaryRepo` — The slug-level canonical "main" HF repo. Every component manifest
  carries the **same** `primaryRepo` value (not each component's own repo). This is
  how consumers fan out across components under one logical slug.
- `components` — All HF repos belonging to this slug. One manifest is generated and
  uploaded per entry.

**Invariant**: Every component manifest carries the same `(modelId, primaryRepo, components)`
triple. The per-component CDN path key (`slug` field) is derived from each component's HF repo.

**Upload**:
```bash
# Stage each component first (run acervo download for each repo), then:
acervo ship --spec flux2-spec.json
```

> **Note**: `--spec` with live upload is for operator-tended migration. Use `--dry-run`
> to verify manifest shape before touching live R2 credentials.

---

## Dry-Run Mode: `--dry-run`

`--dry-run` generates manifests from pre-staged files and writes them to disk, skipping
all network I/O (no HuggingFace download, no R2 upload). Useful for:
- Inspecting manifest output in tests and CI
- Verifying spec file correctness before a live upload
- Running CLI tests without R2 credentials

**Single-component dry-run**:
```bash
# Files must already be staged at <STAGING_DIR>/org_repo/ (or --output override)
acervo ship org/repo --dry-run --output-dir /tmp/manifests
# Prints: /tmp/manifests/org_repo-manifest.json
```

**Single-component with slug, dry-run**:
```bash
acervo ship org/repo --slug my-slug --dry-run --output-dir /tmp/manifests
# Manifest has: modelId="my-slug", primaryRepo="org/repo", components=["org/repo"]
```

**Multi-component dry-run**:
```bash
acervo ship --spec flux2-spec.json --dry-run --output-dir /tmp/manifests
# Prints one path per component:
#   /tmp/manifests/black-forest-labs_FLUX.2-klein-4B-manifest.json
#   /tmp/manifests/black-forest-labs_FLUX.2-vae-manifest.json
#   /tmp/manifests/google_t5-v1_1-xxl-manifest.json
# Each manifest has: modelId="flux2-klein-4b", primaryRepo="black-forest-labs/FLUX.2-klein-4B",
#                    components=[all three repos]
```

**Output directory default**: when `--output-dir` is omitted, a unique tempdir is created
under `$TMPDIR` and its path is printed to stdout before the per-manifest paths.

---

## Step-by-Step: Individual Commands

If you need to run steps separately (for debugging or partial uploads):

### Step 1: Download from HuggingFace

```bash
acervo download --model-id "mlx-community/Qwen2.5-7B-Instruct-4bit"
```

**What it does**:
- Fetches file list from HuggingFace
- Downloads all files to `./models/staging/{slug}/`
- Verifies LFS pointers (CHECK 1)

**Options**:
```
--model-id TEXT           Model ID in org/repo format
--staging-dir PATH        Staging directory (default: ./models/staging)
```

**Requires**: `HF_TOKEN` environment variable

**Output**:
```
Downloading from HuggingFace...
config.json (1.2 KB)                      [████] 100%
model.safetensors (4.2 GB)                [████] 100%
tokenizer.json (123 KB)                   [████] 100%

Files staged in: ./models/staging/mlx-community_Qwen2.5-7B-Instruct-4bit/
```

### Step 2: Generate Manifest

```bash
acervo manifest --model-id "mlx-community/Qwen2.5-7B-Instruct-4bit"
```

**What it does**:
- Scans staged directory
- Computes SHA-256 for each file
- Generates `manifest.json`
- Validates manifest integrity (CHECK 2–4)

**Output**:
```
Scanning files...
Generating manifest...
✓ manifest.json (verified)

Files:
  config.json (1.2 KB)
  model.safetensors (4.2 GB)
  tokenizer.json (123 KB)

Manifest checksum: abc123def456...
```

### Step 3: Verify Integrity

```bash
acervo verify --model-id "mlx-community/Qwen2.5-7B-Instruct-4bit" --verbose
```

**What it verifies**:
- CHECK 1: LFS pointer files valid
- CHECK 2: Manifest version is 1
- CHECK 3: Model ID matches
- CHECK 4: Manifest checksum valid
- CHECK 5: File SHA-256 matches manifest
- CHECK 6: No extra/missing files

**Options**:
```
--model-id TEXT           Model ID (required)
--staging-dir PATH        Staging directory (default: ./models/staging)
--verbose                 Print detailed results
```

**Output**:
```
CHECK 1: LFS pointers              ✓ PASS
CHECK 2: Manifest version          ✓ PASS
CHECK 3: Model ID match            ✓ PASS
CHECK 4: Manifest checksum         ✓ PASS
CHECK 5: File checksums (3/3)      ✓ PASS
CHECK 6: File inventory            ✓ PASS

All checks passed!
```

### Step 4: Upload to R2

```bash
acervo upload --model-id "mlx-community/Qwen2.5-7B-Instruct-4bit"
```

**What it does**:
- Verifies manifest and files
- Uploads all files to R2 via `aws` CLI
- Uploads manifest.json
- Verifies uploaded files against manifest

**Options**:
```
--model-id TEXT           Model ID (required)
--staging-dir PATH        Staging directory (default: ./models/staging)
--endpoint URL            R2 endpoint (default: intrusive-memory R2)
--bucket NAME             R2 bucket name (default: "models")
```

**Requires**: `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`

**Output**:
```
Uploading to R2...
  config.json                       [████████████] 100% (1.2 KB)
  model.safetensors                 [████████████] 100% (4.2 GB)
  tokenizer.json                    [████████████] 100% (123 KB)
  manifest.json                     [████████████] 100% (2.1 KB)

Verifying uploaded files...
  config.json                       ✓ OK
  model.safetensors                 ✓ OK
  tokenizer.json                    ✓ OK
  manifest.json                     ✓ OK

Upload complete!
CDN URL: https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/mlx-community_Qwen2.5-7B-Instruct-4bit/
```

---

## Troubleshooting

### "HF_TOKEN not set" or "Authentication failed"

```bash
# Check if token is set
echo $HF_TOKEN

# If not, login to HuggingFace
hf login

# Or set explicitly
export HF_TOKEN="hf_..."
```

### "Model not found on HuggingFace"

Verify the model ID:
```bash
# Check if model exists
curl -H "Authorization: Bearer $HF_TOKEN" \
  https://huggingface.co/api/models?search=Qwen2.5-7B-Instruct-4bit
```

Model must be a **valid, public** HuggingFace repository.

### "R2_ACCESS_KEY_ID not set" or "Access denied"

```bash
# Check if credentials are set
echo $R2_ACCESS_KEY_ID
echo $R2_SECRET_ACCESS_KEY

# If not, get credentials from Cloudflare dashboard
# Settings → R2 → API Tokens
```

Verify credentials work:
```bash
aws --endpoint-url $R2_ENDPOINT s3 ls s3://$R2_BUCKET/
```

### "Upload failed: 403 Forbidden"

Check that:
1. R2 bucket exists and is correct
2. API token has write permissions
3. Endpoint URL is correct

```bash
# List buckets to verify access
aws --endpoint-url $R2_ENDPOINT s3 ls
```

### "Manifest checksum mismatch"

The manifest may have been corrupted or modified. Regenerate:

```bash
acervo manifest --model-id "..." --staging-dir ./models/staging
```

Then verify:
```bash
acervo verify --model-id "..." --verbose
```

### "Downloaded file is incomplete"

The download timed out or the network dropped. Files are resumable. Retry:

```bash
acervo download --model-id "..."
# It will skip already-downloaded files and continue
```

---

## Staging Directory

By default, files are staged in `./models/staging/{slug}/`:

```
./models/staging/
└── mlx-community_Qwen2.5-7B-Instruct-4bit/
    ├── config.json
    ├── model.safetensors
    ├── tokenizer.json
    ├── tokenizer_config.json
    └── manifest.json
```

You can specify a different staging directory:

```bash
acervo ship --model-id "..." --staging-dir /tmp/models
```

**Cleanup**: Staging directory is NOT automatically deleted. You can delete it after successful upload:

```bash
rm -rf ./models/staging/mlx-community_Qwen2.5-7B-Instruct-4bit/
```

---

## Manifest Format

After generation, the manifest looks like (single-component example):

```json
{
  "manifestVersion": 1,
  "modelId": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "primaryRepo": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "components": ["mlx-community/Qwen2.5-7B-Instruct-4bit"],
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
    },
    {
      "path": "tokenizer.json",
      "sha256": "ijkl9012....",
      "sizeBytes": 567890
    }
  ],
  "manifestChecksum": "qrst7890...."
}
```

For a multi-component slug, every component manifest carries the **same** `modelId`,
`primaryRepo`, and `components`, but each has its own unique `slug` (derived from
the component's HF repo) which determines its CDN path:

```json
{
  "manifestVersion": 1,
  "modelId": "flux2-klein-4b",
  "primaryRepo": "black-forest-labs/FLUX.2-klein-4B",
  "components": [
    "black-forest-labs/FLUX.2-klein-4B",
    "black-forest-labs/FLUX.2-vae",
    "google/t5-v1_1-xxl"
  ],
  "slug": "black-forest-labs_FLUX.2-vae",
  "updatedAt": "2026-04-18T10:30:00Z",
  "files": [ ... ],
  "manifestChecksum": "..."
}
```

This manifest is:
- Used by consuming apps to verify downloads
- Stored on CDN alongside model files at `models/{slug}/manifest.json`
- Not user-editable (auto-generated and verified)
- Required to carry all three new fields (`modelId`, `primaryRepo`, `components`);
  manifests missing any field will fail to decode

---

## Legacy Shell Scripts

The following shell scripts are superseded by `acervo` but still work:

```bash
# Legacy: not recommended
./Tools/upload-model.sh "org/repo"
./Tools/generate-manifest.sh "org/repo" /path/to/files

# Modern: use acervo instead
acervo ship --model-id "org/repo"
acervo manifest --model-id "org/repo"
```

---

## Best Practices

1. **Always verify before uploading**: Run `acervo verify --verbose` to catch issues early
2. **Test with small models first**: Don't start with a 100 GB model
3. **Keep credentials in `.env` or secure storage**: Never commit them
4. **Record which version you uploaded**: Note the manifest `updatedAt` timestamp
5. **Test the download**: After uploading, test that `Acervo.ensureAvailable()` works:
   ```bash
   # In a consuming app
   try await Acervo.ensureAvailable("your-new-model", files: ["config.json"])
   ```

---

## See Also

- **[CDN_ARCHITECTURE.md](CDN_ARCHITECTURE.md)** — How downloads work
- **[BUILD_AND_TEST.md](BUILD_AND_TEST.md)** — Running acervo commands
- **[USAGE.md](USAGE.md)** — Integration guide for consuming libraries
