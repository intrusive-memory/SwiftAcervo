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

## Migration note (existing consumers)

This is a **breaking configuration change**. Before this change a CDN host was
compiled into the library; now there is none. Any consumer that has not set
`ACERVO_CDN_BASE_URL` (CLI/test/CI) or the `AcervoCDNBaseURL` `Info.plist` key
(UI apps) will **`fatalError` on the first SwiftAcervo call that needs the CDN**.

To migrate:

- **UI apps**: add the `AcervoCDNBaseURL` key to `Info.plist`.
- **CLIs / scripts / CI**: `export ACERVO_CDN_BASE_URL=...`.
- **Test targets**: add the entry to each test plan's
  `environmentVariableEntries`.
- **`acervo verify` (CDN mode)**: ensure `R2_PUBLIC_URL` is set (domain-only).

---

## See also

- [CDN_ARCHITECTURE.md](CDN_ARCHITECTURE.md) — how downloads work end-to-end.
- [SHARED_MODELS_DIRECTORY.md](SHARED_MODELS_DIRECTORY.md) — the parallel App
  Group resolution contract this pattern mirrors.
