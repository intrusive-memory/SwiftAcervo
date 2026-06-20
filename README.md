# SwiftAcervo

Manifest-driven shared AI model discovery, download, and verification for iOS 26.0+ and macOS 26.0+. Zero external dependencies (Foundation + CryptoKit only).

This repository ships three things:

## Library

A Swift package that consuming apps and libraries add as a dependency to discover, download, and verify shared AI models from a private CDN. The full reference is at **[Docs/USAGE-library.md](Docs/USAGE-library.md)** — that document is compiled from the public API surface in `Sources/SwiftAcervo/` and is the source of truth for how to integrate SwiftAcervo.

## CLI

`acervo`, a command-line tool for operator-side workflows: listing what is on the CDN, downloading models from HuggingFace, generating CDN manifests, uploading to R2, verifying integrity, and managing local cache. The full reference is at **[Docs/USAGE-cli.md](Docs/USAGE-cli.md)** — that document is the captured `acervo --help` output for every subcommand.

```bash
acervo list                                   # List model directories on the CDN
acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit   # Download from HF and mirror to CDN
acervo download mlx-community/Qwen2.5-7B-Instruct-4bit
acervo verify mlx-community/Qwen2.5-7B-Instruct-4bit
acervo delete mlx-community/Qwen2.5-7B-Instruct-4bit --local --cdn --yes
```

`acervo list` is a plain inventory: it prints one slug per line for every directory under `models/` in the bucket, sorted, and makes no claim about whether each model is complete or valid (that is what `acervo verify` is for).

### Environment variables

`acervo` reads all of its credentials and paths from the environment (the library never reads them itself):

| Variable | Required for | Default | Purpose |
| --- | --- | --- | --- |
| `HF_TOKEN` | private/gated HF downloads | — | HuggingFace API token (or pass `--token`) |
| `R2_ACCESS_KEY_ID` | `list`, `upload`, `ship`, `recache`, `delete --cdn` | — | R2 access key id |
| `R2_SECRET_ACCESS_KEY` | CDN operations | — | R2 secret access key |
| `R2_ENDPOINT` | CDN operations | — | R2 S3-compatible API endpoint (signed writes + listing) |
| `R2_PUBLIC_URL` | CDN operations | — | Public CDN base URL (readback verification) |
| `R2_BUCKET` | optional | `intrusive-memory-models` | Bucket name |
| `R2_REGION` | optional | `auto` | Region literal |
| `STAGING_DIR` | optional | `/tmp/acervo-staging` | Staging root for `download` / `recache` |
| `ACERVO_APP_GROUP_ID` | cache-scoped ops | — | App Group id locating the shared models directory |
| `ACERVO_MODELS_DIR` | optional | — | Absolute override for the shared models directory (takes precedence over the App Group) |
| `ACERVO_OFFLINE` | optional | — | When set (e.g. `=1`), forbid all network access; serve only on-disk content |

## UI Components

`SwiftAcervoUI`, a thin SwiftUI layer with drop-in components (`AcervoModelsList` and friends) for managing on-device models, plus a SwiftData-backed `StoredModelReference` persistence scaffold. The full reference is at **[Docs/USAGE-ui-components.md](Docs/USAGE-ui-components.md)** — compiled from `Sources/SwiftAcervoUI/`.

---

License: see [LICENSE](LICENSE). Contributing: see [Docs/CONTRIBUTING.md](Docs/CONTRIBUTING.md).
