---
type: test-cleanup-report
state: incomplete
feature_name: OPERATION INTEGRITY CHECKPOINT
mission_branch: mission/integrity-checkpoint/01
iteration: 1
---

# Test Cleanup Report — OPERATION INTEGRITY CHECKPOINT

Cross-repo mission (SwiftAcervo + SwiftVinetas). Cleanup scope = test files added/modified
during the mission, scanned for the 12 high-confidence CI-failure patterns.

- SwiftAcervo diff base: `5aae72d`..HEAD (branch `mission/integrity-checkpoint/01`)
- SwiftVinetas diff base: `d34b4ae`..HEAD (branch `mission/integrity-checkpoint/01`)

## Removed

| file:test | reason | confidence |
|-----------|--------|-----------|
| _(none)_ | No mission-added test matched a high-confidence CI-failure pattern. | — |

## Flagged for Review

| file:test | concern | recommended action |
|-----------|---------|--------------------|
| _(none)_ | — | — |

## Notes / Out-of-scope observations

- `Tests/SwiftAcervoTests/AvailabilityThreeStateTests.swift` contains two `Thread.sleep`
  calls (lines ~320, ~421). **Pre-existing, NOT mission-added** (`git diff 5aae72d..HEAD`
  shows no `+` for them) → out of scope. They are deliberate concurrency-coordination
  sleeps in the download-dedup/joiner tests, not flaky timing assertions.
- The mission's added tests are uniformly fixture/mock/stub-based: temp directories,
  `MockURLProtocol`, injected `availabilityEvaluatorOverride` (`@TaskLocal`) / `integrityChecker`
  closures. No hardcoded `/Users/` paths, no real-network calls, no unseeded randomness,
  no `Date()` assertions, no skip markers.
- HARD DISCOVERY (for the brief, not a prunable test): SwiftVinetas `make test-unit`
  crashes without `ACERVO_CDN_BASE_URL` / `TEST_RUNNER_ACERVO_CDN_BASE_URL` in the
  test-runner environment (fatalError in SwiftAcervo `Acervo+CDNConfiguration.swift`).
  This is a **pre-existing** SwiftAcervo consumer requirement; CI supplies it via the
  test plan. New tests did not introduce it. Candidate follow-up: make the SwiftVinetas
  `make test-unit` target self-contained (export a default) so it doesn't rely on the
  developer's shell profile.

## Build Verification

- SwiftAcervo `make test`: GREEN (main 685/97, tool 98/11, UI 70/12 w/ 2 pre-existing known issues).
- SwiftVinetas `make test-unit`: GREEN (758/83, with the two CDN env vars exported).

(No deletions were made, so no post-deletion re-run was required.)
