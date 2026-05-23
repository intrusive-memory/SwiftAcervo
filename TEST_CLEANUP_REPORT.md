# TEST_CLEANUP_REPORT.md

**Mission**: OPERATION VAULT BROOM 03  
**Branch**: `mission/vault-broom/03`  
**Date**: 2026-05-22  
**Status**: CLEAN SLATE — No removals, no flagged concerns

---

## Summary

All tests added or modified during VAULT BROOM 03 are CI-safe. No tests require deletion or quarantine.

---

## Removed

| File:Test | Reason | Confidence |
|-----------|--------|-----------|
| *(none)* | — | — |

---

## Flagged for Review

| File:Test | Concern | Recommended Action |
|-----------|---------|-------------------|
| *(none)* | — | — |

---

## Build Verification

```
make test: PASSED (64 tests in 11 suites)
```

All tests executed successfully. No CI-unsafe patterns detected.

---

## Details

### Test Files Reviewed

1. **CDNManifestFetchTests.swift** (2 tests, ~79 lines)
   - Intentional read-only smoke test against live R2 CDN
   - Documented as "wired into PR CI" (CLAUDE.md convention)
   - Uses proper environment variable overrides (`R2_PUBLIC_URL`, `ACERVO_CI_CDN_MODEL_SLUG`)
   - **Status**: CI-safe by design

2. **ShipCommandTests.swift** (11 tests, ~404 lines)
   - Uses `NSTemporaryDirectory()` for all staging (CI-safe)
   - All network calls mocked via `CLIMockURLProtocol`
   - Proper environment variable lifecycle: save → mutate → restore in deinit
   - Tests: argument parsing, credential resolution, `--keep-orphans` propagation, `--dry-run` short-circuit
   - **Status**: All CI-safe

3. **ToolCheckTests.swift** (5 tests, ~115 lines)
   - Uses `NSTemporaryDirectory()` with proper cleanup
   - Tests PATH-based tool discovery (hf binary availability)
   - One test captures stderr by fd redirection (lines 87–104) — intentional, isolated, properly restored
   - **Status**: All CI-safe

4. **UploadCommandTests.swift** (10 tests, ~318 lines)
   - Uses `NSTemporaryDirectory()` for all staging
   - All network calls mocked via `CLIMockURLProtocol`
   - Proper env var save/restore in deinit
   - Tests: argument parsing, credential resolution, `--keep-orphans` propagation, `--dry-run` short-circuit
   - **Status**: All CI-safe

5. **CLIMockURLProtocol.swift** (test helper, ~98 lines)
   - Hermetic URL protocol mock with thread-safe state
   - Used by CLI tests to avoid real network calls
   - **Status**: Properly implemented helper, CI-safe

---

## Checklist

- [x] No hardcoded `/Users/`, `/home/`, `~/`, `C:\Users\` paths
- [x] No unmocked HTTP/HTTPS calls to real public domains (CDN smoke test is intentional)
- [x] No tests gated by unset CI env vars
- [x] No reads from `~/.config`, `~/Library`, `%APPDATA%` without isolation
- [x] No sleep-based timing < 100ms
- [x] No `Date()`/`Date.now` assertions without time freezing (none used)
- [x] No unordered collection iteration assertions
- [x] No unseeded randomness
- [x] No `@disabled("flaky")` or `XCTSkip("flaky")` markers
- [x] No empty test bodies
- [x] No duplicate tests in the same file
- [x] `make test` exit 0

---

No action required. All tests are ready for CI.
