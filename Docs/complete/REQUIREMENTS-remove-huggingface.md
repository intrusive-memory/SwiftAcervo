# Requirements: Remove HuggingFace References

**Status**: APPROVED
**Date**: 2026-03-29
**Scope**: Rename all HuggingFace-specific naming throughout the codebase to reflect that SwiftAcervo is an Intrusive Memory CDN-only library. No functional changes — this is a naming/documentation cleanup.

---

## Motivation

SwiftAcervo no longer downloads from HuggingFace. All downloads go through the private Cloudflare R2 CDN (`pub-8e049ed02be340cbb18f921765fd24f3.r2.dev`). Direct HuggingFace support was removed in commit `094848c`, but ~200 references to "HuggingFace" remain in property names, comments, docs, and tests. This is misleading — the library is Intrusive Memory CDN-only.

The `org/repo` model ID format stays. It's a useful convention for namespacing models that happens to originate from HuggingFace, but it's just a string format.

---

## Changes

### 1. Rename `huggingFaceRepo` → `repoId` (source + tests)

**Files**: `ComponentDescriptor.swift`, `ComponentRegistry.swift`, `Acervo.swift`, `AcervoManager.swift`, and all test files that reference the property.

| Before | After |
|--------|-------|
| `public let huggingFaceRepo: String` | `public let repoId: String` |
| `/// The HuggingFace repository this component is downloaded from` | `/// The CDN repository identifier (e.g., "intrusive-memory/t5-xxl-int4-mlx").` |
| `huggingFaceRepo: descriptor.huggingFaceRepo` | `repoId: descriptor.repoId` |
| Parameter labels in `init(... huggingFaceRepo:)` | `init(... repoId:)` |

This is a **public API breaking change**. Consumers must update call sites.

### 2. Update doc comments referencing HuggingFace in source files

Replace "HuggingFace model identifier", "HuggingFace model ID", "HuggingFace repository", etc. with neutral language.

**Key files**:
- `Acervo.swift` — file header, `slugify()` docs, `modelDirectory()` docs, `isModelAvailable()` docs, `download()` docs, all `@param modelId` descriptions
- `AcervoManager.swift` — all `@param modelId` descriptions referencing "HuggingFace model identifier"
- `AcervoModel.swift` — struct doc comment, `id` property doc
- `AcervoDownloader.swift` — subsystem identifier is fine (`com.intrusive-memory.SwiftAcervo`)
- `ComponentDescriptor.swift` — struct doc comment, property docs
- `ComponentRegistry.swift` — deduplication warning string

**Replacement language**:
| Before | After |
|--------|-------|
| "HuggingFace model identifier" | "model identifier" or "model ID" |
| "HuggingFace model ID" | "model ID" |
| "HuggingFace repository" | "CDN repository" or "model repository" |
| "A HuggingFace model identifier in `org/repo` format" | "A model identifier in `org/repo` format" |
| "downloads from HuggingFace" | "downloads from the CDN" |
| "HuggingFace repo structure" | "repository directory structure" |

### 3. Remove dead HuggingFace test code in `IntegrationTests.swift`

The integration test file contains tests for `buildRequest(from:token:)` with Bearer token injection — a method that no longer exists in the public API:

- `@Test("buildRequest includes Bearer token in Authorization header")` — **delete**
- `@Test("buildRequest omits Authorization header when token is nil")` — **delete**
- Token special character test — **delete**
- Any test constructing `https://huggingface.co/...` URLs — **delete**
- Suite name `"Integration: Real HuggingFace Downloads"` → `"Integration: Real CDN Downloads"`
- Comment about "real HuggingFace" → "real CDN"

### 4. Update `Tools/upload-model.sh`

This script still uses `huggingface-cli` to pull models before uploading to R2. That's the actual workflow (HF is the upstream source for the operator, not the library consumer). Keep the script functional but update its framing:

- Script description: "Downloads a model from its upstream source, generates a manifest, and uploads to the Intrusive Memory CDN."
- Keep `HF_TOKEN`, `huggingface-cli` usage — these are operator tools, not library concerns
- Add a comment: `# Note: HuggingFace is the upstream model source for operators. The SwiftAcervo library itself only downloads from the CDN.`

### 5. Update documentation files

#### README.md
- Line 3: "Shared AI model discovery and management for HuggingFace models on Apple platforms." → "Shared AI model discovery and management for Apple platforms."
- Line 5: Remove "HuggingFace" from the elevator pitch
- Line 43/85: "No HuggingFace Hub library" → "No external model hub libraries" (keep the zero-dependency messaging)
- Line 126: "Model names from HuggingFace are long" → "Model names are long"
- Line 262: "`huggingFaceRepo: String`" → "`repoId: String`"
- Line 523: "Integration tests that hit the HuggingFace network" → "Integration tests that hit the CDN"
- All code examples: update `huggingFaceRepo:` → `repoId:` in any inline Swift

#### CLAUDE.md
- Line 29: "never HuggingFace directly" → remove the HuggingFace contrast; just say "All downloads go through the private R2 CDN"

#### AGENTS.md
- Line 13: "The library never contacts HuggingFace directly." → "All downloads are CDN-only."
- Line 51: "Full HuggingFace → manifest → R2 upload workflow" → "Full upstream → manifest → R2 upload workflow"
- Line 131: "never HuggingFace" → remove contrast
- Line 169: "download from HuggingFace" → "download from upstream source"
- Line 181: "NOT a HuggingFace client" → "Downloads exclusively from private CDN"

#### REQUIREMENTS.md
- All references to "Download from HuggingFace" → "Download from CDN"
- `huggingFaceRepo` → `repoId` in code examples
- "HuggingFace URLs" / "HuggingFace repo" → neutral language

#### ARCHITECTURE.md
- `huggingFaceRepo` → `repoId` in code examples

#### CONTRIBUTING.md
- Line 39: "Integration tests that download from HuggingFace" → "Integration tests that download from the CDN"

#### GEMINI.md
- No HuggingFace references found; no changes needed.

### 6. Update `.claude/skills/update-cdn-model.md`

- Description: remove "Downloads from HuggingFace" framing
- Keep the actual `huggingface-cli` instructions (they're correct for the operator workflow)
- Clarify the distinction: "This skill manages the operator-side upload pipeline. The library itself only downloads from CDN."

### 7. Archive files — no changes

`Docs/archive/REQUIREMENTS_V1.md` and `Docs/EXECUTION_PLAN-swift-acervo-INCOMPLETE-*.md` are historical records. Do not modify them.

`TASK_LIST.md` and `Docs/complete/EXECUTION_PLAN.md` are completed planning artifacts. Do not modify them.

---

## Out of Scope

- **`org/repo` model ID format**: Stays as-is. It's a useful namespacing convention, not a HuggingFace dependency.
- **`intrusive-memory` org name in model IDs**: These are real CDN model identifiers, not HuggingFace references.
- **`mlx-community` in test model IDs**: These are valid `org/repo` strings for testing slugification and path resolution. They don't imply HuggingFace connectivity. Keep them.
- **`group.intrusive-memory.models` App Group**: Infrastructure, not a HuggingFace reference.
- **`Tools/upload-model.sh` functional changes**: The script correctly uses `huggingface-cli` as an operator tool. Don't remove that functionality.
- **Functional/behavioral changes**: This is purely naming and documentation. No download logic, URL construction, verification, or error handling changes.

---

## Verification

1. **Build**: `xcodebuild build` succeeds with zero warnings about the rename
2. **Tests**: All existing tests pass (property rename is mechanical — find/replace + compile)
3. **Grep check**: `grep -ri "huggingface" Sources/` returns zero results
4. **Grep check**: `grep -ri "huggingface" Tests/` returns zero results (except test model ID strings like `"mlx-community/..."` which are fine)
5. **Doc grep**: `grep -ri "hugging" README.md CLAUDE.md AGENTS.md REQUIREMENTS.md ARCHITECTURE.md CONTRIBUTING.md` returns zero results
