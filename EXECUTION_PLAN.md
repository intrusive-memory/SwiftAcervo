# EXECUTION_PLAN.md — SwiftAcervo

Generated from [`REQUIREMENTS.md`](REQUIREMENTS.md) on 2026-05-19.

Two independent tracks of work fall out of the requirements doc:

1. **Manifest-driven slug registry** for multi-component models (§1) — unblocks Vinetas's UI rework.
2. **Chunked `streamDownloadFile`** (§2) — deferred perf fix from the v0.14.0 mission.

These tracks do not share files or types, so the two work units run in parallel.

---

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure.

> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. One aircraft, one mission, one return.

> **Work Unit** — A grouping of sorties (package, component, phase).

---

## API Model: NAME_SLUG + optional URL

Per the user's resolution of the slug-vs-repo ambiguity, the slug-keyed API surface in this plan follows a unified `(slug, url?)` contract instead of a `/`-based heuristic. Every sortie below assumes this model.

- **`slug` (NAME_SLUG)** is the caller-supplied identifier used by SwiftAcervo to address physical files on disk once downloaded. It may or may not look like `"org/repo"`; that is no longer a signal Acervo branches on.
- **`url` (optional)** is the manifest fetch URL.
  - If `url` is **omitted** and the slug parses as `"org/repo"`, Acervo derives the manifest URL from the canonical HuggingFace/CDN path for that repo. This is the default ergonomic path for HF-style slugs.
  - If derivation fails (manifest fetch returns a non-2xx), Acervo throws an HTTP error. The UI is expected to catch that error and prompt the user for a full URL — Acervo does not silently fall back.
  - If `url` is **supplied**, the slug is treated purely as an internal identifier (it may be `"flux2-klein-4b"`, `"my-org/my-model"`, anything). The manifest is fetched from `url` and the slug becomes the on-disk directory key. No slash-based heuristic is consulted.
- **No legacy/migration shim.** Manifests on the CDN must carry the new fields (`modelId`, `primaryRepo`, `components`); decoding a manifest without them is an error, not a fallback. There is no migration code in this plan.

This model replaces the earlier "presence of `/` indicates HF repo" heuristic everywhere it appeared.

---

## Testing Principles (apply to every sortie)

These constraints govern what may appear in a sortie's exit criteria. A sortie that violates them is not done, even if the implementation is correct.

1. **Every test cited in an exit criterion must run in CI via `make test` (macOS) and `make test-ios` (iOS, where applicable).** CI gating is the *only* signal that an exit criterion is durable. A test that "passes locally" but isn't on the CI test plan does not count.
2. **Performance tests do NOT run in CI.** Wall-clock thresholds, throughput ceilings, and any other timing-sensitive measurements live on a separate test plan (`SwiftAcervo-Performance.xctestplan`) and are invoked only by an explicit `make test-perf` target. They MUST NOT be added to `SwiftAcervo-macOS.xctestplan` or `SwiftAcervo-iOS.xctestplan`. Their pass/fail status is informational and is never part of a sortie's exit criteria.
3. **No flaky or non-deterministic tests in exit criteria.** A test is non-deterministic if its pass/fail depends on wall-clock time, CPU load, scheduler ordering between two concurrent producers, real-network latency, or the order in which independent async tasks happen to emit. If you cannot describe the test as a pure function of fixture input → assertion, it does not belong in an exit criterion.
   - **Race-based correctness checks are forbidden.** Do not write tests that sample two independent live emissions and assert they agree "at the same moment". Instead, extract the shared computation into a pure helper and test the helper with fixture state. Code paths that *use* the helper get a regression test for the *wiring*, not for the math.
   - **Live-network smoke tests are out of scope for this mission.** No sortie in this plan performs live-CDN or live-network assertions; all integration is via `URLProtocol` mocks or other in-process fakes. (Live-CDN data migration has been deferred to scheduled future work — see the bottom of this plan.)
4. **Chunk-count / call-count assertions are deterministic and ARE allowed in CI.** They are a function of file size and the implementation's chunk-size constant, both of which are fixture inputs. They are not performance tests — they are correctness tests for the chunking *contract*.
5. **If a sortie introduces a new test file, the sortie's exit criteria must explicitly state which test plan(s) the file is registered on.** Adding a `.swift` file under `Tests/` is not the same as adding it to a test plan.

---

## Work Units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|-----------|-----------|---------|-------|--------------|
| slug-registry | `Sources/SwiftAcervo/` + `Sources/acervo/` | 5 (S6 deferred) | 1 | none |
| chunked-streaming | `Sources/SwiftAcervo/AcervoDownloader.swift` + `Sources/SwiftAcervo/SecureDownloadSession.swift` | 2 | 1 | none |

Both work units are at Layer 1 (no inter-unit dependency). Sorties **within** a work unit run sequentially.

---

## Work Unit: slug-registry

Implements REQUIREMENTS.md §1 — manifest schema extension, slug-keyed API surface, CLI tooling, and CDN data migration.

### Sortie 1: Manifest schema extension

**Priority**: 20 — Blocks 5 downstream sorties; establishes the manifest type + cache contract reused by every slug-keyed API. Highest-priority work in the plan.

**Entry criteria**:
- [ ] First sortie — no prerequisites.

**Tasks**:
1. Add three required (non-optional) fields to the on-CDN manifest model type (`modelId: String`, `primaryRepo: String`, `components: [String]`). Locate the manifest type definition in `Sources/SwiftAcervo/` and update both the type and its `Codable` implementation.
2. **No migration shim.** Decoding a manifest that does not carry all three fields is a hard error (`DecodingError`). There is no legacy fallback, no `// MIGRATION:` comment, and no compat code. Manifests on the CDN that lack the fields are out-of-spec and will be re-uploaded out-of-band (not by this mission).
3. **Pin `primaryRepo` semantics for multi-component manifests.** For a multi-component slug like `flux2-klein-4b`, every component manifest (transformer / VAE / text-encoder / …) carries the **same** `primaryRepo` value — the slug's canonical "main" component as supplied by the uploader's spec file. The VAE manifest's `primaryRepo` is *not* the VAE's own HF repo; it is the shared spec-level `primaryRepo`. For single-component slugs, `primaryRepo` equals the sole repo. Document this in the manifest type's doc comment.
4. Update the in-memory manifest cache to key/index by `(slug, url?)` per the API model above. The cache must support: lookup by slug-with-derived-URL, lookup by slug-with-explicit-URL, and lookup by HF repo string (which is just the special case where slug == "org/repo" and URL is derived). Implementation choice: a single backing dictionary plus index dictionaries is acceptable; a single dictionary with multiple key mappings to the same value is also acceptable. Pick whichever has the smaller diff against today's cache.
5. Add unit tests covering:
   - (a) decoding a manifest that carries all three fields succeeds,
   - (b) decoding a manifest that **lacks** any of the three fields throws `DecodingError` (replaces the prior "legacy compat shim" test — the assertion is now that strict decoding fails, not that fallback succeeds),
   - (c) cache lookup by slug returns the same instance as lookup by the derived URL.
6. Document the new manifest shape in `Docs/CDN_ARCHITECTURE.md`. Include the multi-component `primaryRepo` semantics rule from Task 3.

**Exit criteria**:
- [ ] `make build` succeeds.
- [ ] All three test scenarios above are on `SwiftAcervo-macOS.xctestplan` and pass via `make test`.
- [ ] Manifest type carries `modelId`, `primaryRepo`, `components` as non-optional fields. Manifests missing any of the three fail to decode.
- [ ] `Docs/CDN_ARCHITECTURE.md` documents the multi-component `primaryRepo` invariant ("all component manifests in a multi-component slug share the same `primaryRepo`").
- [ ] In-memory cache lookups via the slug-and-derived-URL path and the slug-with-explicit-URL path both resolve to the same cached entry.

---

### Sortie 2: Slug-keyed `Acervo.availability(slug:url:)` with multi-component aggregation

**Priority**: 7 — Blocks Sortie 3; introduces the shared aggregation helper that S3 reuses. Foundation work for the slug-keyed API surface.

**Entry criteria**:
- [ ] Sortie 1 exit criteria all met (manifest carries `modelId` + `components`; cache resolves by slug).

**Tasks**:
1. Extend `Acervo.availability(...)` to a `(slug: String, url: URL? = nil)` signature per the API model section above. **No `/`-based heuristic.** Resolution rule:
   - If `url` is supplied, use it verbatim as the manifest fetch URL; the slug is purely the on-disk identifier.
   - If `url` is nil and the slug parses as `"org/repo"` (single forward slash, non-empty halves), derive the canonical HF/CDN manifest URL from the slug.
   - If `url` is nil and the slug does not parse as `"org/repo"`, throw `AcervoError.urlRequiredForSlug(slug)` (introduce this error case) — Acervo will not guess.
   - If the manifest fetch returns a non-2xx HTTP status, throw an HTTP error (use the existing networking error type if one exists; otherwise introduce `AcervoError.manifestFetchFailed(slug:status:)`). The UI is expected to catch this and prompt the user for a full URL.
2. Once the manifest is fetched, fan out to each entry in `components` and aggregate: all `.available` → `.available`; any `.downloading` → `.downloading(progress: weightedAggregate)` using `bytesTotal` weights (`.notAvailable` contributes 0, `.available` contributes 1, `.downloading(progress: p)` contributes `p`; equal-weight when bytes are unknown); otherwise `.notAvailable`.
3. Preserve today's repo-keyed call as the **derived-URL path** — i.e. a call like `availability(slug: "black-forest-labs/FLUX.2-klein-4B")` (no URL) must produce the same observable result it does today (single-component fetch from the canonical HF/CDN URL). This is what the API model calls the "HF-style slug" ergonomic case.
4. Ensure all call shapes (derived-URL, explicit-URL, single-component, multi-component) funnel through the same `recordModelAvailability` telemetry invocation (single telemetry emission per call).
5. Add unit tests, all driven by **injected fixture state** (no real downloads, no timing):
   - (a) HF-style slug + no URL → single-component manifest returns the per-repo state (the today-equivalent regression case),
   - (b) slug + explicit URL → multi-component all-available returns `.available`,
   - (c) slug + explicit URL → multi-component mixed states returns `.downloading(progress: X)` where `X` equals the value the pure aggregation helper produces for the fixture (assert the exact numeric value — e.g. transformer `.downloading(0.5)` weight=4GB, VAE `.available` weight=1GB, text-encoder `.notAvailable` weight=1GB → expected `0.5 * 4/6 + 1.0 * 1/6 + 0.0 * 1/6 = 0.5`),
   - (d) non-`org/repo` slug + no URL throws `AcervoError.urlRequiredForSlug`,
   - (e) manifest fetch returning HTTP 404 throws the documented HTTP error (use a `URLProtocol` mock; deterministic),
   - (f) telemetry is emitted exactly once per call regardless of call shape (use a counting telemetry stub).

**Exit criteria**:
- [ ] `make build` succeeds.
- [ ] All six test scenarios above are on `SwiftAcervo-macOS.xctestplan` and pass via `make test` (and `make test-ios` where platform-agnostic).
- [ ] Every assertion is a pure function of fixture input (no wall-clock, no live concurrency races — see Testing Principle 3).
- [ ] Acceptance criteria §1.4.1 and §1.4.2 (PixArt HF-style slug; Flux2 multi-component slug with weighted `.downloading`) are demonstrated by tests with an exact expected numeric value.
- [ ] Acceptance criterion §1.4.6 (HF-style slug + no URL produces today's repo-scoped result) is demonstrated by test (a).
- [ ] `AcervoError.urlRequiredForSlug(String)` and the HTTP-failure error case are introduced and reused by S3/S4 (no duplicate error types invented downstream).

---

### Sortie 3: Slug-keyed `Acervo.ensureAvailable(slug:url:files:progress:)`

**Priority**: 2 — Leaf sortie in its chain; depends on the aggregation helper from S2.

**Entry criteria**:
- [ ] Sortie 2 exit criteria all met (slug-keyed availability with aggregation lands; `AcervoError.urlRequiredForSlug` and HTTP-failure error case introduced).

**Tasks**:
1. Extend `Acervo.ensureAvailable(...)` to a `(slug: String, url: URL? = nil, files: [String], progress: ...)` signature mirroring S2's API model. Resolution rules and error model are identical to S2 — reuse the same helper/types. Once the manifest is resolved, iterate each component in `components` and share the existing `InFlightDownloads` dedup keyed by `(modelId, file)`.
2. Make the `progress:` callback emit the same bytes-weighted aggregate that `availability(_:)` returns mid-flight (acceptance §1.4.3). **Extract the aggregation math into a pure helper** (taking per-component state as input, returning the aggregate) so the two code paths share one implementation and cannot drift.
3. Preserve HF-repo-keyed `ensureAvailable` behavior exactly (regression-protect with a test).
4. Add unit tests covering:
   - (a) slug multi-component download triggers a download per component,
   - (b) concurrent calls dedup via `InFlightDownloads`,
   - (c) **deterministic helper-equivalence test** — call the pure aggregation helper with a fixture state vector (e.g. transformer `.downloading(0.5)` bytes=N1, VAE `.available` bytes=N2, text-encoder `.notAvailable` bytes=N3); assert the helper returns the documented weighted value. Then assert that `availability(_:)` and the `progress:` callback both consume that helper (by code path / dependency-injection inspection — not by racing two live emissions).

**Exit criteria**:
- [ ] `make build` succeeds.
- [ ] All three test scenarios above are on `SwiftAcervo-macOS.xctestplan` and pass via `make test` (and `make test-ios` where the test is platform-agnostic).
- [ ] Acceptance criterion §1.4.3 is demonstrated by the **deterministic** helper-equivalence test in (c). No race-based "callback matches poll" test is allowed (see Testing Principle 3).

---

### Sortie 4: Slug-keyed `Acervo.deleteModel(slug:url:)`

**Priority**: 1.5 — Independent leaf sortie; only depends on Sortie 1's cache. Can run in parallel with S2/S5 (no shared files beyond the manifest cache).

**Entry criteria**:
- [ ] Sortie 1 exit criteria all met (manifest cache resolves slugs to components).

**Tasks**:
1. Extend `Acervo.deleteModel(...)` to `(slug: String, url: URL? = nil)` mirroring S2's API model. Resolve `components` via the same mechanism (cached manifest, or fetch via derived/explicit URL). For each component, **delete its on-disk folder unconditionally** — do not stat, do not enumerate, do not check that any particular file is present before removing. The only post-condition that matters is "the folder is gone".
2. **Error model:** the function only throws if `FileManager.removeItem` fails (permission denied, IO error, etc.) on a folder that exists and cannot be removed. Specifically:
   - Folder does not exist → no-op success (not an error).
   - Some components have on-disk folders, others don't → delete the ones that exist, succeed.
   - Manifest cannot be fetched (HTTP error) → throws the same HTTP error as S2/S3 (we can't know what to delete without it).
   - `FileManager.removeItem` fails on an existing folder → throws the underlying filesystem error.
3. Add unit tests, all driven by an in-memory `FileManager` fixture or a tempdir (no live network):
   - (a) Multi-component slug, all component folders present → all removed; function returns successfully.
   - (b) Multi-component slug, only one component folder present → that one is removed; function returns successfully (the missing-folder components are not errors).
   - (c) Multi-component slug, no folders present anywhere → function returns successfully (pure no-op).
   - (d) HF-style slug + no URL (regression): single-folder delete still works.
   - (e) `FileManager.removeItem` simulated to fail on an existing folder → function throws the filesystem error.

**Exit criteria**:
- [ ] `make build` succeeds.
- [ ] All five test scenarios above are on `SwiftAcervo-macOS.xctestplan` and pass via `make test`.
- [ ] No code path checks for file existence before deletion. The implementation calls `removeItem` and either succeeds, succeeds-because-folder-already-gone (treated as success), or throws the filesystem error verbatim.
- [ ] Acceptance criterion §1.4.4 is demonstrated by test (a).

---

### Sortie 5: `acervo ship` CLI — `--slug` + multi-component manifest upload

**Priority**: 6 — Final sortie in the slug-registry work unit; equips the operator-tended deferred migration (see "Scheduled Future Work") with the CLI it needs. Touches the CLI target, not library code; safe to run in parallel with S2/S3/S4.

**Entry criteria**:
- [ ] Sortie 1 exit criteria all met (manifest type carries the three new fields).

**Tasks**:
1. Add a `--slug <slug>` argument to `acervo ship` so the uploaded manifest carries `modelId` set to the slug. Default behavior (no `--slug`) preserves today's single-repo flow.
2. Add an ergonomic affordance for multi-component models — a per-model spec file (path passed via flag, e.g. `--spec components.json`) listing the component HF repos that share one `modelId`. **Spec file format** (JSON): `{ "modelId": "flux2-klein-4b", "primaryRepo": "black-forest-labs/FLUX.2-klein-4B", "components": ["black-forest-labs/FLUX.2-klein-4B", "black-forest-labs/FLUX.2-vae", "google/t5-v1_1-xxl"] }`. The CLI must produce one manifest per component, all populated with the **same** `modelId`, the **same** `primaryRepo` (the spec-level value — per the S1 multi-component invariant), and the full `components` array. Document this schema inline in `Docs/CDN_UPLOAD.md`.
3. Wire the new fields (`modelId`, `primaryRepo`, `components`) into the manifest-generation step of `acervo ship` so generated JSON matches the schema from Sortie 1.
4. **Add a `--dry-run` flag to `acervo ship`** that runs the full pipeline through manifest generation, writes the generated manifest(s) to a `--output-dir <path>` (default: a tempdir whose path is printed on stdout), and **skips the R2 upload step**. The flag exists so CLI tests can assert on manifest output without needing live R2 credentials. Print the output path(s) to stdout so tests can locate them.
5. Add CLI tests (using `--dry-run`, no live network) covering:
   - (a) `--slug <slug> --dry-run` on a single-repo model produces a manifest with `modelId == slug`, `primaryRepo == repo`, `components == [repo]`;
   - (b) `--spec <path> --dry-run` produces N manifests, every one sharing the same `modelId` and the same `primaryRepo`, with the full `components` array.
6. Update `Docs/CDN_UPLOAD.md` with the new flow (single-component `--slug`, multi-component spec file, `--dry-run` for testing).

**Exit criteria**:
- [ ] `make build` succeeds.
- [ ] `make install-acervo` produces a CLI that accepts `--slug`, the spec-file flag, and `--dry-run`.
- [ ] CLI tests using `--dry-run` (no live R2 credentials required) are on `SwiftAcervo-macOS.xctestplan` and pass via `make test`.
- [ ] No CLI test in this sortie touches the live CDN or requires R2 credentials.
- [ ] `Docs/CDN_UPLOAD.md` documents the new flow including `--dry-run`.
- [ ] Acceptance criterion §1.4.5 is demonstrated by tests.

---

### Sortie 6: ~~Data migration — re-upload three Vinetas manifests~~ — **DEFERRED**

**Status**: Removed from this mission. Per the user's instruction, live-CDN testing is not in scope for this execution; the data migration is scheduled separately as a long-running operator-tended task (see "Scheduled Future Work" at the bottom of this plan). The slug-registry work unit is complete after S5.

**Implication for consumers**: until the deferred migration runs, calls to `Acervo.availability(slug: "flux2-klein-4b")` (no URL) will throw the documented HTTP error introduced in S2 — the canonical CDN URL for that slug won't yet have a manifest with the new fields. The UI catches that error and prompts the user for a full URL (per the API model section), so this is a recoverable failure path, not a regression. Consumer apps that need Flux2/PixArt before the migration runs can pass an explicit `url:` argument pointing at a pre-staged manifest.

---

## Work Unit: chunked-streaming

Implements REQUIREMENTS.md §2 — replace the byte-at-a-time `URLSession.AsyncBytes` loop in `streamDownloadFile` with a delegate-driven chunked download path, and exploit Cloudflare R2's HTTP/2 + HTTP/3 + Range capabilities to saturate available bandwidth on multi-gigabyte model weights (the dominant workload).

### R2 CDN Speed Surface (what S1 explicitly exploits)

The download endpoint is `https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev`, a Cloudflare R2 public bucket served through Cloudflare's global edge network. The protocol features S1 targets:

| Feature | What R2/Cloudflare offers | How S1 uses it |
|---|---|---|
| **HTTP/3 (QUIC)** | Supported on all `pub-*.r2.dev` endpoints; advertised via `Alt-Svc`. | Set `URLSessionConfiguration.assumesHTTP3Capable = true` so URLSession attempts QUIC on the **first** request instead of waiting for Alt-Svc discovery on the second. Removes 1 RTT cold-start; removes TCP head-of-line blocking on lossy networks (per-stream loss recovery instead of per-connection). |
| **HTTP/2 multiplexing** | One TCP/TLS connection carries N concurrent streams (or N QUIC streams under HTTP/3). | Parallel-range requests for a single file share one connection. Zero per-request TLS handshake cost — fanout is essentially free per additional range. |
| **HTTP Range requests** (`Range: bytes=A-B`) | Full support, including suffix ranges. Returns `206 Partial Content`. | (a) Existing `.part` resume on the single-stream path. (b) **NEW**: parallel range fetches for large files (files > `parallelRangeThreshold`, see S1 Task 6). |
| **Edge caching at PoPs** | First fetch from a region warms the local edge POP; subsequent clients in that region hit the cache. | No client code required. We must NOT add a `Cache-Control: no-cache` request header (we don't today). Note: the current `URLSessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData` is a **client-side** directive only — it tells URLSession to bypass its local cache, it does NOT bypass the Cloudflare edge cache. We keep this setting. |
| **TLS 1.3 + session resumption** | Automatic on Cloudflare's edge. | Free, transparent via shared `URLSession`. The aggressive single-session-for-everything pattern in `SecureDownloadSession.shared` is correct and we keep it. |

**Explicitly NOT exploited** (and why):
- **gzip/brotli compression**: model weights (`.safetensors`, `.bin`, `.gguf`) are entropy-dense and not compressible. Adding `Accept-Encoding` would burn CPU on both ends for ~0% size win. We leave URLSession's default behavior (which negotiates but compression won't apply to weight files).
- **Cloudflare Workers / signed URLs**: the public r2.dev bucket doesn't need them. Our integrity guard is the redirect-rejection delegate + per-file SHA-256 manifest, not signed URLs.
- **Multiple endpoints / sharding**: there is one CDN host. Adding regional shards would complicate the redirect-rejection allowlist for no measurable win — Cloudflare already does geo-routing at the edge.

### Sortie 1: Delegate-driven chunked download with HTTP/3 + parallel ranges

**Priority**: 7 — Blocks Sortie 2 (the regression/perf tests). Highest risk in the chunked-streaming track because (a) the redirect-rejection contract on `SecureDownloadSession` must survive a delegate-shape change, and (b) parallel ranges add a reorder-buffer dependency between in-flight requests and the SHA-256 hasher.

**Entry criteria**:
- [ ] First sortie — no prerequisites.

**Tasks**:

1. **Drop `URLSession.AsyncBytes` entirely from the streaming path.** The byte-at-a-time loop at `Sources/SwiftAcervo/AcervoDownloader.swift:745` (`for try await byte in asyncBytes { buffer.append(byte); ... }`) is the actual performance bug — appending one byte at a time through `AsyncBytes` is roughly two orders of magnitude slower than the native delegate dispatch. The replacement is `URLSessionDataDelegate`. **There is no `AsyncBytes`-batching fallback.** If delegate integration forces changes to `SecureDownloadSession`, make them — Task 2 spells out the exact shape required. The "delegate vs AsyncBytes" implementation-branch ambiguity is hereby resolved as **delegate-only**. `grep -rn "AsyncBytes" Sources/SwiftAcervo/` must return zero matches outside comments after this sortie.

2. **Extend `SecureDownloadSession` to a delegate-backed session that handles both redirects and data delivery.** The existing `SecureDownloadDelegate` only implements `URLSessionTaskDelegate.urlSession(_:task:willPerformHTTPRedirection:...)`. Add:
   - `URLSessionDataDelegate.urlSession(_:dataTask:didReceive data:)` — receives chunks as `Data`. Chunk sizes are OS-chosen; on HTTP/3 they typically arrive in 16–64 KB pieces, on HTTP/2 closer to 64–256 KB.
   - `URLSessionDataDelegate.urlSession(_:dataTask:didReceive response:completionHandler:)` — must call `completionHandler(.allow)` for 2xx/206, `.cancel` otherwise (the existing HTTP-status check moves here from the post-hoc body inspection).
   - A **per-task consumer registry**: `[ObjectIdentifier(URLSessionTask): ChunkConsumer]` guarded by an `NSLock` (or a small actor). One delegate instance per session; one consumer registered per started task; consumer is unregistered on task completion. This pattern keeps the single `allowedHost` invariant intact — do NOT instantiate one delegate per task, that breaks the redirect contract's host pinning.
   - `URLSessionTaskDelegate.urlSession(_:task:didCompleteWithError:)` — surfaces stream-end (success or transport error) to the consumer via a sentinel.

3. **Tune the URLSessionConfiguration in `SecureDownloadSession.shared` for R2 bulk download.** Comments are the *why*, not the *what*, so they survive future tinkering:
   ```swift
   config.assumesHTTP3Capable = true                          // QUIC on first request (saves 1 RTT cold-start)
   config.httpMaximumConnectionsPerHost = 8                   // supports parallel-range fanout (Task 6)
   config.requestCachePolicy = .reloadIgnoringLocalCacheData  // unchanged — client-side only, edge cache still warms
   config.waitsForConnectivity = true                         // ride out transient Wi-Fi blips instead of failing the download
   config.timeoutIntervalForRequest = 60                      // single-chunk RTT ceiling
   config.timeoutIntervalForResource = 7 * 24 * 3600          // whole-file ceiling — multi-GB downloads on slow links
   ```

4. **Introduce three named constants** at file scope in `AcervoDownloader.swift`, each with a one-line comment explaining what governs them:
   - `streamFlushSize: Int = 256 * 1024` — flush-and-hash quantum. With the delegate path, the OS picks I/O chunk sizes; this constant is the in-memory buffer threshold at which we drain into `hasher.update(data:)` + `fileHandle.write(contentsOf:)`. Smaller than the old 4 MB because the per-byte amortization need is gone, and smaller flushes give finer-grained progress updates and lower peak memory per in-flight stream.
   - `parallelRangeThreshold: Int64 = 64 * 1024 * 1024` — files smaller than this take the single-request path (no range splitting). 64 MB is small enough that 4-way parallelism would only shave milliseconds and large enough that single-stream throughput is already saturated on most connections.
   - `parallelRangeCount: Int = 4` — number of concurrent range requests per file when the file exceeds `parallelRangeThreshold`. Matches `maxConcurrentDownloads`. With one large file in flight, this gives 4 parallel range streams; with 4 small files in flight, each takes 1 stream. Peak concurrent HTTP requests across the session ≈ 4 (small files) to 16 (one large file + 3 large file slots × 4 ranges); `httpMaximumConnectionsPerHost = 8` is sufficient because HTTP/2/3 multiplexes streams over connections.

   These three constants are the contract surface that S2's regression tests assert against. They must be single named constants, not magic numbers anywhere else in the file.

5. **Single-request path (file ≤ `parallelRangeThreshold` OR `parallelRangeCount == 1`).** This is the simple replacement for today's `streamDownloadFile`:
   - Start one `URLSessionDataTask` with the existing `Range:` header (for resume) or no Range (for fresh start).
   - Delegate's `didReceive data:` appends to a per-task buffer.
   - When the buffer reaches `streamFlushSize`, drain: `hasher.update(data: buffer)`, `fileHandle.write(contentsOf: buffer)`, `bytesWritten += buffer.count`, reset buffer, fire progress callback.
   - On `didCompleteWithError(nil)`: flush any tail bytes, close handle, run the existing size + SHA verification, atomic rename `.part` → destination.
   - On `didCompleteWithError(error)` or `Task.isCancelled` between flushes: cancel the data task, close handle, keep the `.part` file on disk (existing resume contract), throw.

6. **Parallel-range path (file > `parallelRangeThreshold`).** This is the speed-critical new feature.
   - Compute `tailRange = [resumeOffset, sizeBytes)`. If `resumeOffset > 0`, the existing on-disk prefix is fed into the hasher first (re-seed from disk, unchanged from today's resume).
   - Split `tailRange` into `parallelRangeCount` equal sub-ranges. Last sub-range absorbs the remainder if size isn't divisible.
   - Dispatch one `URLSessionDataTask` per sub-range, each with its own `Range: bytes={start}-{end-1}` header. Each task expects HTTP `206 Partial Content`; any non-206 causes the whole download to fail.
   - **Reorder buffer for sequential SHA-256.** SHA-256 is not commutative; bytes must be fed in order. The implementation:
     - Each range task writes its `Data` chunks **directly to the `.part` file at the correct seek offset** as they arrive (use a per-file `NSLock` around `fileHandle.seek` + `write`). No per-range buffering on disk — the `.part` file *is* the assembly buffer, written sparsely as ranges complete.
     - A separate **hasher coordinator** task maintains `hashedThrough: Int64` (the next byte offset SHA-256 expects). Each range task, after writing a chunk, signals the coordinator via an `AsyncStream<RangeChunkComplete>`. The coordinator reads back from the `.part` file when contiguous bytes from `hashedThrough` become available and feeds them into the hasher.
     - In practice the coordinator's read-back loop only re-reads each byte once and uses small (64 KB) reads, so the disk-read cost is negligible compared to the network savings.
   - **Memory budget**: the in-memory buffer for any single range is bounded by `streamFlushSize` (256 KB); 4 ranges × 256 KB = 1 MB peak in-memory per in-flight file. Acceptable.
   - **Cancellation**: cancelling the parent `Task` cancels all range tasks. The `.part` file is kept (partial bytes are still valid for a future resume — the next resume will re-fetch the not-yet-hashed tail).
   - **`parallelRangeCount = 1` debug override**: read `ACERVO_PARALLEL_RANGES` from the environment at session config time; if set to `1`, force the single-request path even for large files. Used for narrowing down regressions during diagnostics.

7. **Redirect rejection stays enforced on every code path.** Every `URLSessionDataTask` (single-request OR range) flows through `SecureDownloadDelegate`, whose `willPerformHTTPRedirection` is invoked per-task and checks the host allowlist. The redirect-rejection contract is non-negotiable; if a code path could bypass it, the code path is wrong. S1's exit criteria include a deterministic redirect-rejection test on the single-request path; S2 adds the same test for the parallel-range path (but on the perf plan, per the user's gating decision — see S2 Task 1).

8. **Progress reporting on the parallel-range path.** Aggregate progress across all in-flight ranges: progress = (sum of bytes received across all ranges + already-on-disk prefix) / `sizeBytes`. Fire from the coordinator at each `hashedThrough` advancement, not at each range chunk — keeps callback rate similar to the single-request path.

9. **Preserve resume.** `.part`-file resume continues to work unchanged for both paths. The parallel-range path computes its sub-ranges *after* applying `resumeOffset`, so the on-disk prefix is consumed by the hasher before any range request fires.

10. **Keep `bytes(for:)` in place for the manifest fetch.** Manifests are small (≪ 1 MB); chunking and parallel ranges are unnecessary overhead. The delegate-shape changes in Task 2 do not affect this path.

11. **Leave `fallbackDownloadFile` (lines ~857–928) untouched** per §2.5.

**Exit criteria**:
- [ ] `make build` succeeds.
- [ ] `grep -rn "AsyncBytes" Sources/SwiftAcervo/` returns zero hits outside comments.
- [ ] `streamFlushSize`, `parallelRangeThreshold`, `parallelRangeCount` exist as single named file-scope constants in `AcervoDownloader.swift`, each with a one-line `why` comment referencing the design above. No duplicate magic numbers for any of these values elsewhere in the file.
- [ ] `SecureDownloadSession.shared` is configured with: `assumesHTTP3Capable = true`, `httpMaximumConnectionsPerHost = 8`, `waitsForConnectivity = true`, the two timeouts from Task 3, and `requestCachePolicy = .reloadIgnoringLocalCacheData` (unchanged).
- [ ] `SecureDownloadDelegate` implements both `URLSessionDataDelegate.didReceive data:` and `URLSessionDataDelegate.didReceive response:completionHandler:`, plus the existing `willPerformHTTPRedirection`. A per-task consumer registry is in place; one delegate instance per session, not one per task.
- [ ] All existing `ResumableDownloadTests` pass unchanged via `make test` (CI-gated).
- [ ] All existing `AvailabilityThreeStateTests` pass unchanged via `make test` (CI-gated).
- [ ] **Single-request path redirect rejection (CI-gated):** a deterministic `URLProtocol`-mocked test confirms that a non-CDN redirect on a single-stream download fails with the existing redirect-rejection error. On `SwiftAcervo-macOS.xctestplan`.
- [ ] **Single-request path resume (CI-gated):** a deterministic test confirms that resuming from a partial `.part` produces a manifest-matching SHA via the new delegate-driven code path. On `SwiftAcervo-macOS.xctestplan`.

---

### Sortie 2: Regression tests (CI-gated, single-stream only) and parallel-range + performance tests (out-of-CI)

**Priority**: 3 — Leaf sortie. Locks in correctness for the single-stream delegate path in CI, and parks both the parallel-range correctness tests and the wall-clock perf tests on the out-of-CI performance plan per the user's gating decision.

**Caveat acknowledged**: putting the parallel-range reorder-buffer correctness test on the performance plan (rather than CI) means a regression in the reorder buffer (e.g. seek-offset bug, off-by-one on range boundaries, hasher fed bytes out of order) will NOT fail CI. The signal will only fire when a developer runs `make test-perf` locally. This is a deliberate tradeoff for CI cleanliness; reconsider if reorder-buffer churn becomes a source of silent regressions.

**Entry criteria**:
- [ ] Sortie 1 exit criteria all met (delegate path lands; HTTP/3 enabled; parallel-range path implemented; existing tests green).
- [ ] Sortie 1 defined concrete values for `streamFlushSize`, `parallelRangeThreshold`, `parallelRangeCount`. S2 references those constants when computing expected hasher call counts and range counts; it does not invent its own.

**Tasks**:

1. **Create the CI-gated test file** at `Tests/SwiftAcervoTests/StreamingChunkingTests.swift`. Register on `SwiftAcervo-macOS.xctestplan` (and `SwiftAcervo-iOS.xctestplan` if platform-agnostic). Every test in this file uses a `URLProtocol` mock that serves a file **below** `parallelRangeThreshold`, so the single-request code path is exercised. **No test in this file touches the parallel-range path.**
   - **Test B — flush-call-count contract (CI).** Download a synthetic file of size `streamFlushSize * 32` (e.g. 8 MB if `streamFlushSize = 256 KB`) from a `URLProtocol` mock through a hasher whose `update(...)` calls are counted. Assert `callCount ≤ ceil(fileSize / streamFlushSize) + smallMargin`. Pure function of fixture size and the S1 constant — fully deterministic.
   - **Test C — resume on the delegate path (CI).** Start from a partial `.part` at a known offset (still below `parallelRangeThreshold`), complete via the delegate-driven single-request path against a `URLProtocol` mock, assert final SHA matches the manifest. Deterministic.
   - **Test D — redirect rejection on the single-request path (CI).** A `URLProtocol` mock issues a redirect to a non-CDN host mid-transfer; assert the download fails with the redirect-rejection error. Deterministic. (Overlaps S1's exit-criterion test; S2 confirms the test is on the plan and continues to pass.)
   - **Test E — HTTP/3 capability flag set (CI, trivial).** Read back `SecureDownloadSession.shared.configuration.assumesHTTP3Capable` and assert `== true`. Cheap regression guard for someone accidentally reverting Task 3 of S1.

2. **Create the out-of-CI performance test file** at `Tests/SwiftAcervoTests/StreamingPerformanceTests.swift`. This file:
   - **MUST NOT** be registered on `SwiftAcervo-macOS.xctestplan` or `SwiftAcervo-iOS.xctestplan`.
   - **MUST** be registered on a new `.swiftpm/xcode/xcshareddata/xctestplans/SwiftAcervo-Performance.xctestplan` (create this plan). The plan's `testTargets` lists `SwiftAcervoTests` with an `onlyTests` filter selecting only `StreamingPerformanceTests`.
   - Contains both wall-clock measurements AND the parallel-range correctness tests (per the user's gating decision — all parallel-range tests stay off CI):
     - **Test A — wall-clock measurement (off CI).** Download a 256 MB synthetic file from an in-process `URLProtocol` mock that injects realistic per-chunk delays (e.g. 1ms per 64 KB) to simulate a network. Record and print the wall-clock duration. The test asserts the download *completes successfully* — it does **not** assert a numeric ceiling. Wall-clock numbers are emitted for human review.
     - **Test F — parallel-range reorder buffer correctness (off CI).** Synthetic file of size `parallelRangeThreshold * 2` (e.g. 128 MB) served by a `URLProtocol` mock that responds to `Range:` headers. Mock injects **deliberate out-of-order completion** (e.g. delay range 0 by 100ms, range 1 by 0ms, range 2 by 50ms, range 3 by 25ms) so ranges complete in a non-sequential order. Assert: (a) final SHA matches the manifest, (b) destination file size matches the manifest, (c) HTTP response code recorded for each range is 206. Deterministic — pure function of mock delays and file content.
     - **Test G — parallel-range redirect rejection (off CI).** A `URLProtocol` mock issues a non-CDN redirect on one of the four range requests; assert the entire download fails with the redirect-rejection error and the other range tasks are cancelled. Deterministic.
     - **Test H — parallel-range resume (off CI).** Start from a `.part` file at an offset such that the remaining tail exceeds `parallelRangeThreshold` (so the resume tail triggers parallel ranges). Complete via the parallel-range code path; assert final SHA matches the manifest.
     - **Test I — `ACERVO_PARALLEL_RANGES=1` debug override (off CI).** Set the env var, instantiate a fresh `URLSession` config, request a file > `parallelRangeThreshold`, assert only one `URLSessionDataTask` was created (count via the `URLProtocol` mock). Confirms the kill-switch works.
   - Rationale: shared CI runners (`macos-26`) are noisy, and per the user's gating decision, the parallel-range path's correctness tests live alongside the wall-clock perf tests on the perf plan, not CI. The single-request path (Tests B/C/D/E in Task 1) carries the CI regression signal for the delegate-driven code.

3. **Add a `make test-perf` target to the Makefile** that runs the performance plan explicitly:
   ```
   test-perf:
   \txcodebuild test -scheme $(TEST_SCHEME) -testPlan SwiftAcervo-Performance \
   \t  -destination $(DESTINATION)
   ```
   Document in `Docs/BUILD_AND_TEST.md` that `make test-perf` is run manually on a developer machine, never in CI. Explicitly call out that the perf plan also carries the parallel-range correctness tests (Tests F/G/H/I) — running it before shipping changes to `AcervoDownloader.swift` is recommended.

4. **Verify CI plans were not contaminated.** Open `SwiftAcervo-macOS.xctestplan` and `SwiftAcervo-iOS.xctestplan` and confirm neither plan lists `StreamingPerformanceTests` (directly or via unfiltered target glob). The CI plans contain only `StreamingChunkingTests` (Tests B/C/D/E) for the new file.

5. Re-run `ResumableDownloadTests` and `AvailabilityThreeStateTests` to confirm zero regressions.

**Exit criteria**:
- [ ] `make build` succeeds.
- [ ] `make test` runs `StreamingChunkingTests` (Tests B, C, D, E) plus all existing tests, all green. **No wall-clock thresholds and no parallel-range tests appear in CI-gated assertions.**
- [ ] `make test-perf` exists, points at `SwiftAcervo-Performance.xctestplan`, and runs Tests A, F, G, H, I to successful completion. Test A reports wall-clock without asserting a numeric ceiling.
- [ ] `SwiftAcervo-macOS.xctestplan` and `SwiftAcervo-iOS.xctestplan` do NOT include `StreamingPerformanceTests` (grep both plan JSON files to confirm).
- [ ] Test B's flush-call-count assertion holds against `streamFlushSize` from S1.
- [ ] Tests C, D, E confirm resume, redirect rejection, and HTTP/3 capability on the single-request path.
- [ ] Tests F, G, H, I (perf plan, off CI) confirm reorder-buffer correctness, redirect rejection, resume, and the debug-override kill-switch on the parallel-range path.
- [ ] No regression in `ResumableDownloadTests` or `AvailabilityThreeStateTests`.
- [ ] `Docs/BUILD_AND_TEST.md` documents `make test-perf` as developer-only / out-of-CI, and explicitly notes that parallel-range correctness lives on that plan.

---

## Parallelism Structure

**Critical Path** (length 3): `slug-registry/S1 → S2 → S3`. With S6 deferred to scheduled future work, the longest in-mission chain is the pure-code path through the slug-keyed API surface.

**Parallel Execution Groups**:

- **Group 1** (start in parallel — no shared dependencies between work units):
  - `slug-registry/S1` — Manifest schema (supervising agent; modifies the manifest type that other sorties read)
  - `chunked-streaming/S1` — Chunked download (independent file, independent concern; safe to run as a separate sortie-agent in parallel)
- **Group 2** (depends on `slug-registry/S1`; these three touch different APIs and can fan out as up to 3 parallel sortie agents):
  - `slug-registry/S2` — slug-keyed `availability(_:)` + shared aggregation helper
  - `slug-registry/S4` — slug-keyed `deleteModel(_:)`
  - `slug-registry/S5` — `acervo ship` CLI (separate target — `Sources/acervo/`)
  - **Parallel-safety note**: S2 introduces the aggregation helper. If S2 and S4 collide on the manifest cache, dispatch S4 *after* S2. The conservative ordering is S2 → S4 sequential, S5 in parallel with both.
- **Group 3** (depends on Group 2):
  - `slug-registry/S3` — `ensureAvailable(slug:url:files:progress:)` (depends on S2's aggregation helper)
  - `chunked-streaming/S2` — chunk-count + resume regression tests, perf-plan setup (depends on chunked-streaming/S1)
  - Both can run in parallel as separate sortie agents.
- **Group 4**: (none — S6 is deferred to scheduled future work)

**Agent Constraints**:
- **Supervising agent**: Per the parallelism enforcement rule, build-bearing sorties belong to the supervising agent's dispatch chain. In practice every sortie in this plan has `make build` in its exit criteria, so all sorties are dispatched as full sortie agents (not no-build sub-agents). Parallelism here means *multiple sortie agents running concurrently*, each doing its own build, not sub-agents off the supervising context.
- **Maximum parallelism**: 3 concurrent sortie agents at peak (Group 2), well under the 4-agent ceiling.

---

## Open Questions & Missing Documentation

### Resolved (auto-fixed during refinement)

| Sortie | Original Issue | Resolution |
|--------|----------------|------------|
| `slug-registry/S1` | "Infer `modelId` from the HF repo string" was vague | Pinned to: legacy-manifest fallback sets `modelId == primaryRepo == repo`, `components == [repo]`. |
| `slug-registry/S1` | Cache shape (single dict vs two indices) was undecided | Both shapes acceptable; minimize the diff against today's cache. |
| `slug-registry/S2` | "Correct weighted progress" had no formula for in-flight contribution | Pinned to: in-flight component contributes its own `progress` value to the weighted average. Tests assert an exact numeric expected value, not a fuzzy range. |
| `slug-registry/S3` | Test (c) ("callback matches poll at the same moment") was race-based | Replaced with a deterministic helper-equivalence test: extract a pure aggregation helper, test the helper with fixture state, then verify both code paths consume the same helper. |
| `slug-registry/S5` | `--spec components.json` file format was undefined | Pinned to a concrete JSON schema with `modelId` / `primaryRepo` / `components` fields. |
| `chunked-streaming/S1` | `streamChunkSize` was referenced but never defined | Replaced with three named file-scope constants — `streamFlushSize` (256 KB, in-memory flush quantum on the delegate path), `parallelRangeThreshold` (64 MB, size above which a file uses parallel-range fetching), `parallelRangeCount` (4, concurrent ranges per large file). S2 Test B asserts call counts against `streamFlushSize`. |
| `chunked-streaming/S1` | "Delegate route vs AsyncBytes-batching fallback" was an unresolved implementation branch | Resolved as **delegate-only**. `URLSession.AsyncBytes` is dropped entirely; the `SecureDownloadDelegate` is extended to a `URLSessionDataDelegate` with a per-task consumer registry. The redirect-rejection contract is preserved because the delegate stays per-session (one instance, host-pinned). |
| `chunked-streaming/S1` | R2 CDN-specific speed features were not exploited | Resolved by enabling HTTP/3 (`assumesHTTP3Capable = true`), tuning `httpMaximumConnectionsPerHost = 8` for parallel-range fanout, `waitsForConnectivity = true` for transient blips, and adding **parallel HTTP Range fetches** for files > 64 MB with a reorder buffer for sequential SHA-256 consumption. See the "R2 CDN Speed Surface" section. |
| `chunked-streaming/S2` | Wall-clock ceiling on CI was vague and flake-prone | Resolved by moving the wall-clock test to a separate `SwiftAcervo-Performance.xctestplan` invoked only by `make test-perf`. CI gates the flush-call-count *contract* (deterministic, single-request path only). Per-user gating decision, the parallel-range correctness tests **also** live on the perf plan, not CI — see S2's "Caveat acknowledged" note. |
| `slug-registry/S4` | "Documented error" for missing-manifest delete was undefined | Resolved: `deleteModel` does not check existence. Folder-not-present is a no-op success; only filesystem failure (`FileManager.removeItem` failing on an existing folder) throws. Manifest-fetch failure throws the same HTTP error as S2/S3. |
| `slug-registry/S6` | "Sensible results end-to-end" was unmeasurable; live-CDN smoke test was vague and flake-prone | Resolved by deferring S6 entirely. Live-CDN testing is out of scope for this mission and is rescheduled as operator-tended future work. |
| API surface | `/`-based slug-vs-repo heuristic was fragile (slug could contain `/`) | Resolved by the API Model section: signature is `(slug: String, url: URL? = nil)`. Slugs may contain `/`; URL is supplied separately when derivation cannot apply. |
| `slug-registry/S1` | `primaryRepo` semantics for multi-component manifests unpinned | Resolved: all component manifests in a multi-component slug share the same `primaryRepo` (the spec-level value). Single-component: `primaryRepo == sole repo`. |
| `slug-registry/S1` | Migration shim with no removal task → immortal dead code risk | Resolved: no migration shim. Manifests must carry the new fields or fail to decode. |
| `slug-registry/S5` | CLI tests' upload semantics ambiguous (live R2 vs mock vs dry-run) | Resolved: S5 introduces `--dry-run` flag; CLI tests use it exclusively. No CLI test touches live R2. |

### Unresolved (must address before or during execution)

_None._ The previously-open implementation-branch question (delegate vs AsyncBytes-batching) is now resolved in favor of delegate-only. No unresolved item gates any sortie in this mission.

---

## Scheduled Future Work (not part of this mission)

These items are explicitly out of scope for the current execution but are tracked here so they don't get lost.

### Deferred: Data migration — re-upload three Vinetas manifests

**Why deferred**: requires live R2 credentials and live-CDN smoke testing, which the user has chosen to schedule separately as a long-running operator-tended task.

**Prerequisites** (must be true before this work is dispatched):
- `slug-registry` work unit landed and `acervo ship --slug` / `--spec` / `--dry-run` exists.
- R2 / CDN credentials available in the operator's environment.
- Vinetas's full component lists for Flux2 Klein 4B and 9B are confirmed (fetch from `SwiftVinetas/Sources/SwiftVinetas/Engine/Flux2Engine.swift` or the Vinetas maintainer).

**Work**:
1. Re-upload `pixart-sigma-xl` (single-component) using `acervo ship --slug pixart-sigma-xl ...`.
2. Re-upload `flux2-klein-4b` using a spec file listing transformer + VAE + text-encoder.
3. Re-upload `flux2-klein-9b` with the same component set.
4. After each upload, fetch the manifest and assert: `modelId`, `primaryRepo`, `components` are present and match the expected concrete values (no "sensible results" language — the smoke check is a structural shape assertion against known expected values).
5. Record CDN URLs + verification output in a migration note under `Docs/`.

**Exit criteria** (for the deferred task, when it eventually runs):
- All three slugs' CDN manifests carry the new fields with the expected values.
- A consumer-level `availability(slug: "flux2-klein-4b")` (no URL) successfully fetches and decodes the manifest end-to-end (asserts no throw + correct `components.count`).
- Migration note committed under `Docs/`.

---

## Summary

| Metric | Value |
|--------|-------|
| Work units | 2 |
| Total sorties in mission | 7 (slug-registry S1–S5 + chunked-streaming S1–S2; S6 deferred) |
| Deferred to scheduled future work | 1 (slug-registry/S6 — live-CDN data migration) |
| Dependency structure | 2 parallel work units at Layer 1; sorties sequential within each work unit |
| Critical path length | 3 sorties (S1 → S2 → S3 within slug-registry) |
| Maximum parallel sortie agents | 3 (Group 2 peak) |
| Blocking open questions | 0 |
| Operator-assisted sorties in mission | 0 (live-CDN work was the only such sortie and is now deferred) |
