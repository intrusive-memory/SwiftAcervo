---
type: doc
updated: 2026-08-15
---

# Manifest Resilience & CDN Access Control — Execution Plan

**Status: planned.** Phase 0 (mirror repo) is done. Phases 1–5 are not started.

## Problem

Two architectural gaps, surfaced together in Aug 2026:

1. **Outage resilience.** The CDN domain is the sole authority for model
   structure (manifests) *and* the sole source of weight bytes. A multi-day
   domain outage strands every consumer that hasn't already downloaded —
   nothing can even enumerate what files a model contains. (The reverted
   local-first commit `a23d982` fixed this only for models already on disk.)
2. **Open access.** Anyone can download manifests and weights anonymously.
   The exposure is bandwidth abuse and, more seriously, license compliance:
   some mirrored models (e.g. FLUX.2) are gated on HuggingFace, and an open
   mirror is redistribution.

## Architecture

One principle resolves both: **the manifest is the trust anchor — make it
public and redundantly distributed; gate only the weight bytes.**

Manifests are file lists + sizes + SHA-256 hashes. Because every byte is
verified against the manifest, byte transport does not need to be trusted or
unique. Decision (locked, Aug 2026): manifests are world-readable.

### Ordered manifest resolution chain (read side)

```
in-memory ManifestCache
  → <modelDir>/manifest.json                  (persisted after full download)
  → persisted slug-manifest store             (persisted at fetch time)
  → bundled AcervoManifests/ app resources    (pinned at consumer build time)
  → mirror origin(s)                          (git-backed, raw.githubusercontent)
  → CDN
```

Every tier runs the same `manifestChecksum` / `modelId` validation as the CDN
path. A device with local copies works with the CDN dark; a fresh install
resolves structure from the mirror or its own bundle.

### Byte gating (write/serve side)

A Cloudflare Worker fronts R2 `GET /models/*`: `*/manifest.json` passes
unauthenticated; weight files require a bearer token (Tier 1). The design
leaves the validation seam Worker-side so App Attest short-lived tokens
(Tier 2) can replace the static token later without client API changes.
Candor note: a token embedded in a shipped app is extractable — Tier 1 is a
deterrent (crawlers, hotlinking, casual scraping), not a vault. The SigV4
mutation path (`publishModel` / `deleteFromCDN` / `recache`) is separately
credentialed and unaffected.

### Mirror repo (Phase 0 — DONE)

- **Repo:** <https://github.com/intrusive-memory/acervo-manifests> (public)
- **Local checkout:** `pkg/acervo-manifests` (sibling of this repo)
- **Layout:** `models/<slug>/manifest.json` + top-level `index.json` catalog
  (slug, modelId, primaryRepo, manifestChecksum, fileCount, totalBytes)
- **Seeded** 2026-08-15 from the live CDN: 48 models. CI (`validate.yml`)
  checks manifest shape and index/manifest-set consistency on every push.
- Written exclusively by the `acervo` publish pipeline once Phase 2 lands;
  hand edits are forbidden (see its README).

Seeding surfaced CDN cruft to clean up: `FLUX.2-klein-4B` and `FLUX.2-vae`
carry legacy hash-less manifests the current `CDNManifest` decoder cannot
parse (excluded from the mirror); `kyutai_moshiko-pytorch-bf16`,
`lmstudio-community_Mistral-Small-3.2-24B-Instruct-2506-MLX-4bit`, and
`PixArt-alpha_PixArt-Sigma-XL-2-1024-MS` have no `manifest.json` at all.

## TODO

### Phase 1 — Library: ordered manifest resolution chain

- [ ] `ManifestResolver` implementing the chain; `ManifestCache.swift` becomes
      its in-memory tier.
- [ ] Re-introduce disk persistence of slug manifests (cherry-pick/salvage
      from reverted `a23d982`), persisting at fetch time. Post-download
      persistence already exists (`AcervoDownloader.swift`, `manifestFilename`).
- [ ] Bundled tier: auto-read `AcervoManifests/` from `Bundle.main`;
      `Acervo.registerBundledManifests(directory:)` for CLIs/tests.
- [ ] Mirror tier: `ACERVO_MANIFEST_MIRROR_URLS` env var /
      `AcervoManifestMirrorURLs` Info.plist key — ordered HTTPS base URLs.
      `SecureDownloadSession` admits mirror hosts for manifest paths only.
- [ ] Rewire onto the resolver: `fetchManifest(for:)`
      (`Acervo+ManifestAccess.swift`), `performHydration`
      (`Acervo+Hydration.swift`), `ensureAvailable`/`availability`
      (`Acervo+SlugAvailability.swift`, `Acervo+EnsureAvailable.swift`),
      component downloads. `deleteModel` purges persisted manifests so a
      deleted model re-resolves fresh.
- [ ] `AcervoError.manifestUnavailableAllSources` carrying per-source
      failure reasons.
- [ ] `ACERVO_OFFLINE` serves the network-free tiers instead of forbidding
      all resolution.
- [ ] Register new variables in `Acervo.EnvironmentVariable`
      (`Acervo+Environment.swift`) — help/diagnostics update automatically.

### Phase 2 — Mirror write side (CLI)

- [ ] `acervo ship` (`ShipCommand.swift` → `UploadCommand.swift` /
      `PublishRunner.swift`): after CHECK 5 passes, commit manifest + updated
      `index.json` to the mirror checkout and push. Flags:
      `--manifest-mirror <repo-or-path>`, `--no-mirror`.
- [ ] `acervo delete --cdn` and `acervo recache` keep mirror + index in sync.
- [ ] `acervo mirror verify`: diff mirror against live CDN manifests
      (CI-able drift check).

### Phase 3 — Byte gating (Cloudflare Worker, Tier 1)

- [ ] Worker with R2 binding on `GET /models/*`: manifests pass, weights
      require `Authorization` bearer token. Wrangler config in `cdn-worker/`.
- [ ] `SecureDownloadSession` attaches the token from
      `ACERVO_CDN_AUTH_TOKEN` / `AcervoCDNAuthToken` plist key; add both to
      `Acervo.EnvironmentVariable`.
- [ ] Publish-pipeline + `acervo doctor` gate checks: manifest fetch succeeds
      without token; weight fetch 401s without token and succeeds with it.
- [ ] Document the Tier 2 (App Attest) upgrade path; do not build it until
      abuse or license audit warrants.

### Phase 4 — Offline discovery

- [ ] `Acervo.listModels` / `acervo list` fall back to mirror `index.json`
      → bundled index when the CDN is unreachable.

### Phase 5 — Tests, docs, rollout

- [ ] Resurrect the dead-CDN suite from `a23d982`
      (`LocalFirstResolutionTests.swift`); add mirror-fallback,
      bundled-manifest, auth-header, and 401-path cases (MockURLProtocol).
- [ ] Docs: threat-model section in `CDN_ARCHITECTURE.md`;
      `CDN_CONFIGURATION.md` (new vars); `USAGE-library.md`; `USAGE-cli.md`;
      CLAUDE.md key components.
- [ ] CDN cleanup: delete or re-ship the 5 cruft slugs listed above.
- [ ] Consumer rollout (per app/CLI repo): mirror URL + auth token config,
      optional bundled manifests.

## PR sequencing

1. **PR 1:** Phase 1 + Phase 2 (resolver + populated mirror write side).
2. **PR 2:** Phase 3 (Worker deploy isolated so a bad gate config cannot
   block the resilience work).
3. **PR 3:** Phases 4–5 remainder.

## Decisions log

- Mirror repo: `intrusive-memory/acervo-manifests`, public, raw.githubusercontent
  as the serving origin (independent infrastructure from Cloudflare — that is
  the point).
- Manifests world-readable: **yes** (owner decision, 2026-08-15). Per-model
  exception mechanism: a sensitive model's manifest can live only in specific
  apps' bundled tier and be omitted from the mirror.
- Bytes gated at the Worker; Tier 1 static bearer token now, Tier 2 App
  Attest only if warranted.
- Local-first ordering stands (local tiers before network). The staleness
  trade-off is the documented contract: a CDN-side model update is not picked
  up until the local model is deleted.
