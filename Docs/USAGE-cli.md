# SwiftAcervo CLI — `acervo`

Reference for the `acervo` command-line tool. Textual mirror of `acervo --help` plus every subcommand's `--help`, captured from version `0.18.2`.

Regenerate after CLI changes: `make install-acervo` then re-run this file's source generator.

---

## Top-level `acervo`

```
OVERVIEW: Download, verify, and mirror AI models to the intrusive-memory CDN.

acervo manages the full lifecycle of AI models for the intrusive-memory CDN:
downloading from HuggingFace, generating SHA-256 manifests, uploading to
Cloudflare R2 via the native publish pipeline in SwiftAcervo, and running a
6-step integrity pipeline (CHECKs 1–6).

COMMON ENVIRONMENT VARIABLES
  HF_TOKEN                 HuggingFace API token (required for private/gated
models)
  R2_ACCESS_KEY_ID         Cloudflare R2 access key (required for
upload/ship/recache)
  R2_SECRET_ACCESS_KEY     Cloudflare R2 secret key (required for
upload/ship/recache)
  R2_BUCKET                R2 bucket name (default: intrusive-memory-models)
  R2_ENDPOINT              R2 S3-compatible endpoint URL
  R2_PUBLIC_URL            Public CDN base URL for CHECK 5/6 verification
  R2_REGION                R2 region (default: auto)
  STAGING_DIR              Override default staging root (/tmp/acervo-staging)

REQUIRED TOOLS
  hf        HuggingFace CLI — used for model downloads (brew install
huggingface-hub)

TYPICAL WORKFLOW
  # Download and publish a model in one step:
  acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit

  # Or step by step:
  acervo download mlx-community/Qwen2.5-7B-Instruct-4bit
  acervo upload mlx-community/Qwen2.5-7B-Instruct-4bit
/tmp/acervo-staging/mlx-community_Qwen2.5-7B-Instruct-4bit

  # Re-pull a model from HF and atomically republish (prunes orphans):
  acervo recache mlx-community/Qwen2.5-7B-Instruct-4bit

  # Wipe a model from local cache, staging, and CDN:
  acervo delete mlx-community/Qwen2.5-7B-Instruct-4bit --local --cdn --yes

USAGE: acervo <subcommand>

OPTIONS:
  --version               Show the version.
  -h, --help              Show help information.

SUBCOMMANDS:
  download                Download a model from HuggingFace into the staging
                          directory.
  upload                  Upload a staged model directory to the
                          intrusive-memory CDN.
  ship                    Download a model from HuggingFace and mirror it to
                          the CDN.
  manifest                Generate a CDN manifest.json for a local model
                          directory.
  verify                  Verify a local or CDN-hosted model against its
                          manifest.
  delete                  Delete a model from local cache, staging directory,
                          and/or CDN.
  recache                 Re-fetch a model from HuggingFace and atomically
                          republish it to the CDN.

  See 'acervo help <subcommand>' for detailed help.
```

---

## `acervo download`

```
OVERVIEW: Download a model from HuggingFace into the staging directory.

Shells out to `hf download` and then verifies every downloaded file's
SHA-256 against the HuggingFace LFS API (CHECK 1). Files whose hash
does not match are deleted and the command exits non-zero.

The staging directory is: $STAGING_DIR/<slug>  or  /tmp/acervo-staging/<slug>
where <slug> is the model ID with '/' replaced by '_'.

REQUIRED TOOLS
  hf   HuggingFace CLI (brew install huggingface-hub)

REQUIRED ENVIRONMENT VARIABLES
  HF_TOKEN   Required for private or gated models (or pass --token)

EXAMPLES
  acervo download mlx-community/Qwen2.5-7B-Instruct-4bit
  acervo download mlx-community/Qwen2.5-7B-Instruct-4bit config.json
tokenizer.json
  acervo download mlx-community/Qwen2.5-7B-Instruct-4bit --output
/tmp/my-staging --no-verify

USAGE: acervo download <model-id> [<files> ...] [--source <source>] [--output <output>] [--token <token>] [--no-verify] [--quiet]

ARGUMENTS:
  <model-id>              HuggingFace model identifier in 'org/repo' form.
  <files>                 Optional subset of files to download. Defaults to the
                          whole repo.

OPTIONS:
  -s, --source <source>   Source registry (only 'hf' is supported today).
                          (default: hf)
  -o, --output <output>   Override staging directory root (default:
                          $STAGING_DIR or /tmp/acervo-staging).
  -t, --token <token>     HuggingFace token. Falls back to $HF_TOKEN when unset.
  --no-verify             Skip HuggingFace LFS SHA-256 verification (CHECK 1).
  -q, --quiet             Suppress the download/upload progress bar and
                          subprocess output. Errors still print.
  --version               Show the version.
  -h, --help              Show help information.

```

---

## `acervo upload`

```
OVERVIEW: Upload a staged model directory to the intrusive-memory CDN.

Runs integrity CHECKs 2–6 against a locally-staged model directory:

  CHECK 2  Refuse manifest generation if any file is zero bytes.
  CHECK 3  Re-read manifest.json after writing and verify its checksum.
  CHECK 4  Re-hash every staged file against the manifest before uploading.
  CHECK 5  Fetch manifest.json from the CDN and validate its checksum.
  CHECK 6  Download config.json (or the first manifest entry) from the
           CDN and verify its SHA-256.

The <directory> argument must be the path to the staged model files.
Use `acervo download` first if you need to fetch from HuggingFace,
or use `acervo ship` to run the full pipeline in one step.

Orphan prune runs by default — CDN keys not referenced by the new
manifest are deleted after CHECK 6 passes. Pass `--keep-orphans` to
preserve the previous additive-only behavior.

REQUIRED ENVIRONMENT VARIABLES
  R2_ACCESS_KEY_ID       Cloudflare R2 access key
  R2_SECRET_ACCESS_KEY   Cloudflare R2 secret key
  R2_ENDPOINT            S3-compatible endpoint URL
  R2_PUBLIC_URL          Public CDN base URL used for CHECK 5/6

OPTIONAL ENVIRONMENT VARIABLES
  R2_BUCKET     Bucket name (default: intrusive-memory-models)
  R2_REGION     Region (default: auto)

EXAMPLES
  acervo upload mlx-community/Qwen2.5-7B-Instruct-4bit
/tmp/acervo-staging/mlx-community_Qwen2.5-7B-Instruct-4bit
  acervo upload mlx-community/Qwen2.5-7B-Instruct-4bit /tmp/staging --dry-run
  acervo upload mlx-community/Qwen2.5-7B-Instruct-4bit /tmp/staging
--keep-orphans

USAGE: acervo upload [<options>] <model-id> <directory>

ARGUMENTS:
  <model-id>              HuggingFace model identifier in 'org/repo' form.
  <directory>             Local directory containing the staged model files.

OPTIONS:
  -b, --bucket <bucket>   R2 bucket name. Defaults to $R2_BUCKET environment
                          variable.
  -p, --prefix <prefix>   Key prefix for uploaded objects (default: 'models/').
                          (default: models/)
  --endpoint <endpoint>   R2 endpoint URL. Defaults to $R2_ENDPOINT environment
                          variable.
  --dry-run               Generate and verify the manifest, then print a 'would
                          upload' summary without contacting the CDN.
  --force                 Reserved flag retained for argv compatibility with
                          the pre-v0.14.x shell-out pipeline. The native
                          publish path always uploads exactly the manifest's
                          file set, so this flag is a no-op today.
  --no-verify             Reserved flag retained for argv compatibility with
                          the legacy upload pipeline. CHECKs 4/5/6 are now
                          always run by Acervo.publishModel; this flag is a
                          no-op today.
  -t, --token <token>     Unused for upload. Reserved for argv compatibility.
  -s, --source <source>   Unused for upload. Reserved for argv compatibility.
  -o, --output <output>   Unused for upload. Reserved for argv compatibility.
  --keep-orphans          Skip the orphan-prune step. By default, keys on the
                          CDN not referenced by the new manifest are deleted.
  -q, --quiet             Suppress the download/upload progress bar and
                          subprocess output. Errors still print.
  --version               Show the version.
  -h, --help              Show help information.

```

---

## `acervo ship`

```
OVERVIEW: Download a model from HuggingFace and mirror it to the CDN.

Runs the full integrity pipeline in one command:

  CHECK 0  HF tree completeness — every file the HF API advertises
           must be present in staging at the expected size.
  CHECK 1  HF LFS verify — recompute each downloaded file's SHA-256
           and assert it matches the HF LFS API. (Skip with --no-verify.)
  CHECK 2  Refuse to generate a manifest if any file is zero bytes.
  CHECK 3  Re-read manifest.json after writing and verify its checksum.
  CHECK 4  Re-hash every staged file against the manifest before uploading.
  CHECK 5  Fetch manifest.json from the CDN and validate its checksum.
  CHECK 6  Download config.json (or the first manifest entry) from the
           CDN and verify its SHA-256.

Orphan prune runs by default — CDN keys not referenced by the new
manifest are deleted after CHECK 6 passes. Pass `--keep-orphans` to
preserve the previous additive-only behavior.

REQUIRED ENVIRONMENT VARIABLES
  HF_TOKEN               HuggingFace token (or pass --token)
  R2_ACCESS_KEY_ID       Cloudflare R2 access key
  R2_SECRET_ACCESS_KEY   Cloudflare R2 secret key
  R2_ENDPOINT            S3-compatible endpoint URL
  R2_PUBLIC_URL          Public CDN base URL used for CHECK 5/6

OPTIONAL ENVIRONMENT VARIABLES
  R2_BUCKET              Bucket name (default: intrusive-memory-models)
  R2_REGION              Region (default: auto)
  STAGING_DIR            Staging root (default: /tmp/acervo-staging)

EXAMPLES
  acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit
  acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit config.json tokenizer.json
  acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit --no-verify --dry-run
  acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit --keep-orphans
  acervo ship org/repo --slug my-slug --dry-run --output-dir /tmp/manifests
  acervo ship --spec /path/to/spec.json --dry-run --output-dir /tmp/manifests

USAGE: acervo ship [<options>] [<model-id>] [<files> ...]

ARGUMENTS:
  <model-id>              HuggingFace model identifier in 'org/repo' form. Omit
                          when using --spec.
  <files>                 Optional subset of files to download. Defaults to the
                          whole repo.

OPTIONS:
  -s, --source <source>   Source registry (only 'hf' is supported today).
                          (default: hf)
  -o, --output <output>   Override staging directory root (default:
                          $STAGING_DIR or /tmp/acervo-staging).
  -t, --token <token>     HuggingFace token. Falls back to $HF_TOKEN when unset.
  --no-verify             Skip HuggingFace LFS SHA-256 verification (CHECK 1).
  --slug <slug>           Override the manifest's modelId with this slug
                          (single-component flow). The HF repo becomes
                          primaryRepo. Mutually exclusive with --spec.
  --spec <spec>           Path to a JSON spec file with
                          modelId/primaryRepo/components. Live mode iterates
                          components; --dry-run generates one manifest per
                          component. Mutually exclusive with the positional
                          modelId and --slug.
  --output-dir <output-dir>
                          Destination directory for --dry-run manifest files.
                          Defaults to a unique tempdir under
                          NSTemporaryDirectory().
  -b, --bucket <bucket>   R2 bucket name. Defaults to $R2_BUCKET environment
                          variable.
  -p, --prefix <prefix>   Key prefix for uploaded objects (default: 'models/').
                          (default: models/)
  --endpoint <endpoint>   R2 endpoint URL. Defaults to $R2_ENDPOINT environment
                          variable.
  --dry-run               Generate manifest(s) into --output-dir (or a tempdir)
                          without contacting HF or the CDN. Skips ToolCheck, HF
                          download, credential resolution, and PublishRunner.
  --force                 Reserved flag retained for argv compatibility with
                          the pre-v0.14.x shell-out pipeline. The native
                          publish path always uploads exactly the manifest's
                          file set, so this flag is a no-op today.
  --keep-orphans          Skip the orphan-prune step. By default, keys on the
                          CDN not referenced by the new manifest are deleted.
  -q, --quiet             Suppress the download/upload progress bar and
                          subprocess output. Errors still print.
  --version               Show the version.
  -h, --help              Show help information.

```

---

## `acervo manifest`

```
OVERVIEW: Generate a CDN manifest.json for a local model directory.

Scans <directory>, computes SHA-256 for every file, and writes
manifest.json alongside the model files (CHECK 2 + CHECK 3):

  CHECK 2  Refuses to write a manifest if any file is zero bytes.
  CHECK 3  Re-reads manifest.json after writing and verifies its checksum.

Prints the absolute path to the written manifest.json on stdout.

EXAMPLES
  acervo manifest mlx-community/Qwen2.5-7B-Instruct-4bit \
    /tmp/acervo-staging/mlx-community_Qwen2.5-7B-Instruct-4bit

USAGE: acervo manifest <model-id> <directory> [--quiet]

ARGUMENTS:
  <model-id>              HuggingFace model identifier in 'org/repo' form.
  <directory>             Local directory whose contents should be enumerated
                          into a manifest.

OPTIONS:
  -q, --quiet             Suppress the download/upload progress bar and
                          subprocess output. Errors still print.
  --version               Show the version.
  -h, --help              Show help information.

```

---

## `acervo verify`

```
OVERVIEW: Verify a local or CDN-hosted model against its manifest.

Two modes depending on whether <directory> is supplied:

LOCAL MODE (with <directory>)
  Regenerates a fresh manifest from the directory and re-hashes every
  file to confirm nothing has changed since the manifest was written.
  Exits non-zero and lists all mismatches.

CDN MODE (without <directory>)
  Resolves the staging directory from $STAGING_DIR, fetches the
  authoritative manifest.json from the CDN (CHECK 5), and verifies
  every local file against the CDN manifest. Useful for auditing a
  staging tree against what was previously published.

OPTIONAL ENVIRONMENT VARIABLES (CDN mode only)
  R2_PUBLIC_URL   Public CDN base URL (default:
https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev)
  STAGING_DIR     Staging root (default: /tmp/acervo-staging)

EXAMPLES
  # Local mode: verify staged files match the manifest
  acervo verify mlx-community/Qwen2.5-7B-Instruct-4bit \
    /tmp/acervo-staging/mlx-community_Qwen2.5-7B-Instruct-4bit

  # CDN mode: compare staging directory against live CDN manifest
  acervo verify mlx-community/Qwen2.5-7B-Instruct-4bit

USAGE: acervo verify <model-id> [<directory>] [--quiet]

ARGUMENTS:
  <model-id>              HuggingFace model identifier in 'org/repo' form.
  <directory>             Local directory to verify; omit to use staging
                          directory

OPTIONS:
  -q, --quiet             Suppress the download/upload progress bar and
                          subprocess output. Errors still print.
  --version               Show the version.
  -h, --help              Show help information.

```

---

## `acervo delete`

```
OVERVIEW: Delete a model from local cache, staging directory, and/or CDN.

At least one of --local / --staging / --cache / --cdn is required.

SCOPES
  --local      Implies both --staging and --cache.
  --staging    Removes $STAGING_DIR/<slug> (the directory used by
               `acervo download` / `acervo recache`).
  --cache      Removes the model from the shared App Group cache
               (~/Library/Group Containers/<group>/SharedModels/<slug>).
               Equivalent to calling `Acervo.deleteModel(_:)` from a
               library consumer.
  --cdn        Removes every object under models/<slug>/ from R2.
               Destructive. Prompts on a TTY; requires --yes off-TTY.

OPTIONS
  --dry-run    Print the actions that would be taken; perform none.
  --yes        Bypass the TTY confirmation prompt for --cdn.

REQUIRED FOR --cdn
  R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ENDPOINT, R2_PUBLIC_URL
  R2_BUCKET (optional; defaults to intrusive-memory-models)

EXAMPLES
  acervo delete mlx-community/Qwen2.5-7B-Instruct-4bit --local
  acervo delete mlx-community/Qwen2.5-7B-Instruct-4bit --staging --dry-run
  acervo delete mlx-community/Qwen2.5-7B-Instruct-4bit --cdn --yes

USAGE: acervo delete <model-id> [--local] [--staging] [--cache] [--cdn] [--dry-run] [--yes] [--bucket <bucket>] [--endpoint <endpoint>] [--quiet]

ARGUMENTS:
  <model-id>              Model identifier in 'org/repo' form.

OPTIONS:
  --local                 Implies --staging and --cache.
  --staging               Delete the staging directory copy.
  --cache                 Delete the App Group cache copy.
  --cdn                   Delete from the CDN. Destructive.
  --dry-run               Print intended actions without performing them.
  --yes                   Bypass TTY confirmation prompts.
  -b, --bucket <bucket>   R2 bucket override (otherwise uses $R2_BUCKET).
  --endpoint <endpoint>   R2 endpoint override (otherwise uses $R2_ENDPOINT).
  -q, --quiet             Suppress the download/upload progress bar and
                          subprocess output. Errors still print.
  --version               Show the version.
  -h, --help              Show help information.

```

---

## `acervo recache`

```
OVERVIEW: Re-fetch a model from HuggingFace and atomically republish it to the
CDN.

Pipeline (per REQUIREMENTS-delete-and-recache.md §6.4 / §7):

  1. Run `hf download <modelId>` into the staging directory.
  2. Hand the staging directory to Acervo.publishModel:
       - Generate manifest.json (CHECKs 2 + 3).
       - Re-hash every staged file against the manifest (CHECK 4).
       - List existing CDN keys under models/<slug>/.
       - PUT every file; PUT manifest.json LAST.
       - Re-fetch the manifest from the public URL (CHECK 5).
       - Re-fetch one file from the public URL (CHECK 6).
       - Delete orphan keys (unless --keep-orphans).

The manifest is the LAST PUT, so if any step before that fails the
old manifest still references the prior version's complete file set
and consumers see no disruption.

REQUIRED ENVIRONMENT VARIABLES
  HF_TOKEN               HuggingFace token (or pass --token)
  R2_ACCESS_KEY_ID       Cloudflare R2 access key
  R2_SECRET_ACCESS_KEY   Cloudflare R2 secret key
  R2_ENDPOINT            R2 S3-compatible endpoint URL
  R2_PUBLIC_URL          Public CDN base URL used by CHECKs 5 + 6

OPTIONAL ENVIRONMENT VARIABLES
  R2_BUCKET              Bucket name (default: intrusive-memory-models)
  R2_REGION              Region (default: auto)
  STAGING_DIR            Staging root (default: /tmp/acervo-staging)

EXAMPLES
  acervo recache mlx-community/Qwen2.5-7B-Instruct-4bit
  acervo recache mlx-community/Qwen2.5-7B-Instruct-4bit --keep-orphans
  acervo recache mlx-community/Qwen2.5-7B-Instruct-4bit --yes  # required for
non-TTY

USAGE: acervo recache <model-id> [<files> ...] [--output <output>] [--token <token>] [--bucket <bucket>] [--endpoint <endpoint>] [--keep-orphans] [--yes] [--quiet]

ARGUMENTS:
  <model-id>              HuggingFace model identifier in 'org/repo' form.
  <files>                 Optional subset of files to download. Defaults to the
                          whole repo.

OPTIONS:
  -o, --output <output>   Override staging directory root (default:
                          $STAGING_DIR or /tmp/acervo-staging).
  -t, --token <token>     HuggingFace token. Falls back to $HF_TOKEN when unset.
  -b, --bucket <bucket>   R2 bucket override (otherwise uses $R2_BUCKET).
  --endpoint <endpoint>   R2 endpoint override (otherwise uses $R2_ENDPOINT).
  --keep-orphans          Skip the orphan-prune step. By default, keys on the
                          CDN not referenced by the new manifest are deleted.
  --yes                   Bypass the orphan-prune confirmation prompt. Required
                          for non-TTY (CI) runs that prune.
  -q, --quiet             Suppress the download/upload progress bar and
                          subprocess output. Errors still print.
  --version               Show the version.
  -h, --help              Show help information.

```

---

## Regenerating

This document is mechanically captured from the binary. After any CLI change:

```bash
make install-acervo  # rebuild from source
# then re-run the capture block at the head of this file's commit
```

Companion library reference: [`USAGE-library.md`](./USAGE-library.md).
