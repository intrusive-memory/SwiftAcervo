# REQUIREMENTS — Acervo Demo Harness App

## Purpose

Convert the `Sources/Acervo/` Xcode project from its SwiftData template
boilerplate into a thin, single-screen demo/harness app whose only job is
to host `SwiftAcervoUI.AcervoModelsSection` against the **real**
intrusive-memory CDN. This is a dogfooding shell — not a shipped product,
not a System Settings extension, not a cross-app garbage-collection
utility. It exists so we can iterate on the widgets in `SwiftAcervoUI`
without rebuilding Vinetas/SwiftBruja, and so we have a click-target for
screenshots and UI tests.

## Goals

1. Render the "Models" screen from the reference screenshot using the
   existing `AcervoModelsSection` / `AcervoModelDownloadRow` widgets.
2. Wire the section's `availability` / `download` / `deleteModel`
   closures to the real `Acervo` static library API — no mocks, no
   stubs, no fake progress.
3. Read and write models under the shared App Group container
   (`~/Library/Group Containers/<group>/SharedModels/`), so other
   intrusive-memory apps that join the same group see the same models.
4. Build and run on macOS 26+ and iOS 26+ with automatic signing under
   `io.intrusive-memory.Acervo`.

## Non-Goals (Out of Scope)

- Garbage collection, orphan scanning, or any cross-app cleanup UI.
- Settings/Preferences integration with the host OS — this is a regular
  app window, not a `Settings { … }` scene nor a `.prefPane`.
- Authoring/uploading models (no `acervo ship`, `publish`, `recache`
  surface in the UI).
- Credential entry (R2 keys, HF tokens). The harness only reads from
  the public CDN.
- Localization beyond what `AcervoModelsSection` already provides.
- Adding new public API to `SwiftAcervo` or `SwiftAcervoUI`. The
  harness consumes what's there; if something is missing, file a
  follow-up rather than expanding scope here.

## Context (What Already Exists)

- `Sources/SwiftAcervoUI/` ships the drop-in widgets:
  `AcervoModelsSection`, `AcervoModelDownloadRow`,
  `AcervoModelRowController`, `AcervoModelRowItem`,
  `AcervoModelDownloadInterstitial`, `AcervoUIAccessibility`.
- `Sources/Acervo/` is a stock Xcode multiplatform app project
  (`io.intrusive-memory.Acervo`, automatic signing, macOS + iOS
  targets, plus `AcervoTests` and `AcervoUITests`). Its current
  `ContentView.swift` / `Item.swift` are SwiftData template
  boilerplate and **must be replaced**.
- `Acervo.sharedModelsDirectory` resolves via
  `ACERVO_APP_GROUP_ID` env var or the first
  `com.apple.security.application-groups` entitlement entry. UI apps
  must use the entitlement path (env vars don't work on iOS).
- `Acervo.checkAvailability(_:)`, `Acervo.ensureAvailable(_:progress:)`,
  and `Acervo.delete(_:)` (or the slug-keyed equivalents) cover every
  closure `AcervoModelsSection` needs. Confirm exact signatures in
  `Docs/USAGE-library.md` before wiring.

## Functional Requirements

### FR-1 — Replace boilerplate

- Delete `Sources/Acervo/Acervo/Item.swift`.
- Delete the SwiftData `modelContainer` setup from
  `Sources/Acervo/Acervo/AcervoApp.swift`.
- Rewrite `Sources/Acervo/Acervo/ContentView.swift` to host a single
  `Form` containing one `AcervoModelsSection`. No `NavigationSplitView`,
  no item list, no detail pane.

### FR-2 — Add SwiftAcervoUI as a target dependency

- The `Acervo` app target currently has no Swift package dependency.
  Add a local-package dependency on this repo (`SwiftAcervo` package)
  and link both `SwiftAcervo` and `SwiftAcervoUI` products to the app
  target. (Both iOS and macOS targets of the app, if both ship.)

### FR-3 — Fixture model list

- Provide a hardcoded `[AcervoModelRowItem]` fixture inside the app
  target (e.g. `FixtureModels.swift`). Each item must use a real model
  slug that resolves on the production CDN, with realistic
  `subtitleLines` (size, RAM, perf hint) and `groupID` /
  `groupDisplayName` matching the screenshot's "FLUX.2" / "PIXART"
  grouping style.
- The list must contain at least one grouped pair (to exercise the
  caption header) and at least one ungrouped row.
- See **Open Questions Q1** for the specific slugs.

### FR-4 — Wire real Acervo closures

- `availability` closure: call `Acervo.checkAvailability(_:)` (or the
  slug-keyed variant — pick whichever matches the fixture's `id`
  field) and return the resulting `ModelAvailability` unchanged.
- `download` closure: call `Acervo.ensureAvailable(_:progress:)` and
  forward fractional progress to the row's progress sink. Translate
  any per-component progress into a single `0.0…1.0` fraction
  consistent with how Vinetas wires it.
- `deleteModel` closure: call the appropriate `Acervo.delete(_:)` for
  the fixture's id form. Throw on failure so the row surfaces an
  inline error like the screenshot's "Download failed: …" state.

### FR-5 — App Group entitlement

- Add a `.entitlements` file to the app target declaring
  `com.apple.security.application-groups = ["group.intrusive-memory.models"]`
  (or whatever the chosen group id is — see **Open Questions Q2**).
- Configure both iOS and macOS app targets to embed the entitlement.
- The macOS target must also enable the App Sandbox with
  `com.apple.security.files.user-selected.read-only` (the default
  template setting is fine; just confirm App Group works alongside it).
- On launch, the harness must NOT crash with the
  `Acervo.sharedModelsDirectory` "no app group configured"
  `fatalError`. Verify by running once before declaring done.

### FR-6 — Layout matches reference screenshot

- The visible window/screen renders a `Form` (inset-grouped on iOS,
  default styling on macOS) containing exactly one
  `AcervoModelsSection` with header `"Models"`.
- Group caption headers ("FLUX.2", "PIXART", …) appear above grouped
  rows in uppercased small caps — this is `AcervoModelsSection`'s
  default behavior; do not override unless it diverges from the
  screenshot.
- A row in error state surfaces the error text inline next to a retry
  affordance (`AcervoModelDownloadRow` does this; verify by triggering
  a 404 against a deliberately-bogus fixture id).

### FR-7 — Replace test boilerplate

- `AcervoTests/AcervoTests.swift` currently contains template
  `XCTestCase` scaffolding with no assertions. Replace with at least
  one meaningful unit test that exercises the fixture list (e.g.
  asserts every fixture slug is non-empty and `groupID == nil` xor
  `groupDisplayName != nil` invariant holds).
- `AcervoUITests/AcervoUITests.swift` + `AcervoUITestsLaunchTests.swift`
  may stay as launch smoke tests. If they cannot run reliably in CI,
  the post-mission `test-cleanup` step will prune them — that is
  expected and fine.

## Constraints

- **No `swift build` / `swift test`.** Use XcodeBuildMCP locally; raw
  `xcodebuild` in CI. Honor the existing Makefile if it grows a
  target for the demo app.
- **Platforms:** iOS 26.0+, macOS 26.0+ only. No availability checks
  for older OSes.
- **Zero new external dependencies.** SwiftAcervo's "Foundation +
  CryptoKit only" rule applies to the harness as well.
- **No new public API in SwiftAcervo or SwiftAcervoUI.** If the
  harness can't be built with what's exported today, stop and file a
  follow-up — do not expand the public surface inside this mission.
- **Real CDN, not mocks.** The harness's value is dogfooding the real
  download path; do not introduce a mock `Acervo.*` shim.

## Open Questions (Blocking — Resolve Before Refine)

**Q1. Fixture model list.** Which production CDN slugs should the
harness ship with? The screenshot suggests an image-gen flavor
(FLUX.2 Klein 4B/9B, PixArt-Sigma XL). Need confirmed slugs that
actually resolve on the production CDN today. Suggested shape:

- 2× FLUX-family models, grouped under `groupID="flux2"`.
- 1× PixArt model, grouped under `groupID="pixart"`.
- 1× ungrouped utility/small model (to exercise the no-group path).

User must supply the exact slugs, or approve a probe step that lists
what's actually on the CDN and picks four.

**Q2. App Group identifier.** `Acervo+PathResolution.swift` documents
`group.intrusive-memory.models` as the convention, but the existing
intrusive-memory apps may already be on a different group id (e.g.
`group.io.intrusive-memory.shared`). Using the wrong one means the
harness sees a different `SharedModels/` directory than Vinetas /
SwiftBruja and isn't actually dogfooding the shared store. **Confirm
which group id those apps use** before adding the entitlement.

**Q3. iOS target — keep or drop?** The current Xcode project ships
both iOS and macOS app targets. Keeping iOS doubles the signing /
entitlements / device-test surface area for a harness that is
overwhelmingly going to be exercised on macOS. Recommend dropping
the iOS target for now and re-adding it later if there's a real
demand. User must approve before the iOS app target is removed.

## Acceptance Criteria

1. `make build` (or the project's equivalent XcodeBuildMCP target)
   produces a signed `Acervo.app` for macOS 26+ with no warnings
   about unused SwiftData scaffolding or missing entitlements.
2. Launching the app shows a window whose content matches the
   reference screenshot layout: one "Models" form, grouped rows with
   uppercase caption headers, a trash-can affordance on available
   models, a download button on missing models.
3. Tapping Download on a missing model actually downloads it from
   the CDN, progress bar advances based on real bytes-transferred,
   and on completion the row flips to the green-checkmark/trash-can
   state.
4. Tapping the trash on an available model removes it from
   `SharedModels/` and the row flips back to the Download state.
5. Pointing a fixture row at a deliberately-bogus slug surfaces the
   real `Acervo` error text inline, matching the failure styling in
   the reference screenshot.
6. `AcervoTests` contains at least one meaningful assertion (not
   template boilerplate).
7. `git grep -n "SwiftData\|@Query\|modelContainer\|Item.self"` in
   `Sources/Acervo/` returns nothing.

## Mission Notes for the Supervisor

- The 3 open questions above are **hard blockers**. The refine
  phase's blocking-question pass should halt and surface them
  to the user; do not have a sortie guess slugs or group ids.
- Sorties are well-suited to parallelism along these axes: (a)
  fixture + ContentView rewrite, (b) entitlement + project.pbxproj
  edits, (c) test replacement. The supervisor should still own the
  build gate at the end.
- Post-mission `test-cleanup` is expected to prune the launch UI
  test if it cannot run reliably under the project's CI configuration.
