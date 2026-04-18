# BUILD_AND_TEST.md — Building, Testing, and CLI Operations

**For**: Developers building SwiftAcervo itself or working with the `acervo` CLI tool for CDN operations.

---

## Local Development Workflow

### Prerequisites

- **macOS** 26.0+ or **iOS** 26.0+ target
- **Swift** 6.2+
- **Xcode** 26+
- **Make** (for Makefile targets)

For CLI operations (`acervo` tool):
- `aws` CLI (for R2 uploads): `brew install awscli`
- `hf` CLI (for HuggingFace downloads): `brew install huggingface-hub`

### Make Targets

All builds use Makefile targets (not raw `xcodebuild`):

```bash
make build              # Build the SwiftAcervo library scheme
make test               # Run all tests (SwiftAcervo-Package scheme)
make lint               # Format all Swift source files (swift-format)
make clean              # Clean build artifacts
make resolve            # Resolve Swift package dependencies

make build-acervo       # Build the acervo CLI binary (Debug)
make install-acervo     # Build acervo and install to bin/ (Debug)
make release-acervo     # Build acervo and install to bin/ (Release)

make test-acervo-unit   # Run acervo unit tests (no credentials needed)
```

**Note**: Always use `make` targets, not raw `xcodebuild` or `swift` commands. The Makefile encodes correct schemes, destinations, and flags.

### Discover Available Targets

```bash
make help
# or
grep '^[a-z].*:' Makefile | head -20
```

---

## Building

### SwiftAcervo Library

```bash
make build

# Or manually:
xcodebuild build -scheme SwiftAcervo -destination 'platform=macOS'
```

Build artifacts appear in `.build/` and Xcode's derived data directory.

### acervo CLI Tool

```bash
# Debug binary (fast iteration)
make install-acervo
# Binary installed to: ./bin/acervo

# Release binary (optimized)
make release-acervo
# Binary installed to: ./bin/acervo (Release build)

# Check installation
./bin/acervo --help
./bin/acervo --version
```

---

## Testing

### Unit Tests (No Network)

Run entirely offline with no credentials required:

```bash
make test

# Or manually:
xcodebuild test -scheme SwiftAcervo-Package -destination 'platform=macOS'
```

**What's tested**:
- Model discovery and filtering
- Manifest parsing and verification
- Slugification and path resolution
- Error handling
- Thread-safe access patterns
- Fuzzy search (Levenshtein distance)

### Integration Tests (CDN Access)

Integration tests that hit the actual CDN are **gated behind the `INTEGRATION_TESTS` compile flag** and excluded from normal test runs.

```bash
# Run integration tests (requires network and credentials)
xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS' \
    OTHER_SWIFT_FLAGS='-D INTEGRATION_TESTS'
```

**Prerequisites for integration tests**:
- Network access to `https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev`
- Valid R2 credentials (if testing upload operations)
- No rate limiting or firewall blocks

### Linting

```bash
make lint

# Format all Swift files in-place
swift-format -i Sources/ Tests/
```

---

## acervo CLI Tool

The `acervo` CLI automates CDN operations: downloading from HuggingFace, generating manifests, verifying integrity, and uploading to R2.

**All commands**:
```
acervo download    Download model files from HuggingFace
acervo manifest    Generate a CDN manifest for staged files
acervo verify      Run all 6 integrity checks against staged files
acervo upload      Upload model files to R2 CDN
acervo ship        Full pipeline: download, manifest, verify, upload
```

### Command: acervo ship

**Full pipeline: download from HuggingFace → generate manifest → verify → upload to R2**

```bash
acervo ship --model-id "org/repo"
```

**What it does**:
1. Downloads model files from HuggingFace
2. Generates `manifest.json` with SHA-256 checksums
3. Runs all 6 integrity checks
4. Uploads files and manifest to R2 CDN

**Options**:
```
--model-id TEXT           Model ID in org/repo format (required)
--staging-dir PATH        Directory for staged files (default: ./models/staging)
--repo-path PATH          Path to repo root (default: current directory)
```

**Environment variables**:
```bash
export HF_TOKEN="hf_..."                          # HuggingFace API token
export R2_ACCESS_KEY_ID="..."                     # Cloudflare R2 access key
export R2_SECRET_ACCESS_KEY="..."                 # Cloudflare R2 secret key
export R2_BUCKET="models"                         # (optional, default: "models")
export R2_ENDPOINT="https://..."                  # (optional, default: intrusive-memory R2)
export R2_PUBLIC_URL="https://pub-..."           # (optional, default: intrusive-memory CDN)
export STAGING_DIR="/path/to/staging"            # (optional, default: ./models/staging)
```

**Example**:
```bash
export HF_TOKEN="hf_..."
export R2_ACCESS_KEY_ID="..."
export R2_SECRET_ACCESS_KEY="..."

acervo ship --model-id "mlx-community/Qwen2.5-7B-Instruct-4bit"
# Downloads, manifests, verifies, and uploads in one go
```

### Command: acervo download

**Download model files from HuggingFace only (no manifest or upload)**

```bash
acervo download --model-id "org/repo"
```

**What it does**:
1. Fetches file list from HuggingFace LFS
2. Downloads all files with progress
3. Performs CHECK 1 (LFS pointer integrity)
4. Stages files in `./models/staging/{slug}/`

**Options**:
```
--model-id TEXT           Model ID in org/repo format (required)
--staging-dir PATH        Staging directory (default: ./models/staging)
```

**Requires**: `HF_TOKEN` environment variable

**Example**:
```bash
acervo download --model-id "mlx-community/Qwen2.5-7B-Instruct-4bit"
# Files staged in ./models/staging/mlx-community_Qwen2.5-7B-Instruct-4bit/
```

### Command: acervo manifest

**Generate CDN manifest for staged files (no upload)**

```bash
acervo manifest --model-id "org/repo"
```

**What it does**:
1. Scans staged directory for files
2. Generates `manifest.json` with SHA-256 per-file
3. Computes manifest checksum (SHA-256-of-checksums)
4. Validates manifest version and model ID

**Options**:
```
--model-id TEXT           Model ID in org/repo format (required)
--staging-dir PATH        Staging directory (default: ./models/staging)
```

**Output**: `./models/staging/{slug}/manifest.json`

**Example**:
```bash
acervo manifest --model-id "mlx-community/Qwen2.5-7B-Instruct-4bit"
# Generates ./models/staging/mlx-community_Qwen2.5-7B-Instruct-4bit/manifest.json
```

### Command: acervo verify

**Run all 6 integrity checks (no upload)**

```bash
acervo verify --model-id "org/repo"
```

**What it verifies**:
1. **CHECK 1**: LFS pointer file integrity (HuggingFace artifacts)
2. **CHECK 2**: Manifest version valid (must be 1)
3. **CHECK 3**: Manifest model ID matches CLI argument
4. **CHECK 4**: Manifest checksum valid (SHA-256-of-checksums)
5. **CHECK 5**: Per-file SHA-256 matches manifest
6. **CHECK 6**: Staged files match manifest exactly (no extra/missing files)

**Options**:
```
--model-id TEXT           Model ID in org/repo format (required)
--staging-dir PATH        Staging directory (default: ./models/staging)
--verbose                 Print detailed check results
```

**Example**:
```bash
acervo verify --model-id "mlx-community/Qwen2.5-7B-Instruct-4bit" --verbose
```

### Command: acervo upload

**Upload staged files to R2 CDN (no download or manifest generation)**

```bash
acervo upload --model-id "org/repo"
```

**What it does**:
1. Verifies manifest and files
2. Uploads all files to R2 via `aws` CLI
3. Verifies uploaded files match manifest
4. Reports success/failure per file

**Options**:
```
--model-id TEXT           Model ID in org/repo format (required)
--staging-dir PATH        Staging directory (default: ./models/staging)
--endpoint URL            R2 endpoint (default: intrusive-memory R2)
--bucket NAME             R2 bucket (default: "models")
```

**Environment variables**:
```bash
export R2_ACCESS_KEY_ID="..."
export R2_SECRET_ACCESS_KEY="..."
```

**Example**:
```bash
acervo upload --model-id "mlx-community/Qwen2.5-7B-Instruct-4bit"
# Uploads to https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/mlx-community_Qwen2.5-7B-Instruct-4bit/
```

---

## acervo CLI Tests

### Unit Tests (No Credentials)

Test argument parsing, manifest generation, integrity checks:

```bash
make test-acervo-unit

# Or manually:
xcodebuild test -scheme AcervoToolTests -destination 'platform=macOS'
```

**What's tested**:
- Argument parsing and validation
- Manifest generation and checksum computation
- Integrity check logic (all 6 checks)
- Error handling
- File staging operations

### Integration Tests (Full Pipeline)

These tests actually download from HuggingFace and upload to R2:

```bash
xcodebuild test -scheme AcervoToolIntegrationTests \
    -destination 'platform=macOS' \
    -skipPackagePluginValidation
```

**Requires**:
- `HF_TOKEN` environment variable
- `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`
- Network access to HuggingFace and R2

**These are slow and expensive** — only run when testing the full pipeline.

---

## CI/CD (GitHub Actions)

Tests run automatically on every PR targeting `main` or `development`:

[![Tests](https://github.com/intrusive-memory/SwiftAcervo/actions/workflows/tests.yml/badge.svg)](https://github.com/intrusive-memory/SwiftAcervo/actions/workflows/tests.yml)

### CI Workflow

| Job | Runner | Destination | Tests |
|-----|--------|-------------|-------|
| Test on macOS | `macos-26` | `platform=macOS` | Unit + integration |
| Test on iOS Simulator | `macos-26` | `platform=iOS Simulator,name=iPhone 17,OS=26.1` | Unit tests only |

**Workflow file**: [`.github/workflows/tests.yml`](.github/workflows/tests.yml)

**Required status checks**:
- ✅ Test on macOS
- ✅ Test on iOS Simulator

These must pass before merging to `main`.

### Local Simulation

To simulate CI locally:

```bash
# macOS tests (as run in CI)
xcodebuild test -scheme SwiftAcervo-Package -destination 'platform=macOS'

# iOS Simulator tests (as run in CI)
xcodebuild test -scheme SwiftAcervo-Package \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.1'
```

---

## Legacy Tools

### Shell Scripts (Superseded by acervo CLI)

The following shell scripts still work but are deprecated. Use `acervo` commands instead:

```bash
# Legacy (works, but use acervo instead)
./Tools/upload-model.sh "org/repo"
./Tools/generate-manifest.sh "org/repo" /path/to/model/files

# Modern equivalent
acervo ship --model-id "org/repo"
acervo manifest --model-id "org/repo"
```

These scripts are maintained for backward compatibility but no longer recommended.

---

## Troubleshooting

### Build Fails: "Swift version X is not compatible"

Ensure you're using Swift 6.2+ (check with `swift --version`). Update Xcode if needed.

### Tests Timeout

Some integration tests depend on network speed. Increase timeout:
```bash
xcodebuild test -scheme SwiftAcervo-Package -destination 'platform=macOS' \
    -IDEBuildOperationMaxTimeInterval 3600  # 1 hour
```

### acervo: Command Not Found

Ensure you've installed the binary:
```bash
make install-acervo
export PATH="$(pwd)/bin:$PATH"  # Add to PATH
```

### R2 Upload Fails: "Access Denied"

Check credentials:
```bash
echo $R2_ACCESS_KEY_ID
echo $R2_SECRET_ACCESS_KEY
```

Verify with `aws`:
```bash
aws --endpoint-url $R2_ENDPOINT s3 ls s3://$R2_BUCKET/
```

### HuggingFace Download Fails: "Authentication Failed"

Ensure `HF_TOKEN` is set:
```bash
echo $HF_TOKEN  # Should not be empty
hf login        # Or: hf login --token $HF_TOKEN
```

---

## See Also

- **[README.md](README.md)** — User-facing overview
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — Contribution guidelines
- **[CDN_UPLOAD.md](CDN_UPLOAD.md)** — CDN upload workflow
