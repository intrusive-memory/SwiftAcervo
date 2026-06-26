---
type: docs
state: completed
---

# TEST_CLEANUP_REPORT — OPERATION TORRENT TRIBUNAL (iteration 01)

**Diff range:** `15f5868..47a84a7` (mission branch `mission/torrent-tribunal/01`)
**Assessed by:** supervisor (direct assessment — no pruning agent dispatched; see rationale)
**Tests pruned:** 0
**Tests flagged for review:** 0

## Why no pruning agent was dispatched

The `test-cleanup` pass exists to remove **mission-added tests that would fail unreliably in CI** (unmocked network, hardcoded paths, time races, local-env deps). The single test artifact added by this mission — `Tests/SwiftAcervoTests/StreamingPerformanceTests.swift` — is *built entirely out of those exact patterns* (real `Acervo.download` network calls, `ContinuousClock` timing, `FileManager` temp roots). A naïve pattern-matching prune would delete the entire deliverable.

That is precisely the misfire this mission was designed to make impossible. The suite is **architecturally guaranteed never to run in CI**, via three independent mechanisms:

1. **Runtime gate** — every test early-returns unless `ACERVO_PERF_TESTS` is set (Sortie 1/3).
2. **CI test-plan skip** — `StreamingPerformanceTests` is in the `skippedTests` of both `SwiftAcervo-macOS` and `SwiftAcervo-iOS` plans (Sortie 2).
3. **Scheme isolation** — it only runs under the `SwiftAcervo-Performance` plan, which is opt-in/local-only and not invoked by any CI workflow.

## Evidence the suite cannot fail CI

| Check | Result |
|-------|--------|
| `make test` `[PERF]` line count | **0** (gate suppresses under macOS plan) |
| `make test-ios` `[PERF]` line count | **0** (gate + plan skip) |
| `make test-plan-shape` | **exits 0** — both CI plans clean |
| `grep -rn Performance .github/` | no workflow invokes the `-Performance` plan |

## Conclusion

No tests pruned, none flagged. The CI-failure patterns present in `StreamingPerformanceTests.swift` are the suite's *reason for existing* and are fully neutralized by the gate + skip + scheme isolation. Pruning would be wrong. This is a clean **KEEP** input to the brief.
