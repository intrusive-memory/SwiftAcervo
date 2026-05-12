# REQUIREMENTS: `delete` and `recache`

**Status**: All decisions resolved. Ready for implementation.
**Target version**: 0.9.0 (breaking-API-surface bump if we expose CDN mutation publicly).
**Owner**: Tom Stovall

---

## 1. Background

The user wants two new capabilities exposed both via the `acervo` CLI and via the
`SwiftAcervo` library so that maintainer-side code (CI scripts, internal tools)
can drive them programmatically without re-implementing the orchestration:

- **`delete <model-id>`** — remove a model from the local cache and/or the CDN.
- **`recache <model-id>`** — re-fetch a model from HuggingFace and re-publish
  it to the CDN with a freshly generated manifest and SHA-256 checksums.

The expressed shape is "library-first, CLI-second" — the CLI should be a thin
wrapper around library APIs that consumers can also call.

---

## 2. What already exists

### 2.1 Library side (`Sources/SwiftAcervo/`)

- **`Acervo.deleteModel(_ modelId:)` (public)** at `Acervo.swift:1038`. Removes
  the model's directory from `sharedModelsDirectory` (the App Group container).
  Validates the model-ID slash count, throws `AcervoError.modelNotFound` if
  absent. **Local-only — does not touch the CDN.**
- **`Acervo.deleteComponent(_ componentId:)` (public)** at `Acervo.swift:1739`.
  Same shape, scoped to one component within a model.
- The library currently has **zero CDN-mutation surface**. It is read-only with
  respect to the CDN by design (manifest fetch + file download + integrity
  verification, all via `SecureDownloadSession` with redirect pinning).
- The library has **zero external dependencies** (Foundation + CryptoKit only).

### 2.2 CLI side (`Sources/acervo/`)

- `DownloadCommand`, `UploadCommand`, `ShipCommand`, `ManifestCommand`,
  `VerifyCommand` — registered in `AcervoCLI.subcommands`.
- `CDNUploader` actor handles all CDN write operations by shelling out to the
  `aws` binary via `ProcessRunner`. Reads `R2_ACCESS_KEY_ID` and
  `R2_SECRET_ACCESS_KEY` from the environment at construction time.
- `HuggingFaceClient` already calls the HF API directly via `URLSession`
  (LFS oid endpoint, tree endpoint, `HF_TOKEN` bearer auth). The only remaining
  shell-out is the actual file download (`hf download`), which we are
  intentionally keeping for Xet-protocol coverage.
- `ToolCheck` validates that `hf` and `aws` are on `PATH` before any pipeline runs.

### 2.3 Existing documentation we should not duplicate

- `CDN_UPLOAD.md` — full upload pipeline.
- `CDN_ARCHITECTURE.md` — security model for downloads.
- `REQUIREMENTS-acervo-tool.md` — the original 6-CHECK pipeline spec.

---

## 3. Goals

1. A consumer of the `SwiftAcervo` library can delete a model from the local
   cache (already possible).
2. A maintainer of the CDN, working from a script or internal tool, can:
   - Delete a model from the CDN, programmatically.
   - Trigger a full recache cycle (re-download from HF, re-upload to CDN with
     fresh manifest), programmatically.
3. The `acervo` CLI exposes both as subcommands with the same shape as `ship`.
4. The runtime library does **not** gain CDN-mutation capability that ships into
   end-user applications. (See §5 for the architectural reason.)

---

## 4. Non-goals

- Exposing CDN write/delete from the runtime `SwiftAcervo` library that
  end-user apps link against. (See §5.)
- Reimplementing `aws s3` or HF Xet protocol in pure Swift.
- Any change to the consumer-facing read path (`Acervo.download`, `ensureAvailable`,
  `ensureComponentReady`, manifest fetch, etc.).
- Touching the integrity verification chain (CHECKs 1–6) — recache reuses it.
- A garbage-collection / TTL / disk-pressure eviction policy. Out of scope here.

---

## 5. Architecture: single library with CDN mutation (DECIDED)

**Decision: Option A — add CDN-mutation surface directly to `SwiftAcervo`.**

The earlier draft proposed a two-target split to keep mutation code paths out
of end-user apps. The argument against that split: **R2 IAM is already the
security boundary**, regardless of which library target ships the code. If a
downstream contributor embeds production keys in `Info.plist`, that's a
credential-leak failure that exists for read-only keys too — it's not a
problem you fix with target boundaries. The right operational answer is to
mint read-only access keys for runtime distribution and mutation-scoped keys
only for CI / maintainer tooling. R2 supports per-key permission scoping
natively. With the credential scope correct, attempting to call
`putObject` / `deleteObject` from a runtime-keyed app simply throws an
authorization error from R2 — exactly the desired failure mode.

Code surface is the wrong place to enforce a permission boundary that the
storage backend already enforces. The earlier draft over-rotated on that.

### Operational guidance (record in `CDN_UPLOAD.md` separately)

- **Maintainer / CI keys**: full R2 read+write+delete on the
  `intrusive-memory-models` bucket.
- **Distribution keys (if any are ever needed for runtime)**: read-only,
  scoped to GET/HEAD on `models/*`. Today the runtime path uses no
  credentials at all (public CDN URLs); this is preserved.
- Keys with mutation scope must never be embedded in app bundles.

### Implications for the package

- Single SPM target, single product.
- No new package dependencies — SigV4 implemented natively in
  Foundation + CryptoKit (see §6.2).
- The `aws` binary dependency goes away entirely as a side effect.
  `ToolCheck` shrinks to just `hf`.

---

## 6. Proposed API surface

The library exposes three layers, low to high. Each is independently usable;
the high-level operations are documented as compositions of the lower ones,
not as monoliths. This is the "design primitives atomically, build simple
ops on top" rule from the design call.

```
Layer 3 (orchestration)   Acervo.recache, Acervo.publishModel,
                          Acervo.deleteFromCDN
Layer 2 (CDN operations)  S3CDNClient: list/put/delete/head with SigV4
Layer 1 (signing)         SigV4Signer: pure crypto, no networking
```

### 6.1 Configuration

```swift
public struct AcervoCDNCredentials: Sendable {
    public let accessKeyId: String
    public let secretAccessKey: String
    public let region: String        // R2 uses "auto"
    public let bucket: String        // default: "intrusive-memory-models"
    public let endpoint: URL         // S3-compatible endpoint
    public let publicBaseURL: URL    // for CHECK 5/6 + recache verification

    public init(...)
}
```

Credentials are passed in explicitly. The library **never** reads from
`ProcessInfo.environment`. Env-var resolution is the CLI's job (and any other
consumer's job). This keeps the library impossible to misuse via ambient
credentials and makes it trivial to test.

### 6.2 Layer 1 — `SigV4Signer`

Pure-Swift AWS Signature Version 4 implementation. No networking, no
filesystem, just request signing.

```swift
public struct SigV4Signer: Sendable {
    public init(credentials: AcervoCDNCredentials, service: String = "s3")

    /// Returns a copy of `request` with Authorization, x-amz-date, and
    /// x-amz-content-sha256 headers attached. Mutates nothing.
    public func sign(
        _ request: URLRequest,
        payloadHash: PayloadHash,    // .empty | .precomputed(String) | .unsignedPayload
        date: Date = Date()
    ) -> URLRequest
}
```

Implementation: ~150 lines. Uses `CryptoKit.HMAC<SHA256>` for the four-step
key derivation and the final signature. Test surface includes the canonical
AWS test vectors so we don't ship a broken signer.

### 6.3 Layer 2 — `S3CDNClient`

Thin actor over `URLSession` that wraps SigV4 signing around the four
operations recache and delete need. Nothing else.

```swift
public actor S3CDNClient {
    public init(
        credentials: AcervoCDNCredentials,
        session: URLSession = .shared
    )

    /// Lists every key under `prefix`, paginating via continuation tokens.
    /// Returns key + size + etag tuples.
    public func listObjects(prefix: String) async throws -> [S3Object]

    /// Streams `bodyURL` to `key`. Computes SHA-256 over the file as it
    /// streams (used for x-amz-content-sha256 and for caller verification).
    public func putObject(key: String, bodyURL: URL) async throws -> S3PutResult

    /// Deletes `key`. 404 is not an error (idempotent).
    public func deleteObject(key: String) async throws

    /// Returns metadata or nil if not found.
    public func headObject(key: String) async throws -> S3ObjectHead?

    /// Bulk delete (S3 DeleteObjects API, up to 1000 keys per call).
    /// Returns per-key success/failure.
    public func deleteObjects(keys: [String]) async throws -> [S3DeleteResult]
}
```

The runtime read path stays on the public CDN URL via `SecureDownloadSession`
and does not use `S3CDNClient`. `S3CDNClient` is mutation-only.

### 6.4 Layer 3 — Orchestration

Three top-level functions on `Acervo` (existing namespace, not a new one).

```swift
extension Acervo {

    /// Atomic publish. Uploads every file in `directory`, swaps the
    /// manifest last so the CDN is never internally inconsistent, then
    /// prunes orphans (keys present on the CDN but not in the new manifest).
    ///
    /// Steps:
    ///   1. Generate manifest from `directory` (existing ManifestGenerator).
    ///   2. CHECK 4 — re-hash every file against the manifest.
    ///   3. List existing keys under models/<slug>/.
    ///   4. PUT every manifest file (overwrites by key).
    ///   5. PUT manifest.json LAST.
    ///   6. CHECK 5 + CHECK 6 — re-fetch manifest and one file from public URL.
    ///   7. Delete orphans (old keys not in new manifest, excluding manifest.json).
    ///
    /// If any step before step 5 fails, the old manifest still references
    /// the prior version's complete file set. If step 7 fails, the new
    /// manifest is already live and consumers see the new version; orphans
    /// are storage waste, not correctness bugs.
    public static func publishModel(
        modelId: String,
        directory: URL,
        credentials: AcervoCDNCredentials,
        keepOrphans: Bool = false,
        progress: (@Sendable (AcervoPublishProgress) -> Void)? = nil
    ) async throws -> CDNManifest

    /// Simple iterative delete. Lists the prefix, deletes every key,
    /// repeats until the listing is empty. No atomicity — partial failure
    /// leaves the CDN in a partially-deleted state, which is fine because
    /// nothing is consistent with anything else after a delete anyway.
    ///
    /// Idempotent: missing prefix returns immediately.
    public static func deleteFromCDN(
        modelId: String,
        credentials: AcervoCDNCredentials,
        progress: (@Sendable (AcervoDeleteProgress) -> Void)? = nil
    ) async throws

    /// Composes: caller-supplied source-fetch closure → publishModel.
    /// Library does not know what HuggingFace is. The closure populates
    /// `stagingDirectory` with the files for `modelId`. Subsequent
    /// publish is the atomic path from publishModel.
    public static func recache(
        modelId: String,
        stagingDirectory: URL,
        credentials: AcervoCDNCredentials,
        fetchSource: @Sendable (_ modelId: String, _ into: URL) async throws -> Void,
        keepOrphans: Bool = false,
        progress: (@Sendable (AcervoPublishProgress) -> Void)? = nil
    ) async throws -> CDNManifest
}
```

Notes:

- `publishModel` is the workhorse. `recache` is a thin convenience that
  exists mainly to give CLI/scripts a single-call entry point. A caller who
  has already populated a staging directory by other means can skip
  `recache` and call `publishModel` directly.
- `fetchSource` keeps the library agnostic to where bytes come from. CLI's
  closure shells out to `hf`; a future caller could substitute git, S3,
  a tarball download, etc.
- The orphan-prune is the only "delete" inside `publishModel`. There is no
  "delete first" phase. The non-atomic `deleteFromCDN` is for the explicit
  `acervo delete --cdn` case where the caller actually wants destruction.

### 6.5 Errors

New cases on `AcervoError` (one error type, consistent with existing API):

- `.cdnAuthorizationFailed(operation:)` — R2 returned 401/403. The IAM
  boundary is doing its job; surface clearly.
- `.cdnOperationFailed(operation:, statusCode:, body:)` — generic.
- `.publishVerificationFailed(stage:)` — CHECK 4/5/6 mismatch in publish.
- `.fetchSourceFailed(modelId:underlying:)` — `recache`'s fetch closure threw.

### 6.6 CLI changes

The CLI shrinks. `CDNUploader` and `aws`-related code go away.

- **`acervo delete <model-id>`**
  - Flags: `--local`, `--cdn`, `--dry-run`, `--yes`.
  - At least one of `--local` / `--cdn` required.
  - `--local` → `Acervo.deleteModel(_:)` (existing, in App Group container).
  - `--cdn` → `Acervo.deleteFromCDN(modelId:credentials:)`.

- **`acervo recache <model-id> [files...]`**
  - Same shape as `ship`'s flags.
  - Calls `Acervo.recache(...)` with a closure that shells out to `hf`.

- **`acervo ship`** (existing) is now also implementable as
  `recache` minus the orphan prune, OR retained as-is for backward
  compatibility. Open question — see §8 Q11.

- **`acervo upload`** can be retained or deprecated in favor of
  `publishModel`-via-CLI. Open question — see §8 Q11.

### 6.7 What stays where

- **`SwiftAcervo` library, runtime read path:** unchanged.
- **`SwiftAcervo` library, mutation path:** new — Layers 1/2/3 above.
- **`acervo` CLI:** ToolCheck (now `hf`-only), ProgressReporter, env-var
  resolution, TTY prompting, argument parsing, the `fetchSource` closure
  that shells out to `hf`.
- **Removed:** `CDNUploader` (replaced by `S3CDNClient` + `publishModel`),
  the `aws`-binary shell-out, `ToolCheck.requireAWS()`.

### 6.8 Downstream distribution changes (`../homebrew-tap`)

The Homebrew formula at `../homebrew-tap/Formula/acervo.rb` currently
declares `depends_on "awscli"` and references AWS CLI v2 in its `caveats`
block. Eliminating the `aws` binary from the CLI implementation makes that
dependency obsolete and actively misleading — it would force `brew install`
to pull a ~100 MB Python-based dependency that `acervo` no longer touches.

Required changes to `../homebrew-tap/Formula/acervo.rb`, sequenced with the
v0.9.0 release of SwiftAcervo:

1. **Remove `depends_on "awscli"`** (line 11). `hf` stays.
2. **Update the `caveats` block** to drop the "AWS CLI v2 for R2 CDN
   uploads" line. The list of automatically-installed dependencies should
   show only `hf`.
3. **Bump `url`, `sha256`, and `version`** to the new release tag
   (presumably `v0.9.0`).
4. **Verify the test block still passes** (`acervo --version`).

Sequencing constraint: do not merge the formula change until v0.9.0 is
tagged and the release artifact is published. Until then, the current
formula is still correct for the v0.8.x line.

There is no equivalent change needed for the SwiftPM consumer side —
`SwiftAcervo` as a library does not introduce any new system-level
dependencies (SigV4 is pure Foundation + CryptoKit).

If any other formulae in `../homebrew-tap/` indirectly depend on
`acervo` and assumed `awscli` would be present transitively, those need
auditing too. (Quick grep of sibling formulae confirms none do, but
re-verify at release time.)

---

## 7. Atomicity contract (DECIDED)

**Decision: build atomic primitives now, even though there are no users yet.**

Rationale: there are zero current consumers, so an atomic-vs-non-atomic
recache makes no practical difference today. But primitives are cheap to get
right at write-time and expensive to retrofit. So:

- `publishModel` is **atomic from the consumer's perspective** — manifest
  swaps last, orphan prune runs after CHECK 6 passes, partial failure leaves
  the prior version intact.
- `deleteFromCDN` is **non-atomic by design** — there is nothing to be
  consistent with after a delete. Iterate the prefix listing and delete
  until empty.

Concretely the orphan-prune model from the earlier "Option B" is the only
live design. The earlier "Option A" (delete-first then re-upload) is
discarded — atomic primitives mean we never want that ordering.

### `publishModel` execution order (frozen)

1. Generate manifest from staging directory.
2. CHECK 2 — refuse zero-byte files (`ManifestGenerator` already does this).
3. CHECK 3 — re-read manifest and verify checksum-of-checksums.
4. CHECK 4 — re-hash every staged file against the manifest.
5. List existing CDN keys under `models/<slug>/`.
6. PUT every file from the manifest.
7. PUT `manifest.json` last.
8. CHECK 5 — fetch `manifest.json` from public URL, verify checksum.
9. CHECK 6 — fetch one file (`config.json` if present, else first manifest
   entry) and verify SHA-256.
10. Compute orphan set = `existing_keys - new_manifest_keys - {manifest.json}`.
11. Delete orphans via `S3CDNClient.deleteObjects` (bulk, batches of 1000).

Failure semantics:

- Steps 1–4 fail → nothing on the CDN changed.
- Steps 5–6 fail → some new files may be on the CDN, but the old
  `manifest.json` still points at the old (complete) file set. Consumers
  unaffected. Re-running the command is the recovery path.
- Step 7 fails → same as 5–6.
- Steps 8–9 fail → new manifest is live but verification failed. **This is
  a bug in the upload, not a transient.** Throw loudly. Operator decides
  whether to roll forward (re-run) or roll back manually.
- Steps 10–11 fail → new version is live and serving traffic correctly.
  Orphans are storage waste. Return the orphan list in the error so the
  caller can retry the prune.

### `deleteFromCDN` execution order (frozen)

1. List `models/<slug>/`.
2. Bulk-delete returned keys (1000 at a time).
3. Re-list.
4. If non-empty, repeat 2–3.

Loop terminates when listing returns empty. Any single batch failure
throws and lets the caller retry. No "all or nothing" guarantee — explicit
deletes don't need one.

---

## 8. Open questions

Numbered for easy reference in follow-up. Resolved questions are kept here
with their answer for traceability; new ones added after the architecture
decisions are at the end.

1. ~~**Architecture (§5):** Option A, B, or C?~~ → **Option A** (single
   library, IAM-as-boundary). See §5.
2. ~~**Recache ordering (§7):** Option A or B?~~ → **Option B** (atomic
   replace + orphan prune). See §7.
3. ~~**Local-cache scope for `delete --local` (CLI).**~~ → **Both, with
   separate flags.** `--staging` deletes `STAGING_DIR/<slug>`. `--cache`
   deletes the App Group cache via `Acervo.deleteModel`. `--local` is a
   convenience that implies both. Operator can be precise when needed.
4. ~~**Confirmation prompt for destructive CLI ops.**~~ → **Prompt-on-TTY
   with `--yes` bypass** (Unix convention). Applies to `delete --cdn` and
   to `recache` when it would prune orphans. Non-TTY (CI) requires `--yes`.
5. ~~**Concurrency safety on the CDN.**~~ → **(c) Not supported in v0.9.**
   Document in `CDN_UPLOAD.md` that concurrent `publishModel` runs against
   the same model are unsupported. Revisit when there's a real
   multi-maintainer workflow.
6. ~~**HF Xet handling in recache.**~~ → **Closure** (`fetchSource`). See §6.4.
7. ~~**Observability.**~~ → **Progress callback only for v0.9**, matching
   existing `AcervoDownloadProgress`. AsyncStream variant is additive and
   can be added later without breaking changes.
8. ~~**Versioning.**~~ → **0.9.0.** Mutation API is additive but the
   `aws`-binary removal is a behavior change for anyone scripting around it.
9. ~~**Naming for a separate admin target.**~~ → N/A (single target).
10. ~~**Orphan-prune toggle.**~~ → **`keepOrphans: Bool` is a public
    parameter** on `publishModel` (and forwarded through `recache`).
    Default `false` (prune by default); paranoid operators can opt out.
11. ~~**Existing CLI commands.**~~ → **(a) Rewrite both on top of
    `publishModel`.** `ship` becomes `recache` minus the orphan prune;
    `upload` becomes `publishModel` directly. No parallel CDN-write paths.
12. ~~**SigV4 test vectors.**~~ → **Yes**, vendor the canonical AWS test
    vectors verbatim into the test suite.
13. ~~**Body streaming for large PUTs.**~~ → **Multipart in v0.9.**
    Single-shot PUT will OOM on multi-GB files; not optional.
14. ~~**Homebrew formula sequencing.**~~ → **Confirmed.** Release flow:
    tag SwiftAcervo v0.9.0 → publish release artifact → update
    homebrew-tap formula → merge formula PR. No race window: between
    SwiftAcervo release and formula merge, `brew install acervo` continues
    serving v0.8.x with `awscli`, which is correct for that binary.

---

## 9. Out of scope (recorded so we remember to revisit)

- A library-side disk-pressure eviction policy (`Acervo.evictLRU(toFreeBytes:)`).
- A web UI / dashboard for CDN inventory.
- Replacing the `hf` shell-out for non-Xet repos with native HTTP (already
  discussed; deferred).
- Any change to component-level recache. `recache` operates on whole models
  for now; component-level recache can be added later by composing the
  same primitives.
- Concurrent-recache locking (Q5 above). Documented as "not supported"
  for v0.9.

---

## 10. Decision log

| #  | Question | Decision | Date |
|----|----------|----------|------|
| 1  | Library architecture: single target vs. split admin target | Single target. R2 IAM is the security boundary, not code surface. Mint mutation-scoped keys for CI only. | 2026-05-02 |
| 2  | Recache ordering | Atomic replace + orphan prune. Build atomic primitives now. | 2026-05-02 |
| 3  | `delete --local` scope | Both staging and App Group cache, with separate `--staging` / `--cache` flags. `--local` implies both. | 2026-05-02 |
| 4  | Confirmation prompt | Prompt-on-TTY with `--yes` bypass. CI requires `--yes`. | 2026-05-02 |
| 5  | Concurrent publish safety | Not supported in v0.9. Document in CDN_UPLOAD.md. | 2026-05-02 |
| 6  | HF source fetch in library | Caller-supplied `fetchSource` closure; library does not know what HF is. | 2026-05-02 |
| 7  | Progress observability | Callback only in v0.9. AsyncStream is additive later. | 2026-05-02 |
| 8  | Versioning | 0.9.0 (additive API + `aws`-binary removal). | 2026-05-02 |
| 9  | Naming of admin target | N/A — single target. | 2026-05-02 |
| 10 | `keepOrphans` toggle | Public `Bool` parameter, default `false`. | 2026-05-02 |
| 11 | Fate of `ship` / `upload` | Rewrite both on top of `publishModel`. No parallel CDN-write paths. | 2026-05-02 |
| 12 | SigV4 test vectors | Vendor canonical AWS test vectors into the test suite. | 2026-05-02 |
| 13 | Multipart PUT | Ship in v0.9. Single-shot OOMs on multi-GB files. | 2026-05-02 |
| 14 | Homebrew release sequencing | Tag → publish artifact → update formula → merge formula PR. | 2026-05-02 |
