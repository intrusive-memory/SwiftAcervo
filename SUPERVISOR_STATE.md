# SUPERVISOR_STATE.md — OPERATION VAULT BROOM (iteration 02)

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure.
> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch.
> **Work Unit** — A grouping of sorties (package, component, phase).

---

## Mission Metadata

- **Operation name**: OPERATION VAULT BROOM
- **Iteration**: 02 (iteration 01 abandoned after sortie collision; restart per user directive)
- **Starting point commit**: `7ef2d6d96c0c8dbfa2d30e335ff8014b1effab2f`
- **Mission branch**: `mission/vault-broom/02`
- **Started**: 2026-05-02
- **Plan**: [EXECUTION_PLAN.md](EXECUTION_PLAN.md)
- **Source requirements**: [REQUIREMENTS-delete-and-recache.md](REQUIREMENTS-delete-and-recache.md)
- **Target version**: v0.9.0
- **Max retries**: 3

### Iteration 01 Notes (informational — not carried forward)

- Branch `mission/vault-broom/01` retained as historical record at commit `01ec9e7` (WU1.S1 work).
- Stash `stash@{0}` retained as historical record (contained iteration 01 WIP including S3CDNClient.swift / S3CDNClientTests.swift).
- This iteration starts fresh from `development` per user directive — no cherry-pick, no carry-over.

---

## Plan Summary

- Work units: 4
- Total sorties: 12
- Dependency structure: layers (WU1 → WU2 → WU3 → WU4); sequential within each work unit
- Dispatch mode: dynamic (no explicit template in plan)

## Work Units

| Name | Directory | Sorties | Dependencies |
|------|-----------|---------|--------------|
| WU1: CDN mutation library (SigV4 + S3CDNClient) | `Sources/SwiftAcervo/` | 3 | none |
| WU2: Orchestration API (publishModel / deleteFromCDN / recache) | `Sources/SwiftAcervo/` | 3 | WU1 |
| WU3: CLI migration | `Sources/acervo/` | 3 | WU2 |
| WU4: Documentation, version bump, Homebrew formula | repo + `../homebrew-tap/` | 3 | WU3 |

---

## Per-Work-Unit State

### WU1: CDN mutation library
- Work unit state: `RUNNING`
- Current sortie: 1 of 3
- Sortie state: `PENDING`
- Sortie type: `code`
- Model: pending dispatch (planned: `opus` — foundation override applies)
- Complexity score: 25 (foundation crypto, 11 downstream sorties, new tech)
- Attempt: 0 of 3
- Last verified: n/a (not yet dispatched)
- Notes: Iteration 01 produced a SigV4Signer attempt on branch `mission/vault-broom/01` — not consumed. This sortie re-implements WU1.S1 from scratch on iteration 02.

### WU2: Orchestration API
- Work unit state: `NOT_STARTED`
- Current sortie: — of 3
- Sortie state: —
- Notes: Gated on WU1 COMPLETED.

### WU3: CLI migration
- Work unit state: `NOT_STARTED`
- Current sortie: — of 3
- Sortie state: —
- Notes: Gated on WU2 COMPLETED.

### WU4: Documentation, version bump, Homebrew formula
- Work unit state: `NOT_STARTED`
- Current sortie: — of 3
- Sortie state: —
- Notes: Gated on WU3 COMPLETED. WU4.S3 is a deferred sortie (waits on v0.9.0 tag).

---

## Active Agents

| Work Unit | Sortie | Sortie State | Attempt | Model | Complexity Score | Task ID | Output File | Dispatched At |
|-----------|--------|--------------|---------|-------|-----------------|---------|-------------|---------------|
| _(none yet)_ | | | | | | | | |

---

## Decisions Log

| Timestamp | Work Unit | Sortie | Decision | Rationale |
|-----------|-----------|--------|----------|-----------|
| 2026-05-02 | mission | — | Restart as iteration 02 from `development` HEAD (`7ef2d6d`) | User directive: iteration 01 abandoned after sortie collision; "restart from current development branch" |
| 2026-05-02 | mission | — | Discard iteration 01 SUPERVISOR_STATE.md and code WIP (S3CDNClient.swift, S3CDNClientTests.swift) | User directive: unstash REQUIREMENTS + EXECUTION_PLAN only; status fresh |
| 2026-05-02 | mission | — | Preserve `mission/vault-broom/01` branch and `stash@{0}` as historical record | No data destruction without explicit instruction |
| 2026-05-02 | WU1 | 1 | Plan to dispatch with `opus` | Foundation override: foundation_score=1, dependency_depth=11. Score breakdown: complexity 10 + ambiguity 1 + foundation 10 + risk 4 = 25 |

---

## Overall Status

- **Mission state**: starting up — initial dispatch pending
- **Critical path**: 12 sorties (WU1.S1 → WU1.S2 → WU1.S3 → WU2.S1 → WU2.S2 → WU2.S3 → WU3.S1 → WU3.S2 → WU3.S3 → WU4.S1 → WU4.S2 → WU4.S3)
- **Parallelism opportunity**: only WU4.S1 (docs), up to 4 sub-agents
- **External wait**: WU4.S3 deferred until v0.9.0 release tag exists
