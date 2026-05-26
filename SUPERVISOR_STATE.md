# SUPERVISOR_STATE.md — OPERATION SELF-FEEDING CANARY

## Terminology

> **Mission** — definable, testable scope of work.
> **Sortie** — atomic, testable unit of work executed by a single autonomous AI agent in one dispatch.

## Mission Metadata

- Operation: OPERATION SELF-FEEDING CANARY
- Mission slug: `acervo-demo-harness`
- Iteration: 1
- Starting point commit: `cfad41d727e8eda72cc213b794d562d8cac2f044`
- Mission branch: `model-widget` (per user override — work commits directly to this branch, no `mission/.../01` sub-branch)
- Pre-build dependency purge: skipped (no `intrusive-memory/*` deps in Package.swift; mission edits app target, not library deps)
- Started at: 2026-05-26

## Plan Summary

- Work units: 1
- Total sorties: 4
- Dependency structure: layered (1 → {2 ∥ 3} → 4)
- Dispatch mode: dynamic prompt construction

## Work Units

| Name | Directory | Sorties | Dependencies |
|------|-----------|---------|--------------|
| acervo-demo-app | `Sources/Acervo/` | 4 | none (single-project plan) |

## Per-Work-Unit State

### acervo-demo-app
- Work unit state: RUNNING
- Current sortie: 1 of 4
- Sortie state: PENDING (about to dispatch)
- Sortie type: code
- Model: opus (forced — high foundation importance, novel pbxproj surgery, blocks 3 downstream sorties)
- Complexity score: 17 (task complexity 8 + ambiguity 2 + foundation 7 + risk 3 − code-type 3)
- Attempt: 0 of 3
- Last verified: n/a
- Notes: Sortie 1 carries the highest implementation risk in the plan (direct pbxproj edits + xcconfig env-var substitution + entitlements wiring across two app targets). Starting at opus to maximize first-attempt success.

## Active Agents

| Work Unit | Sortie | Sortie State | Attempt | Model | Complexity | Task ID | Output File | Dispatched At |
|-----------|--------|--------------|---------|-------|------------|---------|-------------|---------------|
| _none yet_ | | | | | | | | |

## Decisions Log

| Timestamp | Work Unit | Sortie | Decision | Rationale |
|-----------|-----------|--------|----------|-----------|
| 2026-05-26 | — | — | Mission branch is `model-widget` (no sub-branch) | User override at start time |
| 2026-05-26 | — | — | Pre-build dependency-purge SKIPPED | No `intrusive-memory/*` deps in `Package.swift`; nothing to bump |
| 2026-05-26 | — | — | Sortie 4 interactive UI parts deferred to user | XcodeBuildMCP unavailable in this session; sub-agent will run build+test+filesystem checks, then escalate UI smoke (tap Download / observe progress / tap trash / error path / screenshot) to user for manual verification |
| 2026-05-26 | — | — | Plan "SUPERVISING AGENT ONLY" annotations reinterpreted | Read as "must dispatch a sub-agent with build-tool access"; mission-supervisor skill forbids supervisor writing production code, so all sorties dispatch to general-purpose sub-agents (which have Bash → xcodebuild) |
| 2026-05-26 | acervo-demo-app | 1 | Model: opus | Forced by override: foundation_score=1 + dependency_depth=3 (blocks Sorties 2, 3, 4). Complexity score 17. |
