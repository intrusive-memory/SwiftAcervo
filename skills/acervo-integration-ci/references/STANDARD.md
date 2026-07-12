---
type: reference
---

# The SwiftAcervo CI integration-test standard

One way to run model-dependent integration tests in CI, identical across every
consumer of SwiftAcervo. This is the spec the skill enforces.

## Principles

1. **Test real inference, not mocks.** CI must exercise actual model
   download-resolution → load → generate/infer paths. Mock-in-CI defeats the
   purpose.
2. **Cache the model, never re-download it per run.** Multi-GB checkpoints are
   cached by `actions/cache`, keyed on the CDN manifest so a re-ship invalidates
   the cache and nothing else does.
3. **One cache location, one env var.** `ACERVO_MODELS_DIR` is checked first by
   `Acervo.sharedModelsDirectory`, overriding App Group entitlements/traits. CI
   uses it universally; production apps keep using their App Group.
4. **Fail loud on a miss.** The test runs with `ACERVO_OFFLINE=1` so a missing
   or incomplete model fails fast instead of silently pulling gigabytes during
   the test (which would blow the job timeout and hide a real cache bug).
5. **Gate on model presence, not on `CI`.** See `test-gates.md`.

## The moving parts

| Piece | Location | Role |
|---|---|---|
| `acervo-ci-prime.sh` | repo `.github/scripts/` | curl+jq primer: CDN manifest → files → byte-equal `manifest.json`. No creds, no Python, no `acervo` binary. |
| `acervo-ci-cache-key.sh` | repo `.github/scripts/` | emits `sha256(concat manifestChecksum)` as the cache key. |
| integration-tests.yml | repo `.github/workflows/` | restore cache → prime on miss → build → test with `TEST_RUNNER_ACERVO_*`. |
| presence gate | each test suite | `XCTSkipUnless` / `@Test(.enabled(if:))` on `Acervo.isModelAvailable`. |

## Env-var contract (from SwiftAcervo)

| Variable | Where set | Effect |
|---|---|---|
| `ACERVO_MODELS_DIR` | job `env` | Cache root; overrides App Group. Used by the prime script and any CLI step. |
| `TEST_RUNNER_ACERVO_MODELS_DIR` | test step `env` | xcodebuild strips `TEST_RUNNER_` and forwards it into the xctest runner so the test process sees `ACERVO_MODELS_DIR`. |
| `TEST_RUNNER_ACERVO_OFFLINE=1` | test step `env` | Forwarded as `ACERVO_OFFLINE=1`; blocks all network in the test. |
| `ACERVO_CDN_BASE` | optional | Override CDN base (default = `AcervoDownloader.cdnBaseURL`). |
| `ACERVO_CI_MODELS` | job `env` | Newline/space list of slugs to prime + key on. |

## Slug == slugify(modelId)

A model's CDN directory and its on-disk directory are both
`slugify(modelId)` = `modelId` with `/` → `_`. Whatever `modelId` string the
consumer passes to `Acervo.ensureAvailable` / `isModelAvailable`, the slug in
`ACERVO_CI_MODELS` must be that string slugified. Examples:

| Consumer modelId | Slug (`ACERVO_CI_MODELS` + CDN dir + disk dir) |
|---|---|
| `flux2-klein-4b` | `flux2-klein-4b` |
| `mlx-community/Qwen3-TTS-12Hz-1.7B` | `mlx-community_Qwen3-TTS-12Hz-1.7B` |

## Prerequisite: model must be shipped in CDNManifest format

The model must already be on the CDN **in `acervo ship` (CDNManifest) format** —
`.files[].path` + `.sizeBytes` + `.manifestChecksum`. The legacy hand-rolled
`{"files":[{"name","size"}]}` shape (seen in some old `ensure-model-cdn.yml`
files) is **rejected** by SwiftAcervo's validator; `acervo-ci-prime.sh` detects
it and stops with a remediation message. Fix by re-shipping:

```
acervo ship <org/repo> --slug <slug>     # or use /acervo-cdn-setup
```

This standard is downstream of the upload standard owned by `/acervo-cdn-setup`
and `/acervo-download-ship`.
