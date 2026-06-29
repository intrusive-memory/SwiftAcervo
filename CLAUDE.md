---
type: project
updated: 2026-06-25
---

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with SwiftAcervo.

## Quick Reference

**Project**: SwiftAcervo - Shared AI model discovery and management

**Version**: 0.22.0-dev

**Platforms**: iOS 26.0+, macOS 26.0+

**Key Components**:
- Static `Acervo` API for model path resolution, discovery, and download
- `AcervoManager` actor for thread-safe operations with per-model locking
- CDN-only downloads with per-file SHA-256 manifest verification
- `SecureDownloadSession` that rejects redirects to non-CDN domains
- Component registry for declarative model component management, with v0.8.0 bare `ComponentDescriptor.init(id:type:displayName:repoId:minimumMemoryBytes:metadata:)` for un-hydrated registration
- `Acervo.hydrateComponent(_:)` / `Acervo.ensureComponentReady(_:)` for manifest-driven descriptor population (auto-hydrate on first use)
- `Acervo.fetchManifest(for: modelId)` and `Acervo.fetchManifest(forComponent: componentId)` for raw manifest access without downloads
- `LocalHandle` / `withLocalAccess(_:perform:)` for scoped access to caller-supplied local paths
- Migration utility for legacy `intrusive-memory/Models/` cache paths
- CDN mutation API: `Acervo.publishModel(modelId:directory:credentials:keepOrphans:progress:)`, `Acervo.deleteFromCDN(modelId:credentials:progress:)`, `Acervo.recache(modelId:stagingDirectory:credentials:fetchSource:keepOrphans:progress:)` — native SigV4 path, no `aws` CLI
- `HuggingFaceClient` (library, `SwiftAcervo`): native HuggingFace API client (tree enumeration, LFS/size verification, and `downloadRepo(...)` byte fetch via the `resolve` endpoint). Pure Foundation, no Python `hf`/`hf_xet`, works on iOS and macOS.
- `SafetensorsResharder` (library, `SwiftAcervo`): `SafetensorsResharder.reshard(directory:maxShardBytes:verify:)` losslessly re-splits over-cap safetensors into ≤256 MiB CDN-edge-cacheable shards (pure Foundation+CryptoKit byte copy; int4/fp16/bf16 pass through untouched). Operates per directory/sub-folder, emits the HF-standard `<stem>.safetensors.index.json`, and SHA-256 round-trip-verifies byte-identity before swapping the originals in place. `acervo ship` runs it automatically **after** download and **before** manifest generation; `--max-shard-mib` overrides the cap, `--no-reshard` disables it. No-op when every weight file is already under the cap.
- Refetch-from-source: `Acervo.recacheFromHuggingFace(modelId:stagingDirectory:credentials:slug:files:revision:...)` — wires the native fetch into the publish pipeline. One HF repo → one CDN slug. Flux2 (N:1 bundle) needs `slug:` to rename `black-forest-labs/FLUX.2-klein-4B` → `flux2-klein-4b`; PixArt (1:1 per-component) makes one call per repo.
- `acervo` CLI tool for CDN upload, manifest generation, and HuggingFace download. Still shells out to the Python `hf` CLI for the actual transfer (the native `downloadRepo` is available in the library but the CLI has not been rewired onto it).

**Critical Rules**:
- ONLY supports iOS 26.0+ and macOS 26.0+ (NEVER add code for older platforms)
- Zero external dependencies (Foundation + CryptoKit only)
- All downloads go through the private R2 CDN
- The CDN base URL is **consumer-supplied with no hardcoded default** — set via `ACERVO_CDN_BASE_URL` (CLI/tests/CI) or the `AcervoCDNBaseURL` Info.plist key (UI apps); a missing/malformed value traps with `fatalError`. See [Docs/CDN_CONFIGURATION.md](Docs/CDN_CONFIGURATION.md).
- `config.json` presence is the universal model validity marker
- Canonical path: `~/Library/Group Containers/<group-id>/SharedModels/{org}_{repo}/`. The group ID is supplied per-consumer via `com.apple.security.application-groups` entitlement (UI apps) or the `ACERVO_APP_GROUP_ID` environment variable (CLIs/tests). No fallback — `Acervo.sharedModelsDirectory` traps with `fatalError` if neither source is configured.
- Manifest-first file selection: consumers do not know what files exist until the CDN manifest returns; the manifest is the sole authoritative source, and names not in it throw `AcervoError.fileNotInManifest`.

---

## Where to find things

The repo ships three surfaces, each with its own reference document:

- **[Docs/USAGE-library.md](Docs/USAGE-library.md)** — Library reference. Compiled from `Sources/SwiftAcervo/*.swift`. Every public symbol with signature + usage example. Read this before suggesting changes to the public API or before answering "how do I use SwiftAcervo from my app/library".
- **[Docs/USAGE-cli.md](Docs/USAGE-cli.md)** — CLI reference. Captured from `acervo --help` plus every subcommand. Read this before suggesting changes to CLI behavior or before answering "how do I run acervo".
- **[Docs/USAGE-ui-components.md](Docs/USAGE-ui-components.md)** — SwiftAcervoUI reference. Documents the SwiftUI drop-in components (`AcervoModelsList`, etc.) and the SwiftData-backed `StoredModelReference` persistence scaffold. Compiled from `Sources/SwiftAcervoUI/*.swift`. Read this before suggesting changes to the UI module or before answering "how do I show a models list in my app".

Topic-specific docs (architectural background, not consumer entry points):

- **[Docs/DESIGN_PATTERNS.md](Docs/DESIGN_PATTERNS.md)** — Static+Actor, streaming SHA-256, per-model locking, atomic downloads.
- **[Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md)** — Ecosystem dependency map, interface contracts.
- **[Docs/CDN_ARCHITECTURE.md](Docs/CDN_ARCHITECTURE.md)** — How downloads work, verification, security properties.
- **[Docs/PROJECT_STRUCTURE.md](Docs/PROJECT_STRUCTURE.md)** — File organization, module layout, test structure.
- **[Docs/SHARED_MODELS_DIRECTORY.md](Docs/SHARED_MODELS_DIRECTORY.md)** — Where models live on disk, directory structure.
- **[Docs/CONTRIBUTING.md](Docs/CONTRIBUTING.md)** — Contribution process.

---

## Quick Commands

**Common Make targets** (preferred over raw xcodebuild):

```bash
make build              # Build the library
make test               # Run all tests
make install-acervo     # Build and install CLI to bin/
```

**acervo CLI** (see [Docs/USAGE-cli.md](Docs/USAGE-cli.md) for full reference):

```bash
acervo ship org/repo                          # Download from HF and mirror to CDN
acervo ship org/repo --slug my-slug           # As above, but rename in CDN
acervo ship --spec spec.json                  # Multi-component upload
acervo ship --spec spec.json --dry-run        # Generate manifest only, no network
acervo download org/repo                      # HF → local staging
acervo verify org/repo                        # Re-hash and check against manifest
acervo delete org/repo --local                # Clean local cache
```

---

## Important: This library does NOT load models

SwiftAcervo finds and downloads models. Loading (inference) is the consumer's job:
- SwiftBruja loads with MLX
- mlx-audio-swift loads with MLX
- Your library loads with your framework

This separation keeps SwiftAcervo lightweight and framework-agnostic.
