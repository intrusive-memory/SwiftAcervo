---
name: acervo-integration-ci
type: skill
description: Wire a repository's model-dependent integration test(s) to actually run in CI against cached SwiftAcervo models, the standardized way. Use this skill whenever the user wants to fix, enable, add, or standardize integration tests that need a downloaded ML model in GitHub Actions — phrases like "make the integration tests run in CI", "my model tests are disabled in CI", "cache the models in CI", "add the integration test to the pipeline", "standardize how we test real inference", or "the generation/TTS/inference test never runs on CI". It vendors a credential-free CDN primer + cache-key script into .github/scripts/, adds/updates an integration-tests workflow that restores models via actions/cache and primes on miss, wires the TEST_RUNNER_ACERVO_* env so xcodebuild forwards the cache into the xctest runner, and normalizes the test's gate to model-presence (XCTSkipUnless / @Test(.enabled(if:))). Input is the specific integration test (file/target/suite) when it can't be derived from repo context. Works one repo at a time; batch by invoking per repo.
---

# acervo-integration-ci

Make a repo's model-dependent integration tests run **for real** in CI —
downloading nothing per-run, testing actual inference — using SwiftAcervo's
standard cache contract. Read `references/STANDARD.md` first; it is the spec
this skill enforces. `references/test-gates.md` and
`references/workflow-template.yml` are the artifacts you apply.

## What "fixing" means here

The recurring failure mode across these repos is that model integration tests
are **disabled, mock-only, or inverted** (`.disabled(if: !CI.isEmpty)` runs them
*only locally*), and CI has **no model caching**, so real inference is never
exercised. This skill converts a repo to the one standard:

1. Vendor `acervo-ci-prime.sh` + `acervo-ci-cache-key.sh` into `.github/scripts/`.
2. Add/update an `integration-tests.yml` job: restore `actions/cache` → prime
   from CDN on miss → build → run the test with `TEST_RUNNER_ACERVO_MODELS_DIR`
   + `TEST_RUNNER_ACERVO_OFFLINE=1`.
3. Normalize the test's gate to `Acervo.isModelAvailable` (presence), removing
   any `CI`-based / mock / nightly-env gating.
4. Make sure the test is in a test plan / `-only-testing` selection the job runs.

## Inputs

- **The repo** (cwd, or the user names one).
- **The integration test** — file path, test target, `@Suite`/`XCTestCase`, or
  test-plan name. Derive it from context when possible (see Step 2). **If you
  cannot unambiguously identify it, ask the user** — do not guess which suite is
  the model-dependent one. The user was told this skill takes the test as input.

## Workflow

### Step 1 — Confirm SwiftAcervo + a real model dependency

```bash
grep -rl "import SwiftAcervo\|Acervo\." Sources Tests 2>/dev/null | head
grep -rn "ensureAvailable\|isModelAvailable\|fromPretrained\|download(model" Tests 2>/dev/null | head
```

- If the repo doesn't use SwiftAcervo for models (e.g. SwiftBruja expects a
  hand-placed model; cloud-only providers), still standardize onto the Acervo
  cache: the consumer should resolve the model through `Acervo.isModelAvailable`
  / `ensureAvailable`. Flag this to the user — it's a code change, not just CI.
- If the "integration test" uses **synthetic data** (e.g. SwiftEchada's vox
  container tests), there is **no model to cache** — tell the user there's
  nothing for this skill to do and stop.

### Step 2 — Identify the integration test and its model slug(s)

Find the model-dependent suite and the exact `modelId` string(s) it loads:

```bash
# Candidate integration suites
grep -rln "ensureAvailable\|isModelAvailable\|fromPretrained\|VinetasClient\|generate(" Tests
# The modelId literals they pass
grep -rn "fromPretrained(\|ensureAvailable(\|isModelAvailable(\|download(model" Tests
```

Convert each `modelId` to its **slug** with `slugify`: replace `/` with `_`
(see `references/STANDARD.md` table). The slug is what goes in `ACERVO_CI_MODELS`
and is the CDN directory name. If the test loads several models (e.g. FLUX.2
transformer + VAE), list all slugs.

To see what slugs actually exist on the CDN (handy for matching the consumer's
`modelId` to a real directory), use the CLI — it lists every model directory on
the bucket (requires R2 credentials in the env):

```bash
acervo list            # all slugs currently on the CDN
```

Note `acervo list` only proves a directory exists; it does **not** validate the
manifest format — Step 3 does that. Confirm with the user if the suite or the
slugs are ambiguous.

### Step 3 — Verify each model is on the CDN in CDNManifest format

The primer only works against `acervo ship`-format manifests. Check before
wiring anything:

```bash
for slug in <slug-1> <slug-2>; do
  echo "== $slug =="
  curl -fsSL "https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/$slug/manifest.json" \
    | jq '{manifestVersion, hasPath: (.files[0].path != null), hasChecksum: (.manifestChecksum != null), files: (.files|length)}'
done
```

- `hasPath: true` + `hasChecksum: true` → good, proceed.
- 404, or `hasPath: false` (legacy `{"files":[{"name","size"}]}`) → **stop and
  remediate**: the model must be (re-)shipped in CDNManifest format. Tell the
  user to run `/acervo-cdn-setup` (or `acervo ship <org/repo> --slug <slug>`,
  see `/acervo-download-ship`). This skill is downstream of the upload standard
  and cannot proceed without a valid manifest. This legacy-format mismatch is
  the most common reason these tests were disabled in the first place.

### Step 4 — Vendor the scripts

Copy both scripts from this skill's `scripts/` dir into the repo (substitute the
announced skill base directory for `<SKILL_DIR>`):

```bash
mkdir -p .github/scripts
cp "<SKILL_DIR>/scripts/acervo-ci-prime.sh"     .github/scripts/
cp "<SKILL_DIR>/scripts/acervo-ci-cache-key.sh" .github/scripts/
chmod +x .github/scripts/acervo-ci-*.sh
```

These are identical in every repo — that's what makes the approach "the same way
everywhere." Don't fork them per-repo; if they need changing, change them in the
skill and re-vendor.

### Step 5 — Add or update the workflow

Use `references/workflow-template.yml`. Either create
`.github/workflows/integration-tests.yml` from it, or merge the `integration`
job into the repo's existing test workflow if the user prefers one file.

Fill the placeholders:
- `{{SCHEME}}` — the scheme that builds the integration test target
  (`xcodebuild -list` / look at existing workflows).
- `{{TEST_PLAN}}` — a test plan containing **only** the model-dependent tests.
  If none exists, either create one, or drop `-testPlan` and use
  `-only-testing:<Target>/<Suite>` so unit tests aren't dragged in.
- `{{MODEL_SLUGS}}` — the newline-separated slugs from Step 2.

Match the repo's existing destination/OS pins (e.g. iOS sim `OS=26.1`) and
runner (`macos-26`). Keep the `TEST_RUNNER_ACERVO_*` env on the test step exactly
as templated — without the `TEST_RUNNER_` prefix the xctest process never sees
the cache dir or offline flag.

> iOS Simulator note: the sim process can read host paths, so
> `ACERVO_MODELS_DIR` as an absolute workspace path works there too. Heavy
> MLX/Metal model tests are macOS-arm64; default the integration job to macOS
> unless the user needs the simulator.

### Step 6 — Normalize the test's gate

Open the integration suite and apply `references/test-gates.md`:
- **Remove** any `.disabled(if: !(env["CI"] …))`, `if isCI { mock }`,
  `MLXAUDIO_NIGHTLY_RUN`-style env gates, and `Issue.record("skip…")`.
- **Add** a presence gate:
  - swift-testing: `@Suite(..., .enabled(if: Acervo.isModelAvailable(slug)), .serialized)`
  - XCTest: `try XCTSkipUnless(Acervo.isModelAvailable(slug), "…")`
- Keep `.serialized` for GPU/MLX suites (shared Metal context).
- Do not call `ensureAvailable` from the body to download — priming is the
  workflow's job; the body assumes the model is present.

### Step 7 — Verify locally, then hand off to CI

- Dry-run the primer + key scripts locally (cheap, public reads):
  ```bash
  ACERVO_CI_MODELS="<slugs>" bash .github/scripts/acervo-ci-cache-key.sh
  ACERVO_MODELS_DIR=/tmp/acervo-ci-test ACERVO_CI_MODELS="<slugs>" \
    bash .github/scripts/acervo-ci-prime.sh
  ```
  (For a quick smoke without pulling full checkpoints, point at the smallest
  slug.) Confirm a `manifest.json` and the listed files land under
  `/tmp/acervo-ci-test/<slug>/`.
- Build the test target locally per the repo's Makefile/XcodeBuildMCP rules
  (never `swift build`/`swift test`; prefer `make`). Confirm it compiles with the
  new gate.
- Commit to the `development` branch (these repos take chores directly on
  `development`; use a PR if the user wants review). Conventional message, e.g.
  `ci: run <suite> integration tests against cached models`.
- After the first CI run, if the job is meant to gate merges, remind the user to
  add its check name to branch protection's `required_status_checks` (per global
  CLAUDE.md).

## Batch use

This skill fixes **one repo at a time**. To standardize several (SwiftVoxAlta,
mlx-audio-swift, SwiftVinetas, Vinetas, …), invoke it per repo — or drive it
across the package collection with `/package-iterator`. Each repo's slugs and
scheme differ, so confirm Steps 2–3 per repo.

## Files in this skill

- `scripts/acervo-ci-prime.sh` — credential-free CDN→cache primer (curl+jq).
- `scripts/acervo-ci-cache-key.sh` — manifest-checksum cache key emitter.
- `references/STANDARD.md` — the full standard + env-var contract. Read first.
- `references/workflow-template.yml` — the canonical integration job.
- `references/test-gates.md` — XCTest / swift-testing gating convention.
