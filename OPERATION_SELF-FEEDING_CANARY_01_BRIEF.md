---
mission: acervo-demo-harness
feature_name: OPERATION SELF-FEEDING CANARY
iteration: 1
generated: 2026-05-26
state: complete
---

# Iteration 01 Brief — OPERATION SELF-FEEDING CANARY

**Mission:** Convert `Sources/Acervo/` from the stock Xcode SwiftData template into a thin, single-screen dogfooding harness hosting `SwiftAcervoUI.AcervoModelsSection` against the real intrusive-memory CDN, no mocks.
**Branch:** `model-widget`
**Starting Point Commit:** `cfad41d727e8eda72cc213b794d562d8cac2f044`
**Sorties Planned:** 4
**Sorties Completed:** 4 (Sortie 4 with 4b deferred-to-human per user decision)
**Sorties Failed/Blocked:** 0
**Duration:** single working session, ~9 commits over one calendar day
**Outcome:** Complete
**Verdict:** `KEEP` — All four sorties landed; signed unit tests pass against the real shared-models container; only deferred work is user-driven UI smoke that was never an agent task.
**Tests pruned:** 0
**Tests flagged for review:** 0

---

## Section 1: Hard Discoveries

### 1. `$(APP_GROUP_ID)` in `.entitlements` does not survive provisioning/codesign

**What happened:** Sortie 1 wired the App Group identifier through `ACERVO_APP_GROUP_ID` → `Shared.xcconfig` → `$(APP_GROUP_ID)` → `Acervo.entitlements`. Sortie 1's build verification with `CODE_SIGNING_ALLOWED=NO` passed because no real signing happened. The first signed run failed: the literal token `$(APP_GROUP_ID)` reached the codesign step un-substituted (or substituted to an empty string), producing a profile/entitlement mismatch.
**What was built to handle it:** Commit `7a80fb6` hardcoded `group.intrusive-memory.models` directly into the entitlements file and retained `Shared.xcconfig` as harmless dead weight.
**Should we have known this?** Yes — there is a well-documented Apple constraint that `.entitlements` plist values are NOT expanded against xcconfig variables the same way Info.plist values are. Researching "xcconfig variable in entitlements" before designing Sortie 1 would have revealed this. The original plan's whole "env-var-driven group ID" gimmick was architecturally wrong.
**Carry forward:** When the deliverable touches signing/entitlements, verify against a REAL signed build, not `CODE_SIGNING_ALLOWED=NO`. Never assume `.entitlements` expands xcconfig variables.

### 2. Apple Developer portal App ID needed App Groups capability explicitly registered

**What happened:** Even after hardcoding, signing failed with "Provisioning profile doesn't include the App Groups capability / doesn't support `group.intrusive-memory.models` App Group / doesn't include the `com.apple.security.application-groups` entitlement." The wildcard "Mac Team Provisioning Profile: io.intrusive-memory.*" had never had App Groups enabled server-side.
**What was built to handle it:** User registered App Groups capability + the specific group ID on the App ID at developer.apple.com and regenerated the profile. Automatic signing then picked it up under `-allowProvisioningUpdates`.
**Should we have known this?** Yes, partially. Sortie 1's report flagged this as a likely blocker ("App Group capability not yet registered against bundle ID"). It got logged as a flag but the mission proceeded anyway and rediscovered it as a hard signing failure two retries later. Better triage of Sortie 1's flags would have surfaced it as a `BLOCKED` state immediately.
**Carry forward:** When a sortie self-reports a flagged user-action prerequisite, the supervisor must escalate it before dispatching downstream work, not just log it.

### 3. Test target deployment targets do not auto-track host app deployment target

**What happened:** User-side Xcode UI edits (folded into commit `7a80fb6`) bumped the Acervo app target from macOS 26.2 to 26.3, but Xcode did not propagate the change to AcervoTests or AcervoUITests. Result: `@testable import Acervo` refused to compile a 26.2-target test bundle against a 26.3 module.
**What was built to handle it:** Commit `3710ee7` bumped iOS and macOS deployment targets in both test target configs (Debug + Release × 2 targets = 4 blocks) from 26.2 to 26.3, leaving xrOS at 26.2 to match the host.
**Should we have known this?** No, this was a pure Xcode-UI behavior we did not exercise until this iteration. Xcode "Edit Deployment Target" affects only the selected target.
**Carry forward:** Any deployment-target change in a multi-target project must be applied to ALL targets in the same scheme. Worth adding to a project-config audit checklist.

### 4. AcervoUITests scaffold target is environmentally flaky on headless macOS

**What happened:** The auto-generated `AcervoUITests-Runner` times out enabling automation mode under `xcodebuild test` in the agent's shell environment ("Timed out while enabling automation mode"). This is a `testmanagerd`/accessibility-daemon limitation unrelated to mission code.
**What was built to handle it:** Nothing — recorded as known flake; mission never authored UI tests.
**Should we have known this?** Yes — this is a common headless-macOS quirk for any Xcode-generated UI test target. Anyone running `xcodebuild test` against a default Xcode project will hit it.
**Carry forward:** Strip or skip `AcervoUITests` from any CI-gating scheme — either delete the target, or pass `-skip-testing:AcervoUITests/AcervoUITests` to xcodebuild, or remove it from the Acervo scheme's Test action. (Open decision OD-1 below.)

---

## Section 2: Process Discoveries

### What the Agents Did Right

#### A1. Sortie 2's deviation calls were correct on both counts

**What happened:** Sortie 2 hit two plan-vs-reality mismatches and made the right judgment in both cases: (a) only one FLUX.2 model exists on the CDN, so it paired with the T5 text encoder to preserve the grouped-pair UX shape, and (b) the plan referenced non-existent API names (`checkAvailability`, `delete`, `ensureAvailable(_:)`); the agent corrected to the real symbols.
**Right or wrong?** Right. The deviation was flagged in SUPERVISOR_STATE for user awareness instead of silently working around the bad spec or stopping cold.
**Evidence:** Commit `8e95de3` compiles and runs; tests against `FixtureModels.demoFixtures` pass; no follow-up sortie needed to "redo" Sortie 2.
**Carry forward:** This is the correct pattern — when the plan and reality disagree, fix the deliverable to match reality and flag the plan defect upward.

#### A2. Sortie 3's tests are exactly the right shape

**What happened:** Sortie 3 wrote three deterministic XCTest methods that iterate the static fixture array and assert structural invariants (non-empty IDs, grouping consistency, both rendering paths exercised). No I/O, no network, no time, no randomness.
**Right or wrong?** Right. Test-cleanup audit removed zero and flagged zero.
**Evidence:** `TEST_CLEANUP_REPORT.md` is the cleanest possible result. All three pass signed against the real container.
**Carry forward:** Fixture-invariant tests are an excellent pattern for harness-style deliverables.

### What the Agents Did Wrong

#### B1. Sortie 1 over-engineered the App Group plumbing

**What happened:** The plan called for "env-var-driven entitlement"; Sortie 1 implemented it faithfully through three layers (`ACERVO_APP_GROUP_ID` → xcconfig → `$(APP_GROUP_ID)` → entitlements). The whole indirection chain turned out to be wrong (see Hard Discovery 1) and got replaced by a single hardcoded string.
**Right or wrong?** Wrong, but not the agent's fault — the agent built what the plan said. The fault is in the plan (see Planner Wrong 1).
**Evidence:** `Shared.xcconfig` is now dead weight retained for git-blame-friendliness; the env-var indirection was deleted in 7a80fb6.
**Carry forward:** Agents executing foundation sorties should be empowered to challenge architectural choices in their entry criteria when they're about to spend cost on a pattern that may not work — but this requires the supervisor's dispatch to invite that challenge.

### What the Planner Did Wrong

#### C1. The "env-var-driven entitlement" requirement was based on an unverified assumption

**What happened:** The plan baked in a complex `ACERVO_APP_GROUP_ID` → xcconfig → entitlement substitution chain as the App Group wiring strategy. This pattern does not work in Apple's signing toolchain — `.entitlements` plists do not get xcconfig variable expansion at codesign time.
**Right or wrong?** Wrong. Five minutes of upfront research ("can xcconfig variables expand in .entitlements") would have killed this pattern before Sortie 1 spent opus tokens on it.
**Evidence:** Three retries of Sortie 4a (plus the entitlement hardcode commit) were directly attributable to this wrong foundation.
**Carry forward:** During `refine`, any "indirection through configuration" pattern needs a one-paragraph "does this actually work in the target toolchain" check before being elevated to a plan requirement.

#### C2. User-prerequisite blockers were under-escalated

**What happened:** Sortie 1's flag about needing to register App Groups in the dev portal was logged but treated as a "flag for user" rather than as a `BLOCKED` state. Mission proceeded all the way to Sortie 4a, hit the wall server-side, then waited for the same user action that was identified four sorties earlier.
**Right or wrong?** Wrong — process bug.
**Evidence:** Three signed-build attempts after the initial flag, two of which were predestined to fail at signing for the same reason.
**Carry forward:** Sortie flags that name a specific user-side prerequisite (registration, account state, server-side capability) should automatically demote the work unit to `BLOCKED` until acknowledged, not just log.

#### C3. Plan made unverified API name claims

**What happened:** Plan referenced `Acervo.checkAvailability(_:)`, `Acervo.delete(_:)`, `Acervo.ensureAvailable(_:)` — none of which exist in the SwiftAcervo public API. Agent corrected to `availability(_:)`, `deleteModel(_:)`, `ensureAvailable(_:files:progress:)` with `files: []`.
**Right or wrong?** Wrong — should have been caught in `refine`.
**Evidence:** Sortie 2 deviation log; the corrections were trivial because the real API was discoverable in one `grep`.
**Carry forward:** During `refine-questions` (Pass 5), any sortie that names an API symbol must have that symbol confirmed against the actual codebase, not against the planner's memory of it.

---

## Section 3: Open Decisions

### OD-1. AcervoUITests scaffold target — strip, skip, or accept?

**Why it matters:** As long as `xcodebuild test` against the `Acervo` scheme runs `AcervoUITests-Runner`, the exit code will be `FAILED` in any headless CI even when all real tests pass. This makes the scheme un-gateable.
**Options:**
- (A) Remove the `AcervoUITests` target entirely. Cleanest. Aligns with "no mocks, no scaffold dead weight" mission spirit.
- (B) Keep the target but remove it from the `Acervo` scheme's Test action.
- (C) Keep everything; always invoke `xcodebuild test -skip-testing:AcervoUITests/AcervoUITests`.
**Recommendation:** (A). The mission never intended UI tests; the scaffold exists only because Xcode generates it by default. Deleting the target is one Xcode click and one pbxproj diff.

### OD-2. `Shared.xcconfig` — keep, delete, or document?

**Why it matters:** It is now an unused config file. Keeping it invites future confusion ("what does APP_GROUP_ID do?"). Deleting it adds noise to the diff if a future iteration decides to reintroduce indirection.
**Options:** keep silently / delete / keep with a comment "intentionally unused since iteration 1 — see brief."
**Recommendation:** Delete. There is no scenario where the env-var-in-entitlements pattern comes back; the Apple constraint is permanent.

### OD-3. Sortie 4b (interactive UI smoke) — track as a follow-up?

**Why it matters:** Tasks 3–6 of Sortie 4 (tap Download, observe progress, tap trash, error path, screenshot) were always user-driven. They are explicitly out of scope for the agent harness per user decision 2026-05-26, but they remain genuinely-not-done as feature verification.
**Options:** open an issue / track in CLAUDE.md or AGENTS.md / consider it done because the unit tests cover the data layer.
**Recommendation:** Open a follow-up issue or note in the README so the next iteration's planner doesn't re-discover this as a gap.

---

## Section 4: Sortie Accuracy

| Sortie | Task | Model | Attempts | Accurate? | Notes |
|--------|------|-------|----------|-----------|-------|
| 1 | Wire SwiftAcervo+SwiftAcervoUI as local SPM deps; env-var-driven entitlement | opus | 1 | **Partially** | Built what the plan said. The env-var indirection was later removed wholesale. Real work (SPM wiring, .gitignore exception, single-target structural discovery) survived. |
| 2 | Replace SwiftData template with AcervoModelsSection harness; populate FixtureModels | opus | 1 | **Yes** | Code survives unchanged. Two plan-vs-reality deviations were correct calls. |
| 3 | Three XCTAssert tests on FixtureModels grouping | sonnet | 1 | **Yes** | Tests passed signed; survived test-cleanup with zero edits. |
| 4a | Build + test gate (macOS signed) | sonnet | 3 | **Yes after retry chain** | Original build under `CODE_SIGNING_ALLOWED=NO` was the wrong gate; required three retries to clear the real signed path (dev-portal fix + deployment-target fix). Final state is verified. |
| 4b | Interactive UI smoke | — | 0 | n/a | Explicitly deferred-to-human; never dispatched. |

**Net assessment:** Foundation sortie (1) was 70% accurate — wiring and structural work survived, the headline architectural choice did not. Build/feature sorties (2, 3) were 100% accurate. The build-gate sortie (4a) is 100% accurate but took 4 attempts due to upstream defects, not its own mistakes.

---

## Section 5: Harvest Summary

The single most important thing we did not know going in: **`.entitlements` plists are not xcconfig-expanded at codesign time.** Everything else flowed from that one wrong assumption — Sortie 1's indirection chain, the dev-portal blocker discovery being delayed, the three Sortie 4a retries. Test cleanup pruned 0 and flagged 0; the mission's authored test surface was hermetic and small, so there's no pattern of repeated bad-test behavior to learn from. The next iteration's planner should bake in a "does this signing pattern actually work in the Apple toolchain?" check during `refine`, and should escalate any user-side prerequisite (dev-portal capability, manual provisioning step) to a hard `BLOCKED` gate instead of a soft flag.

---

## Section 6: Files

### Preserve (read-only reference for next iteration)

| File | Branch | Why |
|------|--------|-----|
| `Sources/Acervo/Acervo/Acervo.entitlements` | `model-widget` | Hardcoded App Group string — keep as-is, do not reintroduce indirection. |
| `Sources/Acervo/AcervoTests/AcervoTests.swift` | `model-widget` | Three hermetic invariant tests. Pattern to emulate. |
| `Sources/Acervo/Acervo/Configs/Shared.xcconfig` | `model-widget` | Currently dead weight; see OD-2. |
| `Sources/Acervo/Acervo.xcodeproj/project.pbxproj` | `model-widget` | Deployment targets unified at 26.3 (iOS, macOS) / 26.2 (xrOS where it remains). |

### Discard (will not exist after rollback)

| File | Why it's safe to lose |
|------|----------------------|
| _(nothing intended for discard)_ | Mission ends in `KEEP`; nothing on the mission branch is targeted for rollback. |

---

## Iteration Metadata

**Starting point commit:** `cfad41d` (`Rearranging files`)
**Mission branch:** `model-widget` (user-overridden, no `mission/.../01` sub-branch)
**Final commit on mission branch:** `43c57f6` (`chore(mission): mark Sortie 4 COMPLETED; add TEST_CLEANUP_REPORT`)
**Rollback target:** `cfad41d` (same as starting point commit) — N/A for this brief
**Next iteration branch:** `mission/acervo-demo-harness/02` (only if a follow-up mission is planned)

---

## Section 8: Rollback Verdict

**Verdict:** `KEEP`

**Reasoning:** Four planned sorties landed. The headline deliverable (single-screen `AcervoModelsSection` harness wired to the real CDN with a real signed shared-models container) is functional and verified by three passing unit tests in a signed run against the real `group.intrusive-memory.models` group container on disk. Hard Discoveries 1–3 cost three Sortie 4a retries but produced a correct end state, not a corrupted one. Zero tests pruned, zero flagged. The remaining work (4b interactive UI smoke) was always human-driven and was explicitly deferred by user decision, not silently dropped. Late-iteration `KEEP` bias applies even though this is iteration 1, because the cost to redo this work would exceed the cost of resolving OD-1/OD-2/OD-3 incrementally on the next branch.

**Recommended action:**
- **KEEP**: merge `model-widget` (or PR it via `/create-pull-request`) once OD-1 and OD-2 are resolved on this branch or accepted as follow-ups.
- Follow-up work for the next iteration's planner:
  1. Delete or skip the `AcervoUITests` scaffold target (OD-1).
  2. Delete `Shared.xcconfig` (OD-2).
  3. Bake the "test the signed path, not `CODE_SIGNING_ALLOWED=NO`" rule into any sortie that touches entitlements (Hard Discovery 1).
  4. Promote user-prerequisite flags from Sortie 1-style "log it" to BLOCKED-on-dispatch (Planner Wrong C2).
