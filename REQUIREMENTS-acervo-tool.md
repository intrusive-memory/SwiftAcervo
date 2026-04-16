# Requirements: `acervo` CLI Tool

**Status**: DRAFT
**Scope**: A Swift 6.2 command-line binary for downloading AI models from upstream sources,
validating their integrity, generating CDN manifests, and mirroring them to Cloudflare R2.
Replaces the existing `Tools/upload-model.sh` and `Tools/generate-manifest.sh` shell scripts.

---

## Background

The existing shell scripts (`Tools/upload-model.sh`, `Tools/generate-manifest.sh`) have a
critical gap: they compute SHA-256 checksums from whatever `huggingface-cli` wrote to disk,
with no cross-check against HuggingFace's own LFS integrity metadata. A corrupt or truncated
download produces a manifest with bad checksums, which the CDN then serves indefinitely.
Clients detect the mismatch at the consumer device — not at the source.

The `acervo` binary fixes this by validating each downloaded file against HuggingFace's LFS
`oid` field before any manifest is generated. It also replaces `rclone` (requires config file)
with the `aws` CLI (maps directly from environment variables), which is pre-installed on
macOS GitHub Actions runners.

---

## 1. Binary Identity

| Property | Value |
|---|---|
| Binary name | `acervo` |
| Install path (local) | `./bin/acervo` |
| Install path (system) | `brew install intrusive-memory/tap/acervo` |
| Language | Swift 6.2 |
| Platforms | macOS 26+ only |
| Pattern | Matches `proyecto` and `diga`: SPM + ArgumentParser + Makefile |
| Entry point | `Sources/acervo/AcervoCLI.swift` with `@main AsyncParsableCommand` |
| Metal bundle | Not required (no MLX inference; file I/O only) |

---

## 2. Subcommands

### `acervo download <model-id> [files...]`

Downloads a model from an upstream source to local staging.

| Option | Default | Description |
|---|---|---|
| `--source` / `-s` | `hf` | Download source. `hf` = HuggingFace. Future: direct URL |
| `--output` / `-o` | `$STAGING_DIR/<slug>` | Override local destination directory |
| `--token` / `-t` | `$HF_TOKEN` | HuggingFace token for gated models |
| `--no-verify` | off | Skip post-download integrity check against HF LFS metadata |
| `[files...]` | (all) | Optional subset of files to download |

After `huggingface-cli` completes, validates every downloaded file's SHA-256 against
HuggingFace's LFS `oid` field via the HF API. Fails with a clear per-file error
(filename, expected hash, actual hash) before any manifest is generated. The `--no-verify`
flag bypasses this check for cases where HF does not publish LFS metadata.

### `acervo upload <model-id> <directory>`

Generates `manifest.json` from a local directory, verifies all files, then uploads
everything to the CDN.

| Option | Default | Description |
|---|---|---|
| `--bucket` / `-b` | `$R2_BUCKET` | R2 bucket name |
| `--prefix` / `-p` | `models/` | Key prefix within the bucket |
| `--endpoint` | `$R2_ENDPOINT` | S3-compatible endpoint URL |
| `--dry-run` | off | Print what would be uploaded; do nothing |
| `--force` | off | Re-upload files even if CDN already has them |

Upload order: generate manifest → verify all files against manifest → upload model files →
upload `manifest.json` last. The CDN treats `manifest.json` presence as the completeness
signal, mirroring the client-side `config.json` convention.

### `acervo ship <model-id> [files...]`

Convenience pipeline: `download` → HF integrity check → `upload` in one command.
Accepts the union of all `download` and `upload` options. This is the primary day-to-day
command and the one invoked by the `mirror_model.yml` GitHub Actions workflow.

### `acervo manifest <model-id> <directory>`

Generates `manifest.json` for a local directory without uploading. Port of the logic in
`Tools/generate-manifest.sh` into Swift, using the library's `CDNManifest` types directly.
Useful for inspection or manual upload workflows.

### `acervo verify <model-id> [directory]`

With `directory`: validates local files against a freshly generated manifest.
Without `directory`: downloads the CDN manifest and checks files in `$STAGING_DIR/<slug>`
against it.

---

## 3. Integrity Checks at Every Step

Every step in the pipeline has an explicit integrity gate. Failure at any gate aborts with
a clear error message identifying the file and the nature of the mismatch.

```
HF Download
  └─ [CHECK 1] Each file's SHA-256 vs HF LFS `oid` from the HF API
      FAIL → delete the staging file, report filename + expected vs actual hash, abort

Manifest Generation
  └─ [CHECK 2] All expected files present and non-zero bytes
  └─ [CHECK 3] Re-derive manifestChecksum after writing; compare to the written value
      FAIL → delete manifest.json, abort

Upload
  └─ [CHECK 4] Re-verify all file SHA-256s against manifest entries before any bytes
               leave the machine (paranoia gate; catches staging mutations between steps)
  └─ `aws s3 sync` exits 0
  └─ [CHECK 5] Fetch manifest.json from CDN; verify HTTP 200, parse JSON,
               call CDNManifest.verifyChecksum()
  └─ [CHECK 6] Spot-check: fetch config.json bytes from CDN; compare SHA-256
               to the manifest entry
      FAIL → report CDN URL and which check failed; warn that files may be
             partially uploaded and recommend re-running with --force
```

Checks 1 and 4 reuse `IntegrityVerification.sha256(of:)` from the SwiftAcervo library.
Check 3 reuses `CDNManifest.computeChecksum(from:)`. Check 5 reuses `CDNManifest.verifyChecksum()`.
No integrity logic is reimplemented in the tool layer.

---

## 4. CDN Upload Implementation

Shell out to the `aws` CLI with the R2 S3-compatible endpoint:

```
AWS_ACCESS_KEY_ID=$R2_ACCESS_KEY_ID \
AWS_SECRET_ACCESS_KEY=$R2_SECRET_ACCESS_KEY \
aws s3 sync <local-dir> s3://$R2_BUCKET/models/<slug>/ \
  --endpoint-url $R2_ENDPOINT \
  --exclude "*.DS_Store" \
  --exclude ".huggingface/*"
```

`aws s3 sync` is idempotent and skips files that already exist with matching size/etag.
The `--dry-run` flag passes through directly to `aws s3 sync --dryrun`.
`manifest.json` is uploaded last via a separate `aws s3 cp` call after all model files
have been synced, so the CDN never shows a manifest pointing to files not yet present.

**Why `aws` CLI over `rclone`**: `rclone` requires a separate config file beyond environment
variables. The `aws` CLI maps directly from `$R2_ACCESS_KEY_ID` and `$R2_SECRET_ACCESS_KEY`
to `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. It is pre-installed on macOS GitHub
Actions runners (version 2.34.24 confirmed on `macos-15`; expected on `macos-26`).

---

## 5. Environment Variables

| Variable | Required | Local Source | CI Source | Description |
|---|---|---|---|---|
| `R2_ACCOUNT_ID` | local only | `~/.zprofile` | not needed | Used to derive endpoint if `R2_ENDPOINT` not set |
| `R2_ENDPOINT` | yes | `~/.zprofile` (derived) | org secret | Full S3 endpoint URL |
| `R2_BUCKET` | yes | `~/.zprofile` | org secret | Target bucket name |
| `R2_ACCESS_KEY_ID` | yes | `~/.zprofile` | org secret | S3-compatible access key |
| `R2_SECRET_ACCESS_KEY` | yes | `~/.zprofile` | org secret | S3-compatible secret key |
| `HF_TOKEN` | gated models | `~/.zprofile` | org secret | HuggingFace auth token |
| `STAGING_DIR` | no | optional | optional | Local staging root (default: `/tmp/acervo-staging`) |

`R2_ENDPOINT` takes precedence. If absent, the CLI derives it as
`https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com`. In CI, `R2_ENDPOINT` is set directly
as an org secret, so `R2_ACCOUNT_ID` is not needed there.

Note: `CLOUDFLARE_ACCOUNT_ID` is an org secret but is NOT used by `acervo`. `R2_ACCOUNT_ID`
is the canonical name for local development.

---

## 6. Homebrew Dependencies

The binary checks for required external tools at startup and prints install instructions
if any are missing.

| Tool | Install | Used for |
|---|---|---|
| `awscli` | `brew install awscli` | CDN upload via R2 S3-compatible endpoint |
| `huggingface-hub` | `brew install huggingface-hub` | `huggingface-cli download` |

On macOS GitHub Actions runners, `aws` CLI is pre-installed. `huggingface-cli` requires
an explicit `brew install huggingface-hub` step in the workflow.

---

## 7. Source File Structure

```
Sources/
  SwiftAcervo/               # existing library (unchanged)
  acervo/
    AcervoCLI.swift          # @main, version constant, subcommand registration
    DownloadCommand.swift    # acervo download
    UploadCommand.swift      # acervo upload
    ShipCommand.swift        # acervo ship (download + upload pipeline)
    ManifestCommand.swift    # acervo manifest
    VerifyCommand.swift      # acervo verify
    HuggingFaceClient.swift  # HF API calls + post-download integrity validation
    ManifestGenerator.swift  # Swift port of generate-manifest.sh; uses CDNManifest types
    CDNUploader.swift        # aws CLI wrapper (shell-out); manages upload order
    ToolCheck.swift          # startup validation of required external tools
    Version.swift            # version constant
```

---

## 8. Package.swift Changes

### New dependency

```swift
.package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
```

(`swift-argument-parser` is not currently a dependency of SwiftAcervo.)

### New product

```swift
.executable(name: "acervo", targets: ["acervo"]),
```

### New target

```swift
.executableTarget(
  name: "acervo",
  dependencies: [
    "SwiftAcervo",
    .product(name: "ArgumentParser", package: "swift-argument-parser"),
  ],
  path: "Sources/acervo",
  swiftSettings: [
    .enableUpcomingFeature("StrictConcurrency")
  ]
),
```

---

## 9. Makefile Changes

New targets following the exact `proyecto` / `diga` pattern. No Metal bundle copy step
(no MLX dependency).

```makefile
ACERVO_SCHEME = acervo
ACERVO_BINARY = acervo

build-acervo: resolve
	xcodebuild -scheme $(ACERVO_SCHEME) -destination '$(DESTINATION)' build

install-acervo: resolve
	xcodebuild -scheme $(ACERVO_SCHEME) -destination '$(DESTINATION)' build
	@mkdir -p $(BIN_DIR)
	@PRODUCT_DIR=$$(find $(DERIVED_DATA)/SwiftAcervo-*/Build/Products/Debug \
	  -name $(ACERVO_BINARY) -type f 2>/dev/null | head -1 | xargs dirname); \
	if [ -n "$$PRODUCT_DIR" ]; then \
	  cp "$$PRODUCT_DIR/$(ACERVO_BINARY)" $(BIN_DIR)/; \
	  echo "Installed $(ACERVO_BINARY) to $(BIN_DIR)/ (Debug)"; \
	else \
	  echo "Error: Could not find $(ACERVO_BINARY) in DerivedData"; exit 1; \
	fi

release-acervo: resolve
	xcodebuild -scheme $(ACERVO_SCHEME) -destination '$(DESTINATION)' \
	  -configuration Release build
	# (same copy logic, Products/Release)
```

---

## 10. Testing

### Test Target 1: `AcervoToolTests` (unit; no credentials; always runs in CI)

| Suite | What it covers |
|---|---|
| `ManifestGeneratorTests` | Generate manifest from a temp fixture directory; assert file entries, per-file SHA-256, `manifestChecksum`, field order |
| `HuggingFaceClientTests` | Parse HF API JSON responses from fixtures; verify LFS `oid` extraction; verify error paths for missing/malformed fields |
| `CDNUploaderTests` | Verify `aws` command construction — endpoint URL, bucket path, env var mapping, upload order (model files before manifest); no actual upload |
| `ToolCheckTests` | Detect missing `aws` and `huggingface-cli`; verify error messages match expected `brew install` instructions |
| `IntegrityStepTests` | Unit-test each pipeline checkpoint in isolation: CHECK 2 (zero-byte file), CHECK 3 (manifest corruption detection), CHECK 4 (staging mutation between steps) |

### Test Target 2: `AcervoToolIntegrationTests` (network + credentials; gated)

Skipped automatically if `R2_ACCESS_KEY_ID` or `HF_TOKEN` environment variables are absent.
Never runs on pull request CI. Runs on `workflow_dispatch` via a dedicated integration
test workflow.

| Suite | What it covers |
|---|---|
| `HuggingFaceDownloadTests` | Download `config.json` from a small public model; verify CHECK 1 passes; verify CHECK 1 fails correctly on a deliberately corrupted file |
| `CDNRoundtripTests` | Upload a synthetic fixture (not a real model) to a `test/` prefix in the bucket; verify CHECK 5 + CHECK 6 pass; delete fixture after test |
| `ManifestRoundtripTests` | Generate manifest locally, upload, download CDN manifest, assert manifests are byte-identical |
| `ShipCommandTests` | Full `ship` pipeline against a small public model; verify final CDN state matches local state |

### CI Test Coverage Requirements

- All new code must achieve ≥90% line coverage in unit tests.
- No timed tests: `sleep()`, `Task.sleep()`, or wall-clock assertions are not permitted.
- No environment-dependent unit tests: unit tests use mock filesystems and injected dependencies.
- A test that passes intermittently is treated as a failing test. No retry-on-failure masking.

### Makefile Test Targets

```makefile
test-acervo-unit         # AcervoToolTests (no credentials)
test-acervo-integration  # AcervoToolIntegrationTests (requires R2_* + HF_TOKEN)
test-acervo-cdn          # Fetch manifest for a known model, verify checksum (network, no credentials)
```

---

## 11. GitHub Actions: `mirror_model.yml` Reusable Workflow

### Location

`.github/workflows/mirror_model.yml` within the SwiftAcervo repository.

### Purpose

A reusable workflow (`workflow_call`) that any org project can call with two lines to
ensure a given model is mirrored on the CDN. The calling project needs no knowledge of
CDN credentials, bucket names, or endpoint URLs — all of that flows from org secrets
via `secrets: inherit`.

### Inputs

| Input | Required | Description |
|---|---|---|
| `model_id` | yes | HuggingFace model ID in `org/repo` format |
| `files` | no | Space-separated file subset; omit to mirror all files |
| `acervo_version` | no | Homebrew formula version; default `latest` |

### Org Secrets Consumed

All consumed via `secrets: inherit`. No per-project secret configuration needed.

| Secret | Environment variable in job |
|---|---|
| `R2_ACCESS_KEY_ID` | `R2_ACCESS_KEY_ID` |
| `R2_SECRET_ACCESS_KEY` | `R2_SECRET_ACCESS_KEY` |
| `R2_ENDPOINT` | `R2_ENDPOINT` |
| `R2_BUCKET` | `R2_BUCKET` |
| `HF_TOKEN` | `HF_TOKEN` |

Note: `CLOUDFLARE_ACCOUNT_ID` is NOT consumed. `R2_ENDPOINT` is the full URL; no account
ID derivation needed in CI.

### Workflow Steps

1. Install `huggingface-cli` (`brew install huggingface-hub`)
2. Install `acervo` (`brew install intrusive-memory/tap/acervo`)
3. Run `acervo ship "${{ inputs.model_id }}"` (or with `files` subset if provided)

`aws` CLI requires no install step — pre-installed on `macos-26` runners.

### Calling It From Any Project

The entire workflow file a downstream project needs:

```yaml
name: Mirror Model to CDN
on:
  workflow_dispatch:
  push:
    branches: [main]

jobs:
  mirror:
    uses: intrusive-memory/SwiftAcervo/.github/workflows/mirror_model.yml@main
    with:
      model_id: mlx-community/Qwen2.5-7B-Instruct-4bit
    secrets: inherit
```

The org secrets flow automatically. The calling project stores no credentials.

### Idempotency

`acervo ship` is safe to re-run. `aws s3 sync` skips files already on the CDN with
matching content. CHECK 1 (HF validation) runs on every invocation — if HuggingFace
updates a file, the new version is detected and re-uploaded.

---

## 12. Homebrew Formula

A formula `Formula/acervo.rb` must be added to `intrusive-memory/homebrew-tap` when the
first binary is released. The existing formulas (`proyecto.rb`, `diga.rb`, etc.) in that
repo define the pattern to follow.

The release process for SwiftAcervo:
1. Tag a release (e.g. `v1.0.0`) via the `/ship-swift-library` skill
2. Build a release binary with `make release-acervo`
3. Attach the binary as a GitHub release asset
4. Update `Formula/acervo.rb` in `intrusive-memory/homebrew-tap` with the new SHA-256 and
   download URL

Until the formula is published, the `mirror_model.yml` workflow can build `acervo` from
source as a stopgap:

```yaml
- uses: actions/checkout@v4
  with:
    repository: intrusive-memory/SwiftAcervo
- run: make install-acervo
- run: ./bin/acervo ship "${{ inputs.model_id }}"
```

---

## 13. Files Superseded by This Effort

Once `acervo` is released and the Homebrew formula is published, the following files
should be archived or deleted:

| File | Replaced by |
|---|---|
| `Tools/upload-model.sh` | `acervo ship` |
| `Tools/generate-manifest.sh` | `acervo manifest` / `ManifestGenerator.swift` |

---

## 14. Implementation Order

1. `Package.swift` — add `swift-argument-parser` dependency and `acervo` executable target
2. `Makefile` — add `build-acervo`, `install-acervo`, `release-acervo`, test targets
3. `Version.swift`, `AcervoCLI.swift` — entry point and subcommand registration
4. `ToolCheck.swift` — startup validation of `aws` and `huggingface-cli`
5. `ManifestGenerator.swift` — Swift port of `generate-manifest.sh`; uses `CDNManifest` types
6. `HuggingFaceClient.swift` — HF API + CHECK 1 validation
7. `CDNUploader.swift` — `aws` CLI wrapper; correct upload order
8. `DownloadCommand.swift`, `UploadCommand.swift`, `ManifestCommand.swift`, `VerifyCommand.swift`
9. `ShipCommand.swift` — pipeline orchestration with all six integrity checks
10. `AcervoToolTests` — unit test suite
11. `.github/workflows/mirror_model.yml` — reusable CI workflow
12. `AcervoToolIntegrationTests` — integration test suite
13. `Formula/acervo.rb` in `intrusive-memory/homebrew-tap` — on first release
