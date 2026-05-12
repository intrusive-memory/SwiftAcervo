# FOLLOW_UP.md — Post-v0.8.0 Follow-Up Items

Items that surfaced during OPERATION DESERT BLUEPRINT but are out of scope for v0.8.0.

---

## CI Workflow Migration

Source: `docs/complete/hydration_todo.md` § "CI Workflow Is a Separate Problem"

Each consumer repo's `ensure-model-cdn.yml` hardcodes a `FILES=(...)` array. That file is the *producer* of the CDN manifest — it can never source files from the manifest it is about to create. Addressing it requires one of:

- A documented CI convention: discover files via the HuggingFace repo API (`https://huggingface.co/api/models/{repoId}/tree/main`) with a filter for inference-relevant extensions.
- `acervo ship --from-hf {repoId}` mode: discovery + filter + upload in one shot. Pulls the logic into this repo instead of leaving every consumer YAML to reinvent it.

Recommendation: the second option. The Swift-side work (v0.8.0) is the prerequisite. Track as a follow-on to the `acervo ship` CLI.

---

## Pre-existing Test Flake: `AcervoPathTests.sharedModelsDirectory`

Observed during Sortie 2 and Sortie 6 validation rounds. Not caused by this mission.

`AcervoPathTests` and `AcervoFilesystemEdgeCaseTests` (30+ tests) share the `Acervo.customBaseDirectory` static global without serialization. When the parallel test runner schedules them concurrently, one suite's teardown resets `customBaseDirectory` mid-run in another suite.

Suggested fix: wrap `customBaseDirectory` access in an actor, or provide a test-only isolation primitive (see next item).

**Status (2026-04-23): Addressed by Sortie 2 of OPERATION TRIPWIRE GAUNTLET (mission branch `mission/tripwire-gauntlet/02`).** A shared `@Suite("Custom Base Directory", .serialized) struct CustomBaseDirectorySuite {}` parent now hosts every suite that writes `Acervo.customBaseDirectory` (`AcervoPathTests`, `AcervoFilesystemEdgeCaseTests`, `AcervoSymlinkEdgeCaseTests`, `ModelDownloadManagerTests`). A complementary `withIsolatedAcervoState { ... }` helper (and a narrower `withIsolatedComponentRegistry { ... }`) in `Tests/SwiftAcervoTests/Support/ComponentRegistryIsolation.swift` snapshots/restores both the `customBaseDirectory` and `ComponentRegistry.shared` contents on every entry/exit — even on throw. `HydrateComponentTests.hydrateComponentPopulatesRegistry` was migrated as proof-of-use of `withIsolatedComponentRegistry`. The sortie's exit criterion required `make test` to pass 5 consecutive times with zero flakes in the previously-racy tests.

---

## Test-Isolation Primitive

SwiftAcervo lacks a clean way for tests to isolate their registry and configuration state. Currently tests rely on unique UUIDs and `defer { unregisterComponent(...) }` patterns, which are error-prone and fail when a test crashes before teardown.

A test-only hook on `ComponentRegistry` and `Acervo` that allows per-suite subsystem instances (rather than sharing the global singleton) would eliminate an entire class of races and make test authoring significantly safer.

---

## Disk-Cache Deferral (Blocker 2)

Manifest disk caching was deferred from v0.8.0 (locked 2026-04-22, Blocker 2: "ship without caching"). Every `ensureComponentReady` call fetches the manifest fresh from the CDN — one HTTP round-trip per startup per component.

If startup-time HTTP calls become a performance complaint: revisit Sortie 7 in `docs/complete/` (archived after this mission). The proposed design caches `manifest.json` to the per-component directory with a 24-hour TTL and falls back to the cached copy on network error.

---

## Git Stash Review

During Sortie 6, a pre-existing developer stash was accidentally popped and its contents discarded during a supervisor-agent recovery step.

Current stash list as of mission close:

- `stash@{0}`: WIP on development (v0.7.2)
- `stash@{1}`: WIP on mission/hydrant-gorge/1

The repository owner should review both stashes before archiving the mission branch to confirm nothing important was lost. Run `git stash show -p stash@{0}` and `git stash show -p stash@{1}` to inspect.

---

## Sortie Process Improvement

Sortie 5 shipped a flaky test (`CatalogHydrationTests.hydrationAwarenessInCatalog`) because it only ran `make test` once before declaring done. The flake was caused by a global-registry race with concurrent suites and was caught during Sortie 6's 5-consecutive-run exit criterion.

Future sorties that add tests touching global state (registry, `customBaseDirectory`, etc.) should run `make test` at least 3 consecutive times before declaring done — regardless of whether the sortie has an explicit flake-sweep requirement.
