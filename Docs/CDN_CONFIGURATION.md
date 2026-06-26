---
type: reference
---

# CDN_CONFIGURATION.md — Configuring the CDN Base URL

**For**: Consumers wiring SwiftAcervo into an app, library, CLI, test target, or
CI pipeline. This document defines the contract for the **CDN base URL** — a
per-consumer configuration value with **no hardcoded default**.

---

## Summary

SwiftAcervo does not ship a baked-in CDN host. Every download URL and the
allowed-redirect host are derived at runtime from a single consumer-supplied
value: `Acervo.cdnBaseURL`. If that value is not configured (or is malformed),
SwiftAcervo traps with `fatalError` rather than guessing a host. This mirrors the
existing App Group resolution contract (see
[SHARED_MODELS_DIRECTORY.md](SHARED_MODELS_DIRECTORY.md)): configuration is
mandatory, explicit, and shared across every consumer.

Running example used throughout this doc:

```
https://cdn.intrusive-memory.productions/models
```

---

## The two configuration channels

| Symbol | Value | Used by |
| --- | --- | --- |
| `Acervo.cdnBaseURLEnvironmentVariable` | `ACERVO_CDN_BASE_URL` | CLI tools, scripts, test runners, CI |
| `Acervo.cdnBaseURLInfoPlistKey` | `AcervoCDNBaseURL` | UI apps (macOS / iOS) |

### Resolution order (`Acervo.cdnBaseURL`)

1. `ACERVO_CDN_BASE_URL` environment variable, if non-empty.
2. `AcervoCDNBaseURL` `Info.plist` key (`Bundle.main`), if non-empty.
3. **`fatalError`** — no per-process fallback.

### Validation

The resolved string is validated before use:

- It must parse via `URL(string:)`.
- Its scheme must be `https`.
- It must carry a non-empty `host`.
- Any trailing `/` is stripped.

A value that fails validation traps with a
`malformed ACERVO_CDN_BASE_URL: <value>` `fatalError`.

### Value format

- **MUST** include the path prefix that `<slug>/<file>` is appended to — the
  `/models` segment in the example. SwiftAcervo builds file URLs as
  `<cdnBaseURL>/<slug>/<fileName>` and the manifest URL as
  `<cdnBaseURL>/<slug>/manifest.json`.
- **MUST NOT** have a trailing slash (it is stripped if present, but don't rely
  on that).
- **MUST** be `https://`.

---

## Allowed-host derivation (`SecureDownloadSession`)

`Acervo.cdnAllowedHost` returns the `host` component of `Acervo.cdnBaseURL`
(guaranteed present by the validation above). `SecureDownloadSession` follows an
HTTP redirect only when the redirect target's host equals `cdnAllowedHost`; every
other redirect is rejected, which prevents a compromised DNS or CDN edge from
silently steering a download to a malicious server. Because the allowed host is
derived from the same configured base URL, there is exactly one source of truth.

---

## How UI apps configure it (Info.plist)

Add the key to your app target's `Info.plist`:

```xml
<key>AcervoCDNBaseURL</key>
<string>https://cdn.intrusive-memory.productions/models</string>
```

No code change is required — SwiftAcervo reads it from `Bundle.main` on first use.

---

## How CLI / tests / CI configure it (environment variable)

### Shell / CLI

```sh
export ACERVO_CDN_BASE_URL=https://cdn.intrusive-memory.productions/models
```

Typically placed in `~/.zprofile` for interactive shells, or exported in a CI
job's environment block.

### Test targets (xctest)

> **Important:** `xcodebuild` does **not** propagate the shell environment to the
> `xctest` runner process. Exporting `ACERVO_CDN_BASE_URL` in your shell or CI
> step is **not** enough for tests — the value must travel through the **test
> plan**.

Add the variable to the test plan's `environmentVariableEntries`. In this repo
all three plans under
`.swiftpm/xcode/xcshareddata/xctestplans/` already carry it:

```json
"environmentVariableEntries" : [
  {
    "key" : "ACERVO_CDN_BASE_URL",
    "value" : "https://cdn.intrusive-memory.productions/models"
  }
]
```

This is the same channel used for `ACERVO_APP_GROUP_ID`.

---

## Relationship to the CLI's `R2_PUBLIC_URL`

`acervo verify` (CDN mode) resolves its public base URL from a **different**
variable, `R2_PUBLIC_URL`, and by a **different convention**:

- `R2_PUBLIC_URL` is **domain-only** (no `/models` suffix), e.g.
  `https://cdn.intrusive-memory.productions`. The `verify` command appends
  `/models/<slug>/manifest.json` itself.
- `ACERVO_CDN_BASE_URL` **includes** the `/models` path prefix.

The two are intentionally **not** cross-wired. `R2_PUBLIC_URL` likewise has no
hardcoded default: `acervo verify` in CDN mode fails cleanly (non-zero exit,
stderr guidance) when it is unset or malformed.

---

## Fixing a broken consumer (migration playbook)

This is a **breaking configuration change**. Before it, a CDN host was compiled
into the library; now there is none. Any consumer that has not supplied a value
will crash on the first SwiftAcervo call that needs the CDN — `download`,
`ensureComponentReady`, `fetchManifest`, etc.

### 1. Recognize the crash

The trap comes from `Acervo.cdnBaseURL` and looks like this:

```
SwiftAcervo: no CDN base URL configured.

UI apps: add the AcervoCDNBaseURL key to your Info.plist.
CLI tools / scripts / test runners / CI: export ACERVO_CDN_BASE_URL ...
```

(If you instead see `malformed ACERVO_CDN_BASE_URL: <value>`, the value *is* set
but isn't a valid `https://…` URL with a host — fix the value, see
[Value format](#value-format).)

It is the exact sibling of the existing `no App Group identifier configured`
trap. If you already configure `ACERVO_APP_GROUP_ID`, set the CDN URL **the same
way, in the same place**.

### 2. Find your consumer type

| You are… | Who sets the value | Fix |
| --- | --- | --- |
| A **UI app** (the app target that ships to users) | The app | `Info.plist` key — §3 |
| A **library that depends on SwiftAcervo** (e.g. SwiftBruja, mlx-audio-swift) | **Not you — the app that embeds you** | §4 (do *not* hardcode it) |
| A **CLI tool / script** | The process environment | `export` — §5 |
| A **test target** (xctest via `xcodebuild`) | The test plan or the runner env | §6 |
| A **CI pipeline** | The workflow | §6 / §7 |

### 3. UI app — `Info.plist`

Static:

```xml
<key>AcervoCDNBaseURL</key>
<string>https://cdn.intrusive-memory.productions/models</string>
```

Per-environment (staging vs prod) via build settings — define `ACERVO_CDN_BASE_URL`
in each `.xcconfig`, then reference it with Info.plist variable substitution:

```xml
<key>AcervoCDNBaseURL</key>
<string>$(ACERVO_CDN_BASE_URL)</string>
```

No code change is needed — SwiftAcervo reads `Bundle.main` on first use.

### 4. A library that depends on SwiftAcervo — **do not set it**

This is the case most likely to be done wrong. If your library (SwiftBruja,
mlx-audio-swift, etc.) just *re-exports* SwiftAcervo's download capability to an
app, then:

- **Your library code sets nothing.** The CDN host is a deployment decision that
  belongs to the **embedding app**, not to you. Hardcoding it in your library
  re-introduces exactly the lock-in this change removed and overrides the app's
  choice.
- **You DO fix two things in your own repo:**
  1. **Your test target** — so your CI goes green again (§6).
  2. **Any example / demo app** you ship — add the `Info.plist` key (§3).
- **Propagate the contract downstream.** Add one line to your library's README:
  *"Consumers must configure SwiftAcervo's CDN base URL — set `ACERVO_CDN_BASE_URL`
  (CLI/tests) or the `AcervoCDNBaseURL` Info.plist key (apps). See
  SwiftAcervo's CDN_CONFIGURATION.md."*

### 5. CLI tool / script — environment variable

```sh
export ACERVO_CDN_BASE_URL=https://cdn.intrusive-memory.productions/models
```

Put it in `~/.zprofile` for interactive use, or in the launch context
(`launchd`/`systemd` unit, wrapper script, container env) for a packaged tool.

### 6. Test target (xctest) — two ways

`xcodebuild` does **not** forward your shell environment to the `xctest` runner,
so `export`-ing in the CI step is **not enough**. Pick one:

**(a) Test plan (persistent).** Add to the plan's `environmentVariableEntries`:

```json
"environmentVariableEntries" : [
  { "key" : "ACERVO_CDN_BASE_URL", "value" : "https://cdn.intrusive-memory.productions/models" }
]
```

**(b) `TEST_RUNNER_` prefix (no plan edit).** `xcodebuild` strips the
`TEST_RUNNER_` prefix and injects the rest into the runner process:

```sh
TEST_RUNNER_ACERVO_CDN_BASE_URL=https://cdn.intrusive-memory.productions/models \
  xcodebuild test -scheme YourScheme -destination '...'
```

This is the same mechanism SwiftAcervo documents for `ACERVO_MODELS_DIR`, and it
is the easiest path for a repo that doesn't want to edit `.xctestplan` files.

### 7. CI pipeline (GitHub Actions)

If your test step already runs through a test plan that carries the variable,
nothing more is needed. Otherwise, inject it at the `xcodebuild` call alongside
the App Group id you already set:

```yaml
- name: Test
  run: |
    TEST_RUNNER_ACERVO_CDN_BASE_URL=https://cdn.intrusive-memory.productions/models \
    TEST_RUNNER_ACERVO_APP_GROUP_ID=group.acervo.testbundle.default \
    xcodebuild test -scheme YourScheme -destination 'platform=macOS,arch=arm64'
```

### 8. `acervo verify` (CDN mode)

Separate variable, separate convention: set **`R2_PUBLIC_URL`** (domain-only, **no**
`/models` suffix), e.g. `https://cdn.intrusive-memory.productions`. It also has no
default and fails cleanly when unset.

### 9. Verify the fix

- **App / CLI:** the call that used to trap now reaches the network. A one-liner
  sanity check anywhere after launch: `print(Acervo.cdnBaseURL)` should print your
  value, not crash.
- **Tests:** the previously-trapping test now runs (and, for live tests, reaches
  the configured host).

---

## See also

- [CDN_ARCHITECTURE.md](CDN_ARCHITECTURE.md) — how downloads work end-to-end.
- [SHARED_MODELS_DIRECTORY.md](SHARED_MODELS_DIRECTORY.md) — the parallel App
  Group resolution contract this pattern mirrors.
