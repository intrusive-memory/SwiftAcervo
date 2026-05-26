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
- Sorties 1/2/3/4 → COMPLETED / COMPLETED / COMPLETED / PARTIAL (4a build gate PASS; test gate + 4b interactive parts all blocked on user dev-portal fix)

#### Sortie 4 — PARTIAL (single user-side blocker covers all remaining work)
- Sortie 4a build gate (unsigned, `CODE_SIGNING_ALLOWED=NO`): **PASS** — zero warnings, `** BUILD SUCCEEDED **`, build runtime ~1 min
- Sortie 4a test gate (unsigned): **FAIL — environmental, not a defect.** AcervoTests is bundle_loader-hosted inside `Acervo.app`. With `CODE_SIGNING_ALLOWED=NO` the host launches unsigned and crashes before XCTest can bootstrap. Failure mode: "Early unexpected exit, operation never finished bootstrapping". None of the 3 Sortie-3 tests executed.
- Sortie 4a retry (signed, post-7a80fb6) on 2026-05-26: **BUILD FAIL — Apple Developer portal still missing App Groups capability on the App ID.** Exact errors from `/tmp/sortie4a-retry-build.log`:
  - "Provisioning profile 'Mac Team Provisioning Profile: io.intrusive-memory.\*' doesn't include the App Groups capability."
  - "...doesn't support the group.intrusive-memory.models App Group."
  - "...doesn't include the com.apple.security.application-groups entitlement."
- Sortie 4b interactive parts (tasks 3–6): still pending; gated on signed run
- **Conclusion**: hardcoding the string did NOT bypass the dev-portal gap — it surfaced it as a clean, named signing error instead of the previous bootstrap crash. The required user action is unchanged from Sortie 1's original flag and is the sole remaining blocker for the entire mission.
- **NEXT_ACTION_FOR_USER**: at developer.apple.com → Certificates, IDs & Profiles → Identifiers → edit App ID `io.intrusive-memory.Acervo` (or the wildcard `io.intrusive-memory.*`) → enable **App Groups** capability → register/add group `group.intrusive-memory.models` → save → regenerate the **Mac Team Provisioning Profile** → in Xcode let automatic signing fetch the refreshed profile → re-run `/mission-supervisor resume`.
- Logs: `/tmp/sortie4a-build.log`, `/tmp/sortie4a-test.log` (unsigned attempt), `/tmp/sortie4a-retry-build.log` (signed attempt, 3792 B). Retry test log was not created (build never reached test phase).

#### Sortie 1 — COMPLETED (amended 2026-05-26 by user override)
- Commit: `cb47d6d` on `model-widget`
- Model used: opus, attempt 1/3
- Verified: macOS + iOS-simulator builds green; `Shared.xcconfig`, `Acervo.entitlements`, env-var substitution all confirmed; no literal app-group id in source/project
- **AMENDMENT 2026-05-26**: env-var substitution (`ACERVO_APP_GROUP_ID` → `APP_GROUP_ID` → `$(APP_GROUP_ID)` in entitlements) did not survive the codesign / provisioning step in practice. User directive: hardcode `group.intrusive-memory.models` directly into `Acervo.entitlements`. `Shared.xcconfig` is now dead weight (harmless; not removed in this commit). Other user-side Xcode edits accepted as part of the same amendment: deployment target bumped 26.2→26.3; `SUPPORTED_PLATFORMS` narrowed (xros/xrsimulator dropped); `TARGETED_DEVICE_FAMILY` `1,2,7`→`1,2`; sandbox tightened with explicit `ENABLE_RESOURCE_ACCESS_*=NO` flags and `ENABLE_OUTGOING_NETWORK_CONNECTIONS=YES`; `ENABLE_USER_SELECTED_FILES` `readonly`→`readwrite`; added `CFBundleDisplayName=Acervo` and `LSApplicationCategoryType=public.app-category.utilities`.
- Structural finding: project has a SINGLE multi-platform target (`Acervo`) covering iphoneos/iphonesimulator/macosx/xros/xrsimulator — not separate macOS/iOS targets. Downstream sorties wire to this one target.
- Deviation accepted: agent added `.gitignore` exception for `Sources/Acervo/Acervo.xcodeproj` because the repo-wide `*.xcodeproj` ignore would have made all Sortie 1 work untracked. Pragmatic; tracked.
- Flag for user: iOS simulator runtime 26.1 not installed locally; agent used 26.3.1. CI still pins 26.1 — confirm a runner has the matching runtime before relying on iOS gate.
- Flag for user: App Group capability `group.intrusive-memory.models` not yet registered against bundle ID `io.intrusive-memory.Acervo` in Apple Developer portal — Sortie 4's launch will fail signing until that's done.

#### Sortie 2 — COMPLETED (with two deviations flagged for user)
- Commit: `8e95de3` on `model-widget`
- Model used: opus, attempt 1/3
- Verified: Item.swift gone; no SwiftData/@Query/modelContainer/Item.self references anywhere in Sources/Acervo/; ContentView imports SwiftAcervo+SwiftAcervoUI; FixtureModels.swift has 4 rows; macOS build green with `CODE_SIGNING_ALLOWED=NO`
- **Deviation 1**: Only ONE FLUX.2 model exists on production CDN. Agent paired `black-forest-labs/FLUX.2-klein-4B` with `intrusive-memory/t5-xxl-int4-mlx` (the T5 text encoder used by the FLUX.2 stack) under `groupID="flux2"`. Preserves the grouped-pair UX shape; not strictly 2× FLUX checkpoints. USER DECISION POINT.
- **Deviation 2**: Plan referenced non-existent API names. Agent corrected to real symbols: `Acervo.availability(_:)` (not `checkAvailability`), `Acervo.deleteModel(_:)` (not `delete`), `Acervo.ensureAvailable(_:files:progress:)` with `files: []` (no 2-arg variant exists). Plan was wrong; agent's correction is right.

#### Sortie 3 — COMPLETED
- Commit: `e00f30c` on `model-widget`
- Model used: sonnet, attempt 1/3
- Verified: three `XCTAssert*` methods touching `FixtureModels.demoFixtures`; no empty template stubs; `AcervoUITests/*` untouched; single-file diff
- Note: file won't compile in isolation until Sortie 2 lands `FixtureModels.swift` — that combined gate is Sortie 4's job by design

## Active Agents

| Work Unit | Sortie | Sortie State | Attempt | Model | Complexity | Task ID | Output File | Dispatched At |
|-----------|--------|--------------|---------|-------|------------|---------|-------------|---------------|
| acervo-demo-app | 1 | COMPLETED | 1/3 | opus | 17 | aaa7f0ed529d38fc4 | tasks/aaa7f0ed529d38fc4.output | 2026-05-26 |
| acervo-demo-app | 2 | COMPLETED | 1/3 | opus | 14 | a6f4d0049691fccb8 | tasks/a6f4d0049691fccb8.output | 2026-05-26 |
| acervo-demo-app | 3 | COMPLETED | 1/3 | sonnet | 4 | a689866f5015ea5ec | tasks/a689866f5015ea5ec.output | 2026-05-26 |
| acervo-demo-app | 4a | PARTIAL | 1/3 | sonnet | (split) | a2d6cbc5c62aaa94f | tasks/a2d6cbc5c62aaa94f.output | 2026-05-26 |

## Decisions Log

| Timestamp | Work Unit | Sortie | Decision | Rationale |
|-----------|-----------|--------|----------|-----------|
| 2026-05-26 | — | — | Mission branch is `model-widget` (no sub-branch) | User override at start time |
| 2026-05-26 | — | — | Pre-build dependency-purge SKIPPED | No `intrusive-memory/*` deps in `Package.swift`; nothing to bump |
| 2026-05-26 | — | — | Sortie 4 interactive UI parts deferred to user | XcodeBuildMCP unavailable in this session; sub-agent will run build+test+filesystem checks, then escalate UI smoke (tap Download / observe progress / tap trash / error path / screenshot) to user for manual verification |
| 2026-05-26 | — | — | Plan "SUPERVISING AGENT ONLY" annotations reinterpreted | Read as "must dispatch a sub-agent with build-tool access"; mission-supervisor skill forbids supervisor writing production code, so all sorties dispatch to general-purpose sub-agents (which have Bash → xcodebuild) |
| 2026-05-26 | acervo-demo-app | 1 | Model: opus | Forced by override: foundation_score=1 + dependency_depth=3 (blocks Sorties 2, 3, 4). Complexity score 17. |
| 2026-05-26 | acervo-demo-app | 1 | Hardcode `group.intrusive-memory.models` in entitlements; abandon env-var indirection | User: "Provision using the environment variable wasn't working. Just go ahead and set the value with a string." Sortie 1's env-var substitution didn't carry through provisioning/codesign. `Shared.xcconfig` retained as dead-weight (harmless). Other user-applied pbxproj edits (deployment 26.2→26.3, drop visionOS, sandbox tightening, display name + category) accepted as part of the same amendment. |
| 2026-05-26 | acervo-demo-app | 4a-retry | Signed build attempted post-7a80fb6 → confirmed dev-portal gap is the only remaining blocker | Hardcoding the App Group did not bypass provisioning; it produced a clean, named error: provisioning profile lacks App Groups capability + `group.intrusive-memory.models` entry. User must register the capability + group on the App ID and regenerate the Mac Team Provisioning Profile. No further automated sortie can advance this until that's done. |
