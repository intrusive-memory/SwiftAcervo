# SwiftAcervo CDN Upload Pattern — Standardization

**Status**: DRAFT — Establishing consuming library ownership of model CDN uploads  
**Date**: 2026-04-18  
**Scope**: All libraries depending on SwiftAcervo

---

## Pattern Summary

**Rule**: Each library that depends on SwiftAcervo **owns** the CDN copy of its models.

- ✅ **Consuming libraries** (SwiftProyecto, SwiftBruja, mlx-audio-swift, SwiftVoxAlta, etc.)
  - Establish and maintain CDN copies of models they use
  - Midnight CI job: download from HuggingFace → compute SHA-256 → upload to CDN
  - Homebrew-installed SwiftAcervo used for download + hash validation
  - macOS-26 runner (consistent with all Claude global standards)
  - CDN credentials via GitHub organization secrets

- ❌ **SwiftAcervo itself** (the framework/library)
  - Does NOT upload any models
  - Provides only the ComponentDescriptor API and Acervo.ensureComponentReady()
  - Consuming libraries use Acervo to download and cache

---

## Current State Audit

| Library | Models | CDN Workflow | Status |
|---------|--------|----------|--------|
| **SwiftAcervo** | N/A (framework) | ❌ MUST NOT HAVE | Remove if exists |
| **SwiftProyecto** | Phi-3 (2.3 GB) | ✅ ensure-model-cdn.yml | COMPLIANT |
| **SwiftBruja** | Qwen3 (44 GB, 9 shards) | ✅ ensure-model-cdn.yml | COMPLIANT |
| **mlx-audio-swift** | SNAC, Mimi, TTS (1.5+ GB) | ✅ ensure-model-cdn.yml | COMPLIANT |
| **SwiftVoxAlta** | 7 TTS (Qwen3, Kokoro, Piper, etc.) | ❌ MISSING | NEEDS SETUP |
| **SwiftEchada** | TTS delegation (uses SwiftVoxAlta models) | ❌ MISSING | NEEDS SETUP |
| **SwiftTuberia** | Pipeline infrastructure (model-agnostic) | ❌ N/A | RESEARCH ONLY |
| **SwiftVinetas** | Image generation (Flux2, PixArt) | ❌ MISSING | NEEDS SETUP |

---

## Standardized Midnight CI Job Template

Every consuming library with models should implement this pattern in `.github/workflows/ensure-model-cdn.yml`:

```yaml
name: Ensure Model on CDN (Midnight)

on:
  schedule:
    # Midnight UTC every day
    - cron: '0 0 * * *'
  workflow_dispatch:

jobs:
  ensure-model-cdn:
    name: Upload Model to CDN
    runs-on: macos-26
    timeout-minutes: 240

    env:
      # Must match ComponentDescriptor ID in ModelManager.swift
      MODEL_ID: "your-model-id"
      MODEL_REPO: "mlx-community/Your-Model-Name"
      MODEL_SLUG: "mlx-community_Your-Model-Name"
      
      # CDN configuration (from GitHub org secrets)
      CDN_BASE: ${{ secrets.CDN_BASE_URL }}
      R2_BUCKET: ${{ secrets.R2_BUCKET }}
      R2_ACCOUNT_ID: ${{ secrets.R2_ACCOUNT_ID }}
      R2_ACCESS_KEY_ID: ${{ secrets.R2_ACCESS_KEY_ID }}
      R2_SECRET_ACCESS_KEY: ${{ secrets.R2_SECRET_ACCESS_KEY }}

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Install SwiftAcervo via Homebrew
        run: |
          brew tap intrusive-memory/tools
          brew install swiftacervo
          swiftacervo --version

      - name: Check if manifest exists on CDN
        id: check-manifest
        run: |
          HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
            "${{ env.CDN_BASE }}/models/${{ env.MODEL_SLUG }}/manifest.json")
          echo "status=$HTTP_STATUS" >> $GITHUB_OUTPUT
          if [ "$HTTP_STATUS" = "200" ]; then
            echo "Model manifest already on CDN — skipping upload"
          else
            echo "Model manifest not found — will download and upload"
          fi

      - name: Download model files from HuggingFace
        if: steps.check-manifest.outputs.status != '200'
        run: |
          set -euo pipefail
          mkdir -p /tmp/model_download/${{ env.MODEL_SLUG }}
          cd /tmp/model_download/${{ env.MODEL_SLUG }}
          
          # Download all model files
          swiftacervo download \
            --repo ${{ env.MODEL_REPO }} \
            --output . \
            --verify-checksums

      - name: Generate manifest with SHA-256
        if: steps.check-manifest.outputs.status != '200'
        run: |
          set -euo pipefail
          cd /tmp/model_download/${{ env.MODEL_SLUG }}
          
          # Generate manifest.json with SHA-256 for all files
          swiftacervo manifest generate \
            --model-id ${{ env.MODEL_ID }} \
            --model-repo ${{ env.MODEL_REPO }} \
            --output manifest.json

      - name: Upload to R2 CDN
        if: steps.check-manifest.outputs.status != '200'
        run: |
          set -euo pipefail
          cd /tmp/model_download/${{ env.MODEL_SLUG }}
          
          # Upload manifest + all model files
          swiftacervo upload \
            --bucket ${{ env.R2_BUCKET }} \
            --account-id ${{ env.R2_ACCOUNT_ID }} \
            --access-key-id ${{ env.R2_ACCESS_KEY_ID }} \
            --secret-access-key ${{ env.R2_SECRET_ACCESS_KEY }} \
            --model-slug ${{ env.MODEL_SLUG }} \
            --manifest manifest.json

      - name: Verify upload
        if: steps.check-manifest.outputs.status != '200'
        run: |
          set -euo pipefail
          
          # Download and verify checksums from CDN
          swiftacervo verify \
            --cdn-base ${{ env.CDN_BASE }} \
            --model-slug ${{ env.MODEL_SLUG }} \
            --manifest-path /tmp/model_download/${{ env.MODEL_SLUG }}/manifest.json

      - name: Notify on success
        run: echo "✅ Model ${{ env.MODEL_SLUG }} verified on CDN"

      - name: Notify on failure
        if: failure()
        run: |
          echo "❌ CDN upload failed for ${{ env.MODEL_SLUG }}"
          exit 1
```

---

## Implementation Checklist

For each library implementing the pattern:

### 1. Identify Models
- [ ] List all models the library uses
- [ ] Get HuggingFace repo IDs
- [ ] Estimate total size
- [ ] Determine download strategy (single file vs. sharded)

### 2. Create ComponentDescriptor
- [ ] Create `Sources/Library/Infrastructure/ModelManager.swift`
- [ ] Register each model with `ComponentDescriptor`
- [ ] Include file manifests with exact sizes and SHA-256
- [ ] Set `estimatedSizeBytes` and `minimumMemoryBytes`
- [ ] Use lazy module-level registration

### 3. Implement CDN Workflow
- [ ] Copy template to `.github/workflows/ensure-model-cdn.yml`
- [ ] Update MODEL_ID, MODEL_REPO, MODEL_SLUG
- [ ] Verify GitHub org secrets exist (CDN_BASE, R2_*, etc.)
- [ ] Test with `workflow_dispatch` trigger first
- [ ] Enable midnight schedule (`0 0 * * *`)
- [ ] Set timeout appropriate for model size (30 min for <5GB, 240 min for >10GB)

### 4. Integrate with Download Logic
- [ ] Update DownloadCommand to call `Acervo.ensureComponentReady(modelId)`
- [ ] Remove direct HuggingFace download code
- [ ] Add progress callback handling
- [ ] Implement error handling for Acervo failures

### 5. Update Documentation
- [ ] Add "Model Management" section to README
- [ ] Document ComponentDescriptor registration in AGENTS.md
- [ ] Update CHANGELOG with CDN migration
- [ ] Link to SwiftAcervo AGENTS.md for framework docs

### 6. Test
- [ ] Run integration tests with CDN download
- [ ] Verify model file integrity (SHA-256 checksums)
- [ ] Test cross-library model sharing (if applicable)
- [ ] Manual verification: library can load and use model from cache

---

## Libraries Needing Implementation

### Priority 1 (High-value, well-defined models)

**SwiftVoxAlta** — 7 TTS models  
- Models: Qwen3-TTS, Kokoro, Piper×8, LlamaSpeak
- Reference implementation already exists
- Action: Create `ensure-model-cdn.yml` following Phi-3 pattern

**SwiftEchada** — TTS delegation  
- Uses models from SwiftVoxAlta (via Qwen3-TTS primarily)
- Action: Either delegate to SwiftVoxAlta OR create own workflow for used TTS variants

### Priority 2 (Research/conditional)

**SwiftTuberia** — Pipeline infrastructure  
- No specific models (infrastructure layer)
- Model-specific packages (Flux2, PixArt) will have their own workflows
- Action: Document that SwiftTuberia is model-agnostic; model packages own uploads

**SwiftVinetas** — Image generation  
- Models: Flux2, PixArt
- Requires SwiftTuberia consolidation first
- Action: Defer until SwiftTuberia pattern established, then implement per-model workflows

---

## GitHub Organization Secrets (Required)

All libraries using the CDN workflow require these secrets at the organization level:

```
CDN_BASE_URL              = https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev
R2_BUCKET                 = intrusive-memory-audio (or similar)
R2_ACCOUNT_ID             = <Cloudflare account ID>
R2_ACCESS_KEY_ID          = <R2 API token ID>
R2_SECRET_ACCESS_KEY      = <R2 API token secret>
```

**Note**: These are organization-level secrets, shared across all repos.

---

## Validation & Rollout

### Phase 1: Current Libraries (Already Compliant)
- [x] SwiftProyecto (Phi-3)
- [x] SwiftBruja (Qwen3)
- [x] mlx-audio-swift (Audio codecs + TTS)

### Phase 2: Reference & Simple Cases
- [ ] SwiftVoxAlta (7 TTS — reference)
- [ ] SwiftEchada (TTS delegation)

### Phase 3: Complex/Deferred
- [ ] SwiftTuberia (infrastructure research)
- [ ] SwiftVinetas (after SwiftTuberia pattern)

---

## Rule Enforcement

**SwiftAcervo Repository**:
- [ ] Audit for any model upload workflows
- [ ] REMOVE if found
- [ ] Document in AGENTS.md that consuming libraries own CDN uploads
- [ ] Add to contributor guidelines

**Consuming Libraries**:
- [ ] MUST have `ensure-model-cdn.yml` if they use any models
- [ ] MUST NOT reference SwiftAcervo's model uploading (doesn't exist)
- [ ] MUST use Homebrew-installed SwiftAcervo in CI
- [ ] MUST use macOS-26 runner
- [ ] MUST use organization secrets for CDN credentials

---

## FAQ

**Q: What if a library has multiple models of different sizes?**  
A: Create a single workflow with environment matrix or separate workflows per model. See SwiftBruja (single model) vs. mlx-audio-swift (multiple models via cascade).

**Q: What if a library doesn't use models?**  
A: No workflow needed. Only libraries with model dependencies implement CDN workflows.

**Q: Can we use SwiftAcervo's workflow instead?**  
A: No. SwiftAcervo should have zero model upload workflows. Each consuming library owns its upload.

**Q: What about model updates?**  
A: The midnight job runs daily and is idempotent — if manifest exists on CDN, it skips. To force re-upload, manually delete CDN manifest or use `workflow_dispatch` with a flag.

**Q: Why macOS-26 specifically?**  
A: Consistent with Claude global standards, supports Metal, arm64 native. Ubuntu runners lack Metal shaders and have different path conventions.

---

**Next Steps**: Implement Phase 2 (SwiftVoxAlta, SwiftEchada) and establish as the canonical pattern.
