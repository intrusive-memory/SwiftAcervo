---
feature_name: OPERATION VAULT BROOM
starting_point_commit: 7ef2d6d96c0c8dbfa2d30e335ff8014b1effab2f
mission_branch: mission/vault-broom/02
iteration: 2
---

# EXECUTION_PLAN.md — SwiftAcervo `delete` and `recache` (v0.9.0)

**Source requirements**: [REQUIREMENTS-delete-and-recache.md](REQUIREMENTS-delete-and-recache.md)
**Target version**: 0.9.0
**Owner**: Tom Stovall

**Refinement status**: Refined 2026-05-02 — atomicity ✓, prioritization ✓, parallelism ✓, open-questions ✓. Ready to execute.

---

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure.

> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. One aircraft, one mission, one return.

> **Work Unit** — A grouping of sorties (package, component, phase).

---

## Mission Overview

Add `delete` and `recache` capabilities to SwiftAcervo. Per requirements §5, this is a **single-target architecture** — CDN mutation surface lives in the main `SwiftAcervo` library, with R2 IAM as the security boundary. The `acervo` CLI becomes a thin wrapper.

Three layered API tiers:
- **Layer 1**: `SigV4Signer` (pure crypto)
- **Layer 2**: `S3CDNClient` (URLSession + signing, list/put/delete/head, multipart)
- **Layer 3**: `Acervo.publishModel`, `Acervo.deleteFromCDN`, `Acervo.recache` (orchestration)

CLI side: new `acervo delete` and `acervo recache` subcommands; `ship` and `upload` rewritten on `publishModel`; `CDNUploader` and `aws`-binary shell-out removed; `ToolCheck` shrinks to `hf` only.

---

## Work Units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|-----------|-----------|---------|-------|--------------|
| WU1: CDN mutation library (SigV4 + S3CDNClient) | `Sources/SwiftAcervo/` | 3 | 1 | none |
| WU2: Orchestration API (publishModel / deleteFromCDN / recache) | `Sources/SwiftAcervo/` | 3 | 2 | WU1 |
| WU3: CLI migration (new commands + ship/upload rewrite + cleanup) | `Sources/acervo/` | 3 | 3 | WU2 |
| WU4: Documentation, version bump, Homebrew formula | repo + `../homebrew-tap/` | 3 | 4 | WU3 |

Within a work unit, sorties are sequential. Across work units, layers gate (Layer N+1 cannot start until Layer N is COMPLETED).

---

## WU1: CDN mutation library (SigV4 + S3CDNClient)

### Sortie 1: SigV4 signing primitives + canonical AWS test vectors

**Priority**: 38 — Foundation crypto layer; 11 downstream sorties depend on signing primitives. New tech (SigV4 from scratch) → highest risk score.

**Entry criteria**:
- [ ] First sortie — no prerequisites.

**Tasks**:
1. Create `Sources/SwiftAcervo/AcervoCDNCredentials.swift` defining `public struct AcervoCDNCredentials: Sendable` with fields `accessKeyId`, `secretAccessKey`, `region`, `bucket`, `endpoint: URL`, `publicBaseURL: URL`, plus a public memberwise initializer. Default `region` to `"auto"` and `bucket` to `"intrusive-memory-models"` per requirements §6.1.
2. Create `Sources/SwiftAcervo/SigV4Signer.swift` defining `public struct SigV4Signer: Sendable` and a `public enum PayloadHash { case empty, precomputed(String), unsignedPayload }`. Implement the `sign(_ request: URLRequest, payloadHash: PayloadHash, date: Date = Date()) -> URLRequest` method per requirements §6.2. Use `CryptoKit.HMAC<SHA256>` for the four-step key derivation; produce `Authorization`, `x-amz-date`, and `x-amz-content-sha256` headers. Mutate nothing — return a copy.
3. Add `Tests/SwiftAcervoTests/SigV4SignerTests.swift` that vendors the **canonical AWS SigV4 test suite vectors** verbatim (per Q12 / Decision Log #12) and asserts the signer produces the documented `Authorization` header for each vector. Cover at least: `get-vanilla`, `get-vanilla-query`, `get-header-key-duplicate`, `post-vanilla`, `post-x-www-form-urlencoded`. If the canonical test suite contains additional vectors relevant to GET/PUT/DELETE on S3-shaped requests, include those.
4. Add a unit test that signs a synthetic R2-shaped `PUT` request with `payloadHash: .precomputed("…")` and asserts the `x-amz-content-sha256` header equals the supplied hash.

**Exit criteria**:
- [ ] `make build` succeeds.
- [ ] `make test` runs `SigV4SignerTests` and all canonical AWS vector cases pass.
- [ ] `git grep -nE "import (Foundation|CryptoKit)" Sources/SwiftAcervo/SigV4Signer.swift` shows only Foundation + CryptoKit imports (no third-party deps per §5).
- [ ] No new entries in `Package.swift` `dependencies:` array.

---

### Sortie 2: `S3CDNClient` — list / head / delete / deleteObjects

**Priority**: 35 — Foundation S3 client (non-PUT ops); 10 downstream sorties depend on it. Establishes XML parsing, pagination, and 404-as-success conventions reused by every later operation.

**Entry criteria**:
- [ ] Sortie 1 COMPLETED (`SigV4Signer` available).

**Tasks**:
1. Create `Sources/SwiftAcervo/S3CDNClient.swift` defining `public actor S3CDNClient` with the initializer `init(credentials: AcervoCDNCredentials, session: URLSession = .shared)` per requirements §6.3.
2. Define supporting public types in the same file `Sources/SwiftAcervo/S3CDNClient.swift`: `S3Object` (key, size, etag), `S3ObjectHead` (size, etag, contentType?, lastModified), `S3PutResult` (key, etag, sha256), `S3DeleteResult` (key, success, error?).
3. Implement `listObjects(prefix:) async throws -> [S3Object]` using S3 `ListObjectsV2`, paginating via `NextContinuationToken` until `IsTruncated=false`. Parse XML response (Foundation `XMLParser` is acceptable; document the parser choice in code comment if non-obvious).
4. Implement `headObject(key:) async throws -> S3ObjectHead?` that returns `nil` on 404 and throws `AcervoError.cdnAuthorizationFailed(operation: "head")` on 401/403. **Define `case cdnAuthorizationFailed(operation: String)` on `Sources/SwiftAcervo/AcervoError.swift` now** (the remaining three new error cases are added in WU2 Sortie 1). This avoids a TODO/placeholder and keeps the tree compiling cleanly through the layer boundary.
5. Implement `deleteObject(key:) async throws` — 404 is **not** an error (idempotent per requirements §6.3).
6. Implement `deleteObjects(keys: [String]) async throws -> [S3DeleteResult]` using S3 `DeleteObjects` POST, batching at the 1000-key limit. For inputs >1000 keys, the actor itself batches and concatenates results.
7. Add `Tests/SwiftAcervoTests/S3CDNClientTests.swift` covering: list pagination across 2 pages (mock `URLProtocol`), head 200 / 404 / 403, delete 204 / 404 (both succeed), bulk delete with mixed success/failure response. Use a `URLProtocol`-based mock — do not hit a real R2 bucket in unit tests.

**Exit criteria**:
- [ ] `make build` succeeds.
- [ ] `make test` runs `S3CDNClientTests`; all cases pass.
- [ ] `deleteObject` test asserts 404 returns success (no throw).
- [ ] `listObjects` test asserts second page is fetched and concatenated when `IsTruncated=true` on page 1.
- [ ] No live network calls in test target (verified by `grep -nE "URLSession\.shared|cloudflarestorage" Tests/SwiftAcervoTests/S3CDNClientTests.swift` returning only mock-related usage).

---

### Sortie 3: `S3CDNClient.putObject` with multipart upload

**Priority**: 32 — Completes the S3 client; 9 downstream sorties depend on it. Multipart streaming is the single most algorithmically dense piece of new code in WU1.

**Entry criteria**:
- [ ] Sortie 2 COMPLETED (`S3CDNClient` skeleton + non-PUT operations available).

**Tasks**:
1. In `Sources/SwiftAcervo/S3CDNClient.swift`, implement `putObject(key:bodyURL:) async throws -> S3PutResult`. For files at or below a 100 MiB threshold (constant `singleShotThreshold`), perform a single signed `PUT` with the file body and `x-amz-content-sha256` set to the streaming SHA-256 of the file. For files above the threshold, use the S3 multipart upload protocol per Q13 / Decision Log #13.
2. Implement multipart helpers (private to the actor): `initiateMultipartUpload(key:) -> uploadId`, `uploadPart(uploadId:partNumber:bodyChunk:) -> ETag`, `completeMultipartUpload(uploadId:parts:) -> S3PutResult`, `abortMultipartUpload(uploadId:)`. Use 16 MiB part size; document the choice inline. Stream chunks from `bodyURL` via `FileHandle` — never load the whole file into memory.
3. Compute SHA-256 incrementally as bytes are read (use `CryptoKit.SHA256` `update(bufferPointer:)`). The final hash is returned in `S3PutResult.sha256`.
4. On any uploadPart failure, call `abortMultipartUpload` to clean up R2-side state, then rethrow. Do NOT retry inside the client — let the caller decide.
5. Add tests in `Tests/SwiftAcervoTests/S3CDNClientTests.swift`: single-shot PUT under threshold (assert one signed PUT request, correct sha256 returned); multipart upload over threshold (assert initiate → N upload-parts → complete sequence via `URLProtocol` mock; assert abort fires when an upload-part returns 500).
6. Add a streaming-memory test: upload a 200 MiB synthetic file (write to tmp, fill with random bytes) and assert peak resident memory growth stays under, say, 64 MiB during the upload. If the test infrastructure can't measure RSS reliably, instead assert that `FileHandle.read(upToCount:)` is called with chunk-sized buffers (no `Data(contentsOf:)` of the whole file).

**Exit criteria**:
- [ ] `make build` succeeds.
- [ ] `make test` runs the new put-object tests; all cases pass.
- [ ] `git grep -nE "Data\(contentsOf:" Sources/SwiftAcervo/S3CDNClient.swift` returns no matches (no whole-file loads).
- [ ] Single-shot PUT test asserts `S3PutResult.sha256` matches a known fixture hash.
- [ ] Multipart test asserts `abortMultipartUpload` is called exactly once when an upload-part fails.

---

## WU2: Orchestration API

### Sortie 1: New `AcervoError` cases + progress types

**Priority**: 27 — Error/progress types reused across all CDN orchestration; required by 8 downstream sorties. Low complexity, high reuse.

**Entry criteria**:
- [ ] WU1 COMPLETED.

**Tasks**:
1. In `Sources/SwiftAcervo/AcervoError.swift`, add the **three remaining** new cases per requirements §6.5 (the fourth, `cdnAuthorizationFailed(operation:)`, was already added in WU1 Sortie 2):
   - `case cdnOperationFailed(operation: String, statusCode: Int, body: String)`
   - `case publishVerificationFailed(stage: String)`
   - `case fetchSourceFailed(modelId: String, underlying: any Error)`
   Update `errorDescription` (or equivalent `LocalizedError` conformance) for each (and also for `cdnAuthorizationFailed` if not already done in WU1.S2).
2. Update `Sources/SwiftAcervo/S3CDNClient.swift` to throw `AcervoError.cdnOperationFailed` for non-2xx responses other than 401/403 (which already throw `cdnAuthorizationFailed` from WU1.S2). Confirm no remaining TODO markers reference deferred error cases.
3. Create `Sources/SwiftAcervo/AcervoPublishProgress.swift` with `public enum AcervoPublishProgress: Sendable` mirroring the publish steps from requirements §7 (e.g. `.generatingManifest`, `.verifyingManifest`, `.listingExistingKeys(found: Int)`, `.uploadingFile(name: String, bytesSent: Int64, bytesTotal: Int64)`, `.uploadingManifest`, `.verifyingPublic(stage: String)`, `.pruningOrphans(count: Int)`, `.complete`).
4. Create `Sources/SwiftAcervo/AcervoDeleteProgress.swift` with `public enum AcervoDeleteProgress: Sendable` (e.g. `.listingPrefix`, `.deletingBatch(count: Int, deletedSoFar: Int)`, `.complete`).
5. Add `Tests/SwiftAcervoTests/AcervoErrorTests.swift` (or extend an existing error test file if present) asserting each new case produces a non-empty `localizedDescription`.

**Exit criteria**:
- [ ] `make build` succeeds.
- [ ] `make test` passes.
- [ ] `git grep -n "TODO" Sources/SwiftAcervo/S3CDNClient.swift` returns no remaining error-related TODOs.
- [ ] All four new `AcervoError` cases are reachable via `git grep -n "cdnAuthorizationFailed\|cdnOperationFailed\|publishVerificationFailed\|fetchSourceFailed" Sources/SwiftAcervo/AcervoError.swift` (one added in WU1.S2, three added in this sortie).

---

### Sortie 2: `Acervo.publishModel` (atomic + orphan prune) + tests

**Priority**: 26 — Core 11-step orchestration consumed by `recache`, `ship`, and `upload`. Highest implementation complexity in the plan; lifts `ManifestGenerator` into the library.

**Entry criteria**:
- [ ] WU2 Sortie 1 COMPLETED.

**Tasks**:
1. Create `Sources/SwiftAcervo/Acervo+CDNMutation.swift` (extension on `Acervo` namespace). Implement `public static func publishModel(modelId:directory:credentials:keepOrphans:progress:) async throws -> CDNManifest` per requirements §6.4 and §7.
2. Implement the **frozen 11-step execution order** from requirements §7:
   1. Generate manifest from `directory` (reuse `ManifestGenerator` from CLI — or, since the library is gaining mutation, lift `ManifestGenerator` from `Sources/acervo/` into `Sources/SwiftAcervo/`; choose lift-into-library to keep CLI thin per §6.7).
   2. CHECK 2 — refuse zero-byte files (already in `ManifestGenerator`).
   3. CHECK 3 — re-read manifest, verify checksum-of-checksums.
   4. CHECK 4 — re-hash every staged file against the manifest (reuse `IntegrityVerification`).
   5. List existing keys under `models/<slug>/` via `S3CDNClient.listObjects`.
   6. PUT every manifest file via `S3CDNClient.putObject`.
   7. PUT `manifest.json` LAST.
   8. CHECK 5 — fetch `manifest.json` from `credentials.publicBaseURL` and verify checksum.
   9. CHECK 6 — fetch one file (`config.json` if present, else first manifest entry) and verify SHA-256.
   10. Compute orphans = `existing_keys − new_manifest_keys − {manifest.json}`.
   11. If `keepOrphans == false`, delete orphans via `S3CDNClient.deleteObjects` in batches of 1000.
3. Emit `AcervoPublishProgress` callbacks at each step boundary and per-file during step 6.
4. Failure semantics per requirements §7: throws specific `AcervoError.publishVerificationFailed(stage:)` for CHECK failures; partial-prune failure includes the orphan list in the thrown error so the caller can retry.
5. Lift `ManifestGenerator` from `Sources/acervo/ManifestGenerator.swift` to `Sources/SwiftAcervo/ManifestGenerator.swift`; make it `public` so the library can call it. Update `Sources/acervo/` callers.
6. Add `Tests/SwiftAcervoTests/PublishModelTests.swift` covering:
   - Happy path: synthetic 3-file model staging dir → mock `S3CDNClient` (use `URLProtocol`) → assert manifest is the LAST PUT, exit `CDNManifest` matches generated manifest.
   - Orphan prune: existing keys include 2 stale files not in the new manifest → assert `deleteObjects` is called with exactly those 2 keys.
   - `keepOrphans: true`: assert `deleteObjects` is NOT called.
   - CHECK 5 failure: mock public `manifest.json` to return a corrupted body → assert `AcervoError.publishVerificationFailed(stage: "CHECK 5")` is thrown.
   - CHECK 6 failure: similar.
   - Partial-prune failure: orphan delete batch returns errors → asserted error contains the failed key list.

**Exit criteria**:
- [ ] `make build` succeeds.
- [ ] `make test` passes; all `PublishModelTests` cases pass.
- [ ] `git grep -n "ManifestGenerator" Sources/acervo/` shows the type is **imported from** `SwiftAcervo`, not redefined locally.
- [ ] Happy-path test asserts the order of S3 mutations: every file PUT precedes the `manifest.json` PUT (verifiable via mock recorder).
- [ ] Orphan-prune test asserts `deleteObjects` invocation count is correct (1 batch for ≤1000 orphans).

---

### Sortie 3: `Acervo.deleteFromCDN` + `Acervo.recache` + tests

**Priority**: 22 — Completes Layer 3 orchestration. `recache` is a 5-line composition over `publishModel`; `deleteFromCDN` is the lone non-atomic primitive.

**Entry criteria**:
- [ ] WU2 Sortie 2 COMPLETED.

**Tasks**:
1. In `Sources/SwiftAcervo/Acervo+CDNMutation.swift`, implement `public static func deleteFromCDN(modelId:credentials:progress:) async throws` per requirements §7:
   1. List `models/<slug>/`.
   2. Bulk-delete returned keys (1000 at a time).
   3. Re-list.
   4. If non-empty, repeat 2–3.
   Loop terminates when the listing is empty. Idempotent: empty initial listing returns immediately. Emit `AcervoDeleteProgress` callbacks per batch.
2. Implement `public static func recache(modelId:stagingDirectory:credentials:fetchSource:keepOrphans:progress:) async throws -> CDNManifest` per requirements §6.4:
   - Call `fetchSource(modelId, stagingDirectory)`. If it throws, wrap in `AcervoError.fetchSourceFailed`.
   - Then call `Acervo.publishModel(modelId:directory:credentials:keepOrphans:progress:)` with the same staging directory.
3. Add `Tests/SwiftAcervoTests/DeleteFromCDNTests.swift`:
   - Happy path: 3 keys exist → one bulk-delete batch → re-list returns empty → returns successfully.
   - Multi-page: 1500 keys → assert two batches (1000 + 500) are issued.
   - Empty prefix: zero keys initially → no bulk-delete called → returns immediately (idempotent).
   - Batch failure: a batch throws → `deleteFromCDN` rethrows.
4. Add `Tests/SwiftAcervoTests/RecacheTests.swift`:
   - Happy path: `fetchSource` populates staging with N files → `publishModel` is invoked with that directory → returns the manifest.
   - `fetchSource` throws → `AcervoError.fetchSourceFailed` is thrown with the underlying error attached.

**Exit criteria**:
- [ ] `make build` succeeds.
- [ ] `make test` passes; all `DeleteFromCDNTests` and `RecacheTests` cases pass.
- [ ] Multi-page delete test asserts exactly 2 `deleteObjects` invocations for 1500 keys.
- [ ] Idempotent test asserts zero `deleteObjects` invocations for an empty prefix.
- [ ] `recache` failure test asserts `AcervoError.fetchSourceFailed.underlying` equals the closure's thrown error.

---

## WU3: CLI migration

### Sortie 1: Remove `CDNUploader` and `aws` shell-out; shrink `ToolCheck`

**Priority**: 16 — Cleanup pre-rewrite. Required to keep the tree compiling cleanly while WU3 Sorties 2/3 land the new commands.

**Entry criteria**:
- [ ] WU2 COMPLETED.

**Tasks**:
1. Delete `Sources/acervo/CDNUploader.swift`.
2. In `Sources/acervo/ToolCheck.swift`, remove any `requireAWS()` / `aws`-binary check. Retain only `hf` validation. Update any references in other CLI files.
3. In `Sources/acervo/ProcessRunner.swift`, leave the type itself but remove any `aws`-specific wrappers/helpers if present.
4. Update `Sources/acervo/UploadCommand.swift` and `Sources/acervo/ShipCommand.swift` to remove their `CDNUploader` usage and replace each `run()` body with `fatalError("rewritten in WU3 Sortie 3 — do not invoke")`. Keep the `AsyncParsableCommand` declarations and existing flag definitions intact so the binary still parses arguments. The `@available(*, unavailable)` alternative is **not** chosen — runtime fatalError keeps the diff smallest and avoids touching the ArgumentParser registration in `AcervoCLI`.
5. Audit: `git grep -nE "\baws\b|CDNUploader|requireAWS" Sources/acervo/` should return no matches except possibly in error messages or comments referencing the removal.
6. Update `Sources/acervo/AcervoCLI.swift` if any registration referenced removed types.

**Exit criteria**:
- [ ] `make build` succeeds (compile-clean tree, even if `ship`/`upload` commands fatalError at runtime — they'll be rewritten next).
- [ ] `git grep -nE "\baws\b|CDNUploader|requireAWS" Sources/acervo/` returns no production-code matches.
- [ ] `git ls-files Sources/acervo/CDNUploader.swift` returns nothing (file is gone).
- [ ] `make test` for `AcervoToolTests` passes (any tests that depended on `CDNUploader` are deleted or rewritten — note in commit message which tests were touched).

---

### Sortie 2: New `acervo delete` command + TTY confirmation utility

**Priority**: 16 — Adds `delete` plus the TTY confirmation helper, which is also reused by `recache` in WU3.S3.

**Entry criteria**:
- [ ] WU3 Sortie 1 COMPLETED.

**Tasks**:
1. Create `Sources/acervo/TTYConfirm.swift` with a `func confirmOnTTY(prompt: String, yesBypass: Bool) throws -> Bool` helper per requirements §8 Q4 / Decision Log #4. If `yesBypass == true`, return `true` immediately. If stdin is a TTY (`isatty(STDIN_FILENO) != 0`), prompt and read a line; return `true` for `y`/`yes`. If non-TTY (CI) and `yesBypass == false`, throw a clear error message instructing the user to pass `--yes`.
2. Create `Sources/acervo/DeleteCommand.swift` defining `struct DeleteCommand: AsyncParsableCommand`. Flags per requirements §6.6:
   - `<model-id>` positional argument.
   - `--local` (flag) — implies both `--staging` and `--cache`.
   - `--staging` (flag) — delete `STAGING_DIR/<slug>` only.
   - `--cache` (flag) — delete the App Group cache via `Acervo.deleteModel(_:)`.
   - `--cdn` (flag) — delete from CDN via `Acervo.deleteFromCDN(...)`.
   - `--dry-run` (flag) — print intended actions, perform none.
   - `--yes` (flag) — bypass TTY confirmation.
   - At least one of `--local` / `--staging` / `--cache` / `--cdn` is required (validate; otherwise throw a `ValidationError`).
3. Implement the command's `run()`:
   - For `--cdn` (destructive): call `confirmOnTTY` with a clear prompt; if the user declines, exit with code 0 and a "cancelled" message.
   - Resolve credentials via env vars (`R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT`, `R2_PUBLIC_BASE_URL`, optional `R2_BUCKET` defaulting to `intrusive-memory-models`). Error clearly if any required env var is missing.
   - Wire `AcervoDeleteProgress` callback into `ProgressReporter`.
4. Register `DeleteCommand.self` in `AcervoCLI.subcommands` in `Sources/acervo/AcervoCLI.swift`.
5. Add `Tests/AcervoToolTests/DeleteCommandTests.swift`: argument-validation tests (missing flags throws; mutually-compatible flag combinations parse), dry-run prints actions without invoking deletes, `--yes` skips the TTY prompt path. Use a mock credentials provider where possible to avoid env-var coupling in tests.

**Exit criteria**:
- [ ] `make build` succeeds.
- [ ] `make install-acervo && bin/acervo delete --help` shows all flags.
- [ ] `make test` passes; `DeleteCommandTests` covers argument validation, dry-run, and `--yes` paths.
- [ ] `bin/acervo delete some/model` (no flags) exits non-zero with a clear error stating at least one flag is required.
- [ ] `bin/acervo delete some/model --cdn` in a non-TTY pipe (e.g. `echo "" | bin/acervo delete some/model --cdn`) exits non-zero instructing the user to pass `--yes`.

---

### Sortie 3: New `acervo recache` + rewrite `ship` / `upload` on top of `publishModel`

**Priority**: 11 — Last code-bearing sortie. Three CLI files all rewriting to the same `Acervo.publishModel` call site — coherent concern, mechanical changes.

**Entry criteria**:
- [ ] WU3 Sortie 2 COMPLETED.

**Tasks**:
1. Create `Sources/acervo/RecacheCommand.swift` per requirements §6.6:
   - `<model-id>` positional + optional `[files...]` positional list.
   - Same env-var-based credential resolution as `DeleteCommand`.
   - `--keep-orphans` flag (forwarded to `Acervo.recache`).
   - `--yes` flag — required when running non-TTY because the orphan prune is destructive (per §8 Q4).
   - The `fetchSource` closure shells out to `hf` (use existing `HuggingFaceClient` or `ProcessRunner` patterns). The library never sees `hf`.
   - Wire `AcervoPublishProgress` callbacks through `ProgressReporter`.
2. Rewrite `Sources/acervo/ShipCommand.swift` to call `Acervo.publishModel(...)` directly with `keepOrphans: true` (per Decision Log #11, `ship == recache − orphan prune`). Preserve the existing CLI flags so this is non-breaking from a user's perspective.
3. Rewrite `Sources/acervo/UploadCommand.swift` to call `Acervo.publishModel(...)` directly. Preserve existing flags.
4. Register `RecacheCommand.self` in `AcervoCLI.subcommands`.
5. Verify `Sources/acervo/` no longer contains any direct S3 / CDN code paths — everything goes through `Acervo.publishModel` / `Acervo.deleteFromCDN`. Audit: `git grep -nE "putObject|deleteObject|listObjects|SigV4|S3CDNClient" Sources/acervo/` should return no matches.
6. Add `Tests/AcervoToolTests/RecacheCommandTests.swift`: argument-validation, `fetchSource` invocation order (fetch before publish), env-var resolution. Update `ShipCommandTests` and `UploadCommandTests` (if they exist) to reflect the new implementation; otherwise add minimal coverage.

**Exit criteria**:
- [ ] `make build` succeeds.
- [ ] `make install-acervo && bin/acervo recache --help && bin/acervo ship --help && bin/acervo upload --help` all succeed.
- [ ] `make test` passes; new `RecacheCommandTests` cases pass.
- [ ] `git grep -nE "putObject|deleteObject|listObjects|SigV4|S3CDNClient" Sources/acervo/` returns zero matches (CLI is a thin wrapper).
- [ ] `bin/acervo --help` lists `delete`, `recache`, `download`, `manifest`, `ship`, `upload`, `verify` as subcommands.

---

## WU4: Documentation, version bump, Homebrew formula

### Sortie 1: Library + CLI documentation update

**Priority**: 7 — Documentation update across 7 files. Internally parallelizable across sub-agents (see Parallelism Structure below).

**Entry criteria**:
- [ ] WU3 COMPLETED.

**Tasks**:
1. Update `CDN_UPLOAD.md`:
   - Add an "IAM key scoping" section (per requirements §5 operational guidance): maintainer/CI keys get full RW+delete; runtime keys (if any) get GET/HEAD only; mutation keys must never ship in app bundles.
   - Add a "Concurrent publishes are not supported in v0.9" warning (per Decision Log #5).
   - Update the pipeline section to show the new `acervo recache` / `acervo delete` / library `Acervo.publishModel` examples; remove `aws`-binary instructions.
2. Update `CDN_ARCHITECTURE.md`:
   - Add a "Mutation layer" section describing the three-layer API (SigV4Signer / S3CDNClient / publishModel-deleteFromCDN-recache).
   - Note that the runtime read path is unchanged (`SecureDownloadSession` + public CDN URLs, no credentials).
3. Update `API_REFERENCE.md` to document the new public surface: `AcervoCDNCredentials`, `SigV4Signer`, `S3CDNClient`, `Acervo.publishModel`, `Acervo.deleteFromCDN`, `Acervo.recache`, `AcervoPublishProgress`, `AcervoDeleteProgress`, and the four new `AcervoError` cases.
4. Update `USAGE.md` with a "Programmatic CDN mutation" example showing a minimal `publishModel` call from a CI script context.
5. Update `README.md` with a one-paragraph mention of the new mutation API and a link to `CDN_UPLOAD.md`.
6. Update `CLAUDE.md` and `AGENTS.md` Quick Reference sections: bump version line, add bullets for the three new orchestration calls, mention single-target architecture, mention `aws`-binary removal.
7. Cross-check: every public API added in WU1/WU2 appears in `API_REFERENCE.md`. Every CLI command added in WU3 appears in `BUILD_AND_TEST.md` (under acervo CLI examples).

**Exit criteria**:
- [ ] `git diff --stat` shows updates in all of: `CDN_UPLOAD.md`, `CDN_ARCHITECTURE.md`, `API_REFERENCE.md`, `USAGE.md`, `README.md`, `CLAUDE.md`, `AGENTS.md`.
- [ ] `git grep -n "aws s3\|awscli\|aws binary" *.md` returns no remaining instructions to install or invoke `aws` (only historical/contextual mentions remain, if any).
- [ ] `git grep -n "publishModel\|deleteFromCDN\|recache(" API_REFERENCE.md` returns matches for all three.
- [ ] `git grep -n "v0.9\|0.9.0" README.md CLAUDE.md AGENTS.md` returns matches in all three.

---

### Sortie 2: Version bump to 0.9.0

**Priority**: 4 — Mechanical version bump. Smallest sortie in the plan.

**Entry criteria**:
- [ ] WU4 Sortie 1 COMPLETED.

**Tasks**:
1. Update `Sources/acervo/Version.swift` to `0.9.0`.
2. Update the Quick Reference version in `CLAUDE.md` (currently `0.8.5-dev` → `0.9.0`). Mirror in `AGENTS.md` if it tracks version.
3. If a `CHANGELOG.md` exists, add a `## 0.9.0 — <date>` entry summarizing: new `delete`/`recache` commands, new `Acervo.publishModel`/`deleteFromCDN`/`recache` library API, native SigV4 (no `aws`-binary dependency), new error cases, four progress types. Mark breaking change: removal of `CDNUploader` (was internal but documented).
4. Verify `bin/acervo --version` prints `0.9.0` after `make install-acervo`.
5. Verify `Package.swift` does not need a version bump (SPM uses tags) and confirm no new entries in `dependencies:`.

**Exit criteria**:
- [ ] `bin/acervo --version` prints `0.9.0`.
- [ ] `git grep -n "0.8.5\|0.8.5-dev" -- ':!*.lock' ':!Tests/'` returns no matches in Sources/ or top-level docs.
- [ ] `git grep -nE "^### |^## " CHANGELOG.md | head -3` shows the new 0.9.0 entry at the top (if CHANGELOG exists).
- [ ] `make test` still passes after the bump.

---

### Sortie 3: Homebrew tap formula update (`../homebrew-tap/Formula/acervo.rb`)

**Priority**: 2 — External sequencing constraint (waits for v0.9.0 tag + release artifact). Sortie prepares the change on a branch, does not push or merge.

**Entry criteria**:
- [ ] WU4 Sortie 2 COMPLETED.
- [ ] Note: per requirements §6.8 sequencing constraint, the formula PR **must not be merged** until `v0.9.0` is tagged and the release artifact is published. This sortie prepares the formula change on a branch and stops before merge.

**Tasks**:
1. Open `../homebrew-tap/Formula/acervo.rb`. Remove `depends_on "awscli"` (line 11 per requirements §6.8). Confirm `depends_on "hf"` (or equivalent) remains.
2. Update the `caveats` block: drop the "AWS CLI v2 for R2 CDN uploads" line. The list of automatically-installed dependencies should show only `hf`.
3. Bump `url`, `sha256`, and `version` to the new release tag (`v0.9.0`). If the release artifact is not yet published at sortie execution time, leave a clearly-marked placeholder with a TODO and stop — do not commit incorrect SHA values. The supervisor reports back so the human can complete the bump after tagging.
4. Run the formula's test block (`brew test acervo`) if the release artifact exists; otherwise skip and document.
5. Audit sibling formulae in `../homebrew-tap/Formula/` for transitive `awscli` assumptions: `ls ../homebrew-tap/Formula/ && grep -l "awscli" ../homebrew-tap/Formula/*.rb`. If any other formula still depends on `acervo` indirectly and needs `awscli` for an unrelated reason, report it; do not modify those files in this sortie.
6. Commit the formula change on a branch named `acervo-v0.9.0` in `../homebrew-tap/`. **Do NOT push or merge** — exit reporting that the PR is ready for human review and pending the v0.9.0 tag publication.

**Exit criteria**:
- [ ] `../homebrew-tap/Formula/acervo.rb` no longer contains `depends_on "awscli"`.
- [ ] The `caveats` block no longer mentions AWS CLI.
- [ ] `git -C ../homebrew-tap status` shows the formula on a branch named `acervo-v0.9.0`, committed, **not pushed**.
- [ ] `git -C ../homebrew-tap log --oneline -1` shows a commit message referencing the v0.9.0 bump and `awscli` removal.
- [ ] Sortie report includes: (a) any sibling-formula `awscli` matches found, (b) whether `sha256` was filled in or left as a TODO pending the release tag.

---

## Parallelism Structure

**Critical path** (12 sorties, fully serial across work units):

```
WU1.S1 → WU1.S2 → WU1.S3 → WU2.S1 → WU2.S2 → WU2.S3 → WU3.S1 → WU3.S2 → WU3.S3 → WU4.S1 → WU4.S2 → WU4.S3
```

**Why mostly serial:** strict layering is intentional (signer → client → put-with-multipart; errors → publish → delete/recache; cleanup → new commands → ship/upload rewrite; docs → version → formula). Each layer depends on the prior layer's API surface.

**Parallel execution groups** (only one cluster benefits from sub-agents):

- **WU4.S1 — Documentation update (4 sub-agents possible):**
  Eight unrelated docs files can be updated concurrently because they share no file dependencies. Supervising agent runs the final cross-check audit (last task in the sortie) sequentially.
  - **Sub-agent A (no build):** `CDN_UPLOAD.md`, `CDN_ARCHITECTURE.md`
  - **Sub-agent B (no build):** `API_REFERENCE.md`, `USAGE.md`
  - **Sub-agent C (no build):** `README.md`
  - **Sub-agent D (no build):** `CLAUDE.md`, `AGENTS.md`
  - **Supervising agent (sequential after sub-agents):** cross-check audit (Task #7) verifying every public API added in WU1/WU2 appears in `API_REFERENCE.md` and every CLI command added in WU3 appears in `BUILD_AND_TEST.md`.

**Agent constraints:**

- **Supervising agent**: handles all sorties with `make build` / `make test` / `make install-acervo` / `bin/acervo --version` / `git grep` audit steps — i.e. every sortie except WU4.S1 sub-agents A–D.
- **Sub-agents (up to 4)**: only WU4.S1 doc-cluster work. **No build operations.** All other sorties are supervising-agent-only because every one has a build/test gate in its exit criteria.

**Missed opportunities considered and rejected:**

- WU2.S1 (errors + progress types) could in principle split into two parallel sub-agents (errors vs progress types), but both are tiny (~30 LoC each) and the build gate must run after both. Not worth the orchestration overhead.
- WU3.S2 + WU3.S3 cannot run in parallel: WU3.S3's `RecacheCommand` calls the `confirmOnTTY` helper that WU3.S2 creates.
- WU4.S2 + WU4.S3 cannot run in parallel: the formula update consumes the version string the version-bump sortie writes.

**Metrics:**

- Maximum parallelism: 4 sub-agents (WU4.S1 only)
- Effective parallelism for the rest of the plan: 1
- Build-restricted sorties (supervising agent only): 11 of 12

---

## Open Questions & Missing Documentation

### Items resolved during refinement (auto-fixed)

| Sortie | Issue Type | Original | Resolution |
|--------|-----------|----------|------------|
| WU1.S2 Task #4 | Open question | "throw a `URLError` with a TODO until WU2 lands; alternatively, define the error case here in advance" — two options, no decision | Define `cdnAuthorizationFailed(operation: String)` in `AcervoError.swift` now (in WU1.S2). WU2.S1 adds the remaining three error cases. Avoids a TODO/placeholder altogether. |
| WU1.S2 Task #2 | Vague criterion | "in the same file (or a sibling file `S3CDNTypes.swift` if cleaner)" — flexibility without decision | Locked to `Sources/SwiftAcervo/S3CDNClient.swift`. One file, deterministic agent action. |
| WU3.S1 Task #4 | Open question | "Pick whichever leaves the tree compiling cleanly with the smallest diff" — two options (`fatalError` vs `@available(*, unavailable)`) | Locked to `fatalError("rewritten in WU3 Sortie 3 — do not invoke")`. Rationale: avoids touching `AcervoCLI` registration; `AsyncParsableCommand` declarations stay intact. |
| WU2.S1 Task #1 | Cross-sortie consistency | Originally instructed adding 4 error cases including `cdnAuthorizationFailed`, which now lives in WU1.S2 | Updated to add only 3 cases; exit-criteria grep reworded accordingly. |

### Items requiring human attention (none blocking)

- **WU4.S3 Task #3** — sortie may discover the v0.9.0 release artifact has not yet been tagged at execution time. Sortie has well-defined fallback (leave SHA placeholder, stop). This is **expected behavior**, not a blocker. The supervisor should treat WU4.S3 as a "deferred sortie" waiting on the external tag-and-release event.
- **Forward-reference in WU2.S2 Task #1** — chooses to lift `ManifestGenerator` from `Sources/acervo/` into `Sources/SwiftAcervo/`. This is the final answer per requirements §6.7; the alternative ("reuse from CLI") is documented as discarded.

### Verification

- No remaining "TBD", "TODO", "decide later", or "either-or" markers in the plan.
- Every sortie has at least one machine-verifiable exit criterion (build, test, file-exists, or git-grep check).
- Every entry criterion names a specific predecessor sortie or "first sortie".

---

## Summary

| Metric | Value |
|--------|-------|
| Work units | 4 |
| Total sorties | 12 |
| Dependency structure | Layered (WU1 → WU2 → WU3 → WU4); sequential within each work unit |
| Critical path length | 12 sorties (no parallelism reduces it) |
| Maximum parallelism | 4 sub-agents (WU4.S1 docs only) |
| New public types | `AcervoCDNCredentials`, `SigV4Signer`, `PayloadHash`, `S3CDNClient`, `S3Object`, `S3ObjectHead`, `S3PutResult`, `S3DeleteResult`, `AcervoPublishProgress`, `AcervoDeleteProgress` |
| New public functions | `Acervo.publishModel`, `Acervo.deleteFromCDN`, `Acervo.recache` |
| New CLI subcommands | `acervo delete`, `acervo recache` |
| Removed | `CDNUploader`, `aws`-binary dependency, `ToolCheck.requireAWS()`, `awscli` Homebrew dep |
| Target release | v0.9.0 |

---

## Notes for the Supervisor

- **Strict layering**: WU1 must be COMPLETED before WU2 starts (S3CDNClient is consumed by publishModel). WU2 before WU3 (CLI imports the library). WU3 before WU4 (docs reflect the final API).
- **Within a work unit, sorties are sequential** because each builds on the prior (signer → client → put-with-multipart; errors → publish → delete/recache; cleanup → new commands → ship/upload rewrite).
- **The only parallelism opportunity** is WU4.S1's docs cluster — see "Parallelism Structure" above. Up to 4 sub-agents can update independent doc files concurrently; the supervising agent runs the cross-check audit. Every other sortie is supervising-agent-only because each has a build/test gate.
- **Sortie WU4.S3 (Homebrew) has an external sequencing constraint**: cannot merge until v0.9.0 is tagged. The sortie prepares the change and stops; the human owns the tag-then-merge handoff. Treat as a "deferred sortie" if the release artifact is not yet published — do **not** escalate to FATAL.
- **Cross-sortie error-case dependency**: `cdnAuthorizationFailed` is added in WU1.S2; the other three new `AcervoError` cases are added in WU2.S1. This was decided during refinement to avoid TODO placeholders.
