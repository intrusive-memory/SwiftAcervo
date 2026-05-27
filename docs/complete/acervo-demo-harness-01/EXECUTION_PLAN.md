---
mission: acervo-demo-harness
feature_name: OPERATION SELF-FEEDING CANARY
source: REQUIREMENTS.md
created: 2026-05-26
state: completed
iteration: 1
starting_point_commit: cfad41d727e8eda72cc213b794d562d8cac2f044
mission_branch: model-widget
---

# EXECUTION_PLAN.md — Acervo Demo Harness App

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure.

> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. One aircraft, one mission, one return.

> **Work Unit** — A grouping of sorties (package, component, phase).

## Mission Summary

Convert `Sources/Acervo/` from the stock Xcode SwiftData template into a thin, single-screen dogfooding harness that hosts `SwiftAcervoUI.AcervoModelsSection` against the real intrusive-memory CDN. macOS-first (iOS target fate per OQ-3). No new public API in `SwiftAcervo` / `SwiftAcervoUI`. No mocks.

## Work Units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|-----------|-----------|---------|-------|-------------|
| acervo-demo-app | `Sources/Acervo/` | 4 | — | none (single-project plan) |

Within the work unit, dependencies are sortie-level (see each sortie's Entry criteria).

---

## Sortie 1: Xcode project foundation (package dep, entitlement, target shape)

**Layer**: 1 (foundation — Sorties 2 and 3 depend on this)

**Priority**: 15.5 — Highest. Transitively blocks every other sortie; establishes the env-var-driven entitlement pattern reused by both app targets; novel xcconfig substitution carries the highest implementation risk.

**Entry criteria**:
- [ ] First sortie — no prerequisites

**Tasks**:
1. Edit `Sources/Acervo/Acervo.xcodeproj/project.pbxproj` to add a local Swift package dependency on the repo root (`../..` relative to the project file), exposing the `SwiftAcervo` and `SwiftAcervoUI` library products.
2. Link both `SwiftAcervo` and `SwiftAcervoUI` products to the macOS app target's `Frameworks` build phase AND to the iOS app target's `Frameworks` build phase. (Per resolved OQ-3, both targets are kept.)
3. Create `Sources/Acervo/Acervo/Configs/Shared.xcconfig` containing exactly one line that exposes the app-group id from the environment: `APP_GROUP_ID = $(ACERVO_APP_GROUP_ID)`. The xcconfig is the single source of truth for the id; nothing else hardcodes it.
4. Set the Debug and Release configurations of **both** the macOS and iOS app targets (and their test targets) to use `Shared.xcconfig` as their base configuration (`baseConfigurationReference` in the pbxproj).
5. Create `Sources/Acervo/Acervo/Acervo.entitlements` declaring `com.apple.security.application-groups = ["$(APP_GROUP_ID)"]`. Keep the existing App Sandbox entries (`com.apple.security.app-sandbox`, `com.apple.security.files.user-selected.read-only`) for the macOS target. The literal string `$(APP_GROUP_ID)` must appear in the plist source — Xcode substitutes it at build time from the xcconfig, which in turn pulls from the `ACERVO_APP_GROUP_ID` env var.
6. Wire `CODE_SIGN_ENTITLEMENTS = Acervo/Acervo.entitlements` into both the macOS and iOS app targets' build settings (Debug + Release).
7. Confirm the project still opens cleanly (`xcodebuild -project Acervo.xcodeproj -list`) and both app targets still build against the **stock** (un-rewritten) `ContentView.swift` / `AcervoApp.swift` — i.e. don't touch SwiftData code yet; this sortie's job is plumbing only. Builds must be invoked with `ACERVO_APP_GROUP_ID` exported in the environment (e.g. `ACERVO_APP_GROUP_ID=group.intrusive-memory.models xcodebuild ...`); the sortie's exit-criteria builds use the same convention.

**Exit criteria**:
- [ ] `xcodebuild -project Sources/Acervo/Acervo.xcodeproj -list` shows both the `Acervo` (macOS) and the iOS app schemes, and lists `SwiftAcervo` + `SwiftAcervoUI` as resolvable dependencies.
- [ ] `ACERVO_APP_GROUP_ID=group.intrusive-memory.models xcodebuild -project Sources/Acervo/Acervo.xcodeproj -scheme Acervo -destination 'platform=macOS' build` succeeds (warnings about the unused SwiftData template are acceptable at this stage — they get fixed in Sortie 2).
- [ ] `ACERVO_APP_GROUP_ID=group.intrusive-memory.models xcodebuild -project Sources/Acervo/Acervo.xcodeproj -scheme <iOS-scheme-name> -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.1' build` succeeds.
- [ ] `Sources/Acervo/Acervo/Configs/Shared.xcconfig` exists and contains `APP_GROUP_ID = $(ACERVO_APP_GROUP_ID)`.
- [ ] `Sources/Acervo/Acervo/Acervo.entitlements` exists, contains the literal substitution string `$(APP_GROUP_ID)` for `com.apple.security.application-groups`, and is referenced by `CODE_SIGN_ENTITLEMENTS` for both app targets' Debug + Release configurations (verify with `grep -n 'CODE_SIGN_ENTITLEMENTS\|APP_GROUP_ID' Sources/Acervo/Acervo.xcodeproj/project.pbxproj Sources/Acervo/Acervo/Acervo.entitlements`).
- [ ] `grep -rn 'group\.intrusive-memory\.models' Sources/Acervo/Acervo/ Sources/Acervo/Acervo.xcodeproj/` returns **no matches** (the literal id must never appear in source/project files — only in env-var-driven substitution).
- [ ] Sanity-check that the env-var substitution is actually wired: running `unset ACERVO_APP_GROUP_ID; xcodebuild ... -showBuildSettings | grep '^ *APP_GROUP_ID = '` prints `APP_GROUP_ID = ` followed by an empty value (not `group.intrusive-memory.models` or any other literal). This guarantees no hardcoded fallback snuck into the xcconfig or pbxproj.

---

## Sortie 2: Replace SwiftData boilerplate with AcervoModelsSection harness

**Layer**: 2 (depends on Sortie 1)

**Priority**: 11.0 — High. Produces `FixtureModels.swift` (foundation for Sortie 3's tests) and the harness UI that Sortie 4 verifies. Carries the CDN probe risk.

**Entry criteria**:
- [ ] Sortie 1 exit criteria met (package dep linked, entitlement wired, both app targets build)

**Tasks**:
1. Delete `Sources/Acervo/Acervo/Item.swift`.
2. Rewrite `Sources/Acervo/Acervo/AcervoApp.swift`: remove the `import SwiftData` line, remove the `sharedModelContainer` property, remove the `.modelContainer(sharedModelContainer)` call on the `WindowGroup`. The `@main App` should host a single `WindowGroup { ContentView() }`.
3. Create `Sources/Acervo/Acervo/FixtureModels.swift` exposing a `static let demoFixtures: [AcervoModelRowItem]`. **Slug selection**: probe the production CDN (use the local `acervo` CLI built from this repo — `make install-acervo` first if needed — to enumerate currently-shipped slugs) and pick four slugs matching the resolved-OQ-1 shape: 2× FLUX-family models grouped under (`groupID="flux2"`, `groupDisplayName="FLUX.2"`), 1× PixArt-Sigma model grouped under (`groupID="pixart"`, `groupDisplayName="PIXART"`), and 1× small ungrouped utility model (`groupID=nil`, `groupDisplayName=nil`). Every chosen slug must return a non-404 manifest from the production CDN at the time of writing — verify with `acervo verify <slug>` or equivalent before committing. Each item populates `subtitleLines` with realistic size / RAM / perf-hint strings.
4. Rewrite `Sources/Acervo/Acervo/ContentView.swift` to render a single `Form` containing one `AcervoModelsSection(title: "Models", items: FixtureModels.demoFixtures, availability: …, download: …, deleteModel: …)`. No `NavigationSplitView`, no `@Query`, no detail pane. Use `.formStyle(.grouped)` on macOS for a layout that visually matches the inset-grouped look from the reference screenshot.
5. Wire the three closures to the real static `Acervo` API (read `Docs/USAGE-library.md` first to confirm exact signatures):
   - `availability`: invoke `Acervo.checkAvailability(_:)` (or the slug-keyed variant matching the fixture's `id` form) and return the resulting `ModelAvailability` unchanged.
   - `download`: invoke `Acervo.ensureAvailable(_:progress:)` and forward fractional progress (0.0…1.0) to the row's progress sink. If the underlying API reports per-component progress, collapse it into a single fraction (sum of bytes-downloaded / sum of total-bytes).
   - `deleteModel`: invoke `Acervo.delete(_:)` for the fixture's id form. Propagate errors by re-throwing so `AcervoModelDownloadRow` surfaces the inline error UI.
6. `git grep -n "SwiftData\|@Query\|modelContainer\|Item.self" Sources/Acervo/` must return **no matches** by the end of this sortie (acceptance criterion #7).

**Exit criteria**:
- [ ] `Sources/Acervo/Acervo/Item.swift` does not exist.
- [ ] `git grep -n "SwiftData\|@Query\|modelContainer\|Item.self" Sources/Acervo/` returns no matches.
- [ ] `Sources/Acervo/Acervo/FixtureModels.swift` exists, defines `demoFixtures`, and the array satisfies: at least one grouped pair (same `groupID` + non-nil `groupDisplayName`) AND at least one row with `groupID == nil`.
- [ ] `Sources/Acervo/Acervo/ContentView.swift` imports `SwiftAcervo` and `SwiftAcervoUI`, contains exactly one `AcervoModelsSection(...)` call, and contains no references to `SwiftData`, `@Query`, `NavigationSplitView`, or `Item`.
- [ ] `xcodebuild -project Sources/Acervo/Acervo.xcodeproj -scheme Acervo -destination 'platform=macOS' build` succeeds with zero warnings about unused SwiftData scaffolding or missing entitlements.

---

## Sortie 3: Replace AcervoTests boilerplate with a meaningful fixture-invariant test

**Layer**: 2 (depends on Sortie 1; runs in parallel with Sortie 2)

**Priority**: 4.5 — Medium. Parallelizable with Sortie 2 because it touches a different file, but its build-green gate is bound to Sortie 2 landing `FixtureModels.swift`.

**Entry criteria**:
- [ ] Sortie 1 exit criteria met (package dep linked so the test target can import `SwiftAcervoUI`)

**Note**: This sortie can run in parallel with Sortie 2 because it touches only `Sources/Acervo/AcervoTests/AcervoTests.swift` (a different file). However, the test itself imports `FixtureModels` — so the **test will not compile and pass until Sortie 2 lands `FixtureModels.swift`**. That's acceptable; the gate for Sortie 3's exit criteria (`test` running green) is held until Sortie 2 also lands. The sortie agent only needs to write the test against the documented fixture invariants — not against runtime fixture content.

**Tasks**:
1. Rewrite `Sources/Acervo/AcervoTests/AcervoTests.swift` to import `SwiftAcervoUI` and the app module, and to define at least one assertion-bearing test method. Suggested coverage (the agent picks the exact form):
   - Every fixture's `id` is non-empty.
   - Every fixture satisfies the grouping invariant: a row either has both `groupID != nil` and `groupDisplayName != nil`, or has both `nil`. (No half-grouped rows.)
   - At least one fixture has `groupID == nil` (exercises the ungrouped path).
   - At least two fixtures share the same `groupID` (exercises the grouped-header path).
2. Confirm `AcervoUITests/AcervoUITests.swift` and `AcervoUITestsLaunchTests.swift` are left in place (post-mission `test-cleanup` will prune them if they're unreliable in CI).

**Exit criteria**:
- [ ] `Sources/Acervo/AcervoTests/AcervoTests.swift` defines at least one XCTest method whose body contains one or more `XCTAssert*` calls referencing `FixtureModels.demoFixtures`.
- [ ] No `func testExample()`-style empty-body template stubs remain.
- [ ] After Sortie 2 also lands, `xcodebuild -project Sources/Acervo/Acervo.xcodeproj -scheme Acervo -destination 'platform=macOS' test` runs the new test method and it passes. (Sortie 4 verifies this end-to-end.)

---

## Sortie 4: Build gate, launch verification, and CDN smoke test

**Layer**: 3 (depends on Sorties 2 and 3)

**Priority**: 4.5 — Terminal. Blocks nothing downstream, but carries real-CDN risk and interactive XcodeBuildMCP launch complexity; must run last because it verifies the integrated stack.

**Entry criteria**:
- [ ] Sortie 2 exit criteria met
- [ ] Sortie 3 exit criteria met

**Tasks**:
1. Run the full macOS build: `xcodebuild -project Sources/Acervo/Acervo.xcodeproj -scheme Acervo -destination 'platform=macOS' build`. Treat any warning about missing entitlements, SwiftData remnants, or unused template files as a failure to bounce back to the responsible sortie.
2. Run the test target: `xcodebuild -project Sources/Acervo/Acervo.xcodeproj -scheme Acervo -destination 'platform=macOS' test`. New `AcervoTests` method must execute and pass.
3. Launch the built `Acervo.app` once (via XcodeBuildMCP `launch_macos_app` or equivalent). Confirm:
   - The window opens without crashing on `Acervo.sharedModelsDirectory`'s `fatalError`.
   - The window shows a `Form` with one "Models" section and the fixture rows.
   - Grouped rows render uppercase small-caps captions (default `AcervoModelsSection` behavior).
4. Smoke-test one fixture slug end-to-end on the real CDN: tap Download on a missing model, observe the progress bar advance based on real bytes, observe the row flip to the available state (green check + trash). Then tap the trash and observe the row return to the Download state.
5. Smoke-test the error path: temporarily flip one fixture to a deliberately-bogus slug (e.g. `intrusive-memory-test/does-not-exist-${UUID}`), tap Download, observe inline error text matching `AcervoModelDownloadRow`'s failure styling. Revert the slug change before reporting done — the bogus row is not shipped.
6. Capture a screenshot of the running app via XcodeBuildMCP `screenshot` and save it to `Sources/Acervo/Acervo/Preview Content/harness-reference.png` for use as a regression reference.

**Exit criteria**:
- [ ] `xcodebuild ... build` succeeds with zero warnings.
- [ ] `xcodebuild ... test` runs the new fixture test and it passes.
- [ ] Manual launch verification: window renders, fixture rows visible, grouped captions present.
- [ ] Download verification (machine-checkable): before tapping Download, `ls ~/Library/Group Containers/$ACERVO_APP_GROUP_ID/SharedModels/<slug-form>/` is absent or empty; after the row settles into the available state, the same `ls` shows at least `config.json` present and non-zero-byte. Row state transitions to the green-check + trash form.
- [ ] Delete verification (machine-checkable): after tapping the trash, `ls ~/Library/Group Containers/$ACERVO_APP_GROUP_ID/SharedModels/<slug-form>/` reports the directory absent (or empty); row returns to Download state.
- [ ] Manual error verification: bogus slug surfaces inline error matching reference screenshot.
- [ ] Bogus-slug change has been reverted before report-out (no shipped fixture row points at a non-existent model).
- [ ] Reference screenshot saved at `Sources/Acervo/Acervo/Preview Content/harness-reference.png` (verify with `test -f`).

---

## Parallelism Structure

**Critical Path**: Sortie 1 → Sortie 2 → Sortie 4 (length: 3 sorties). Sortie 3 runs on a parallel branch (length 2) joining at Sortie 4.

**Parallel Execution Groups**:

- **Group 1** (Layer 1, sequential — foundation):
  - Sortie 1 — **SUPERVISING AGENT ONLY** (xcodebuild build × 2 platforms)
- **Group 2** (Layer 2, can run in parallel):
  - Sortie 2 — **SUPERVISING AGENT ONLY** (xcodebuild build)
  - Sortie 3 — **SUB-AGENT ELIGIBLE — NO BUILD** (pure file edit; test gate is deferred to Sortie 4 by design)
- **Group 3** (Layer 3, sequential — terminal verification):
  - Sortie 4 — **SUPERVISING AGENT ONLY** (build + test + launch + CDN smoke + XcodeBuildMCP)

**Agent Allocation**:
- 1 supervising agent (handles every sortie that compiles, tests, or launches the app)
- Up to 1 sub-agent in Group 2 (handles Sortie 3's file-only edit)
- Sub-agent ceiling unused (4 available, 1 used) because the plan is intentionally small.

**Missed Opportunities**: None inside the current sortie graph. Sub-tasking within Sortie 1's pbxproj/xcconfig/entitlement work would add more dispatch overhead than it saves.

---

## Decisions Log

<!-- Open questions from breakdown were resolved during refine Pass 1 on 2026-05-26. All three are closed; below is the audit trail. -->

| # | Decision | Source | Affects |
|---|----------|--------|---------|
| OQ-1 | Accept recommendation: agent probes the production CDN via the local `acervo` CLI and picks 4 slugs matching the shape (2× FLUX-family grouped, 1× PixArt-Sigma grouped, 1× ungrouped utility). Every chosen slug must be verified to return a non-404 manifest before commit. | recommendation | Sortie 2 |
| OQ-2 | Override: do not hardcode the app-group id. Drive it from the `ACERVO_APP_GROUP_ID` environment variable via an xcconfig (`APP_GROUP_ID = $(ACERVO_APP_GROUP_ID)`) that the entitlements plist substitutes (`$(APP_GROUP_ID)`). Builds must be invoked with the env var exported. The literal `group.intrusive-memory.models` must NOT appear anywhere in source or project files. | user override | Sortie 1 |
| OQ-3 | Override: **keep the iOS app target.** Wire entitlements, xcconfig, and package linkage for both macOS and iOS targets. | user override | Sortie 1 |

## Summary

| Metric | Value |
|--------|-------|
| Work units | 1 |
| Total sorties | 4 |
| Open questions | 0 (3 resolved — see Decisions Log) |
| Dependency structure | layered (1 → {2 ∥ 3} → 4) |
