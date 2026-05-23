---
updated: 2026-05-18
---

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with SwiftAcervo.

## Quick Reference

**Project**: SwiftAcervo - Shared AI model discovery and management

**Version**: 0.15.0

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
- `acervo` CLI tool for CDN upload, manifest generation, and HuggingFace download (thin wrapper around the library API)

**Critical Rules**:
- ONLY supports iOS 26.0+ and macOS 26.0+ (NEVER add code for older platforms)
- Zero external dependencies (Foundation + CryptoKit only)
- All downloads go through the private R2 CDN
- `config.json` presence is the universal model validity marker
- Canonical path: `~/Library/Group Containers/<group-id>/SharedModels/{org}_{repo}/`. The group ID is supplied per-consumer via `com.apple.security.application-groups` entitlement (UI apps) or the `ACERVO_APP_GROUP_ID` environment variable (CLIs/tests). No fallback — `Acervo.sharedModelsDirectory` traps with `fatalError` if neither source is configured.
- Manifest-first file selection: consumers do not know what files exist until the CDN manifest returns; the manifest is the sole authoritative source, and names not in it throw `AcervoError.fileNotInManifest`.

---

## For Different Users

### 🎯 **Consuming Libraries** (Most Users)

**Start here** if you're adding SwiftAcervo to your app or library:

- **[USAGE.md](Docs/USAGE.md)** — Integration guide, examples, common patterns, FAQ
  - Quick start (add to Package.swift)
  - Integration checklist
  - Real-world examples (SwiftBruja, mlx-audio-swift, SwiftVoxAlta)
  - Error handling and best practices
  - **Read this first!**

### 📚 **API Documentation**

Complete reference for all methods and types:

- **[API_REFERENCE.md](Docs/API_REFERENCE.md)** — All Acervo and AcervoManager methods, types, error handling
- **[SHARED_MODELS_DIRECTORY.md](Docs/SHARED_MODELS_DIRECTORY.md)** — Where models are stored, directory structure, migration

### 🛠️ **Building and Testing**

For developers building SwiftAcervo itself or using the CLI:

- **[BUILD_AND_TEST.md](Docs/BUILD_AND_TEST.md)** — Make targets, acervo CLI tool, unit/integration tests, CI/CD

### 🌐 **CDN Operations**

For uploading models to the CDN:

- **[CDN_UPLOAD.md](Docs/CDN_UPLOAD.md)** — Full pipeline (`acervo ship`), step-by-step commands, environment variables
- **[CDN_ARCHITECTURE.md](Docs/CDN_ARCHITECTURE.md)** — How downloads work, verification, security properties

### 🏗️ **Architecture & Design**

For understanding the system:

- **[DESIGN_PATTERNS.md](Docs/DESIGN_PATTERNS.md)** — Core patterns (Static+Actor, streaming SHA-256, per-model locking, atomic downloads)
- **[PROJECT_STRUCTURE.md](Docs/PROJECT_STRUCTURE.md)** — File organization, module layout, test structure
- **[ARCHITECTURE.md](Docs/ARCHITECTURE.md)** — Ecosystem dependency map, interface contracts

### 📖 **User Documentation**

- **[README.md](README.md)** — High-level overview, quick start, installation
- **[CONTRIBUTING.md](Docs/CONTRIBUTING.md)** — Development guidelines and contribution process

---

## Quick Commands

**Common Make targets** (preferred over raw xcodebuild):

```bash
make build              # Build the library
make test               # Run all tests
make install-acervo     # Build and install CLI to bin/
```

**acervo CLI** (for CDN operations):

```bash
acervo ship --model-id "org/repo"     # Full pipeline: download, manifest, verify, upload
acervo download --model-id "org/repo" # Download from HuggingFace only
acervo manifest --model-id "org/repo" # Generate manifest.json
acervo verify --model-id "org/repo"   # Verify all integrity checks
acervo upload --model-id "org/repo"   # Upload to R2 CDN
```

See [BUILD_AND_TEST.md](Docs/BUILD_AND_TEST.md) for full details.

---

## Important: This library does NOT load models

SwiftAcervo finds and downloads models. Loading (inference) is the consumer's job:
- SwiftBruja loads with MLX
- mlx-audio-swift loads with MLX
- Your library loads with your framework

This separation keeps SwiftAcervo lightweight and framework-agnostic.

---

## See AGENTS.md for:

- Complete API overview (all methods in one place)
- ModelDownloadManager for batch downloads
- Design patterns and architectural decisions
- Platform requirements
- Dependencies and build notes

[AGENTS.md](AGENTS.md) is a comprehensive reference. For specific questions, use the docs above.
