# PR #35 Code Review (Senior Engineer Assessment)

Date: 2026-05-03
Reviewer: Codex (GPT-5.3-Codex)

## Scope Reviewed

- `Sources/SwiftAcervo/Acervo+CDNMutation.swift`
- `Sources/SwiftAcervo/S3CDNClient.swift`
- `Sources/SwiftAcervo/SigV4Signer.swift`
- New tests around publish flow, manifest integrity, and SigV4

## Overall

PR #35 is a substantial and well-structured expansion that introduces a full CDN mutation surface with thoughtful layering:

1. SigV4 primitives
2. S3 mutation client
3. High-level `Acervo.publishModel` orchestration

The design intent around atomic manifest-last swaps and post-upload verification is strong.

## Primary Finding (Needs Follow-Up)

### 1) Public readback verification is vulnerable to HTTP caching artifacts

`publishModel` performs post-upload verification against `credentials.publicBaseURL` using `URLSession.shared`. The public readback path does not appear to force cache bypass semantics for `manifest.json` and sample-file checks.

**Why this matters:** immediately after upload, CDN edge or local URL cache behavior can produce stale responses, creating false negatives (or, in some topologies, false positives if intermediate layers behave unexpectedly). This makes CI/CD pipelines flaky and can obscure real deployment correctness.

**Recommendation:** in the public verification requests, enforce cache-busting and strict cache policy:

- Set `cachePolicy = .reloadIgnoringLocalCacheData`
- Add `Cache-Control: no-cache`
- Add a deterministic cache-buster query parameter (e.g., upload timestamp or manifest hash)

This keeps verification coupled to origin freshness rather than cache state.

## Secondary Notes

- The separation between correctness failures (steps 8/9) and non-fatal orphan prune failure semantics is excellent.
- Batch delete handling and explicit failed-key surfacing materially improves operational debuggability.
- Test coverage breadth is strong for a large feature landing.

## Verdict

- **Architecture:** Strong
- **Reliability:** Good, with one important verification-hardening gap
- **Merge readiness:** **Conditionally ready** once cache-hardening strategy is added (or explicitly documented and accepted as known risk)
