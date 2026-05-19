# REQUIREMENTS — SwiftAcervo open work items

**Status:** Active.
**Last reconciled:** 2026-05-19.
**Predecessor doc:** [`Docs/complete/REQUIREMENTS-three-state-availability.md`](Docs/complete/REQUIREMENTS-three-state-availability.md) — shipped substantially in v0.14.0; §4.4 (chunked streaming) was deferred and continues as §2 below.

This file is the contract for the next round of SwiftAcervo work. Two independent items: a manifest-driven slug registry for multi-component models (§1, blocking Vinetas's UI rework) and the deferred chunked-streaming perf fix (§2, addresses the original "step 0 of 20 sticks" symptom that motivated the predecessor doc).

---

## 1. Manifest-driven slug registry for multi-component models

**Source-of-truth doc:** [`../Vinetas/docs/REQUIREMENTS-acervo-3-state.md`](../Vinetas/docs/REQUIREMENTS-acervo-3-state.md) (§D1, §H2, §H9). Vinetas's UI rework is parked until this lands.

Extends the predecessor mission. That work delivered the three-state enum and the `Acervo.availability(_ modelId: String)` entry point (shipped in 0.14.0). This follow-on makes that entry point useful for **multi-component models** (Flux2 Klein 4B/9B carry transformer + VAE + text-encoder + … as separate HF repos) and for **slug-only consumers** (Vinetas, mlx-audio-swift, SwiftBruja, etc. — they don't know HF repo strings).

### 1.1 Why

Vinetas's `AvailableModel.id` is a slug — `"pixart-sigma-xl"`, `"flux2-klein-4b"`, `"flux2-klein-9b"`. The HF repo string is internal to SwiftVinetas (not on the public `ModelDescriptor` protocol). For Vinetas to call `Acervo.availability(model.id)` directly, Acervo has to resolve the slug. And for multi-component models the resolution has to fan out across components and aggregate the result. Per the Vinetas spec decision: manifest-driven, slug canonical.

### 1.2 Items

- [ ] **Manifest schema extension.** Add three required fields to the model manifest fetched from the CDN:
  - `modelId: String` — the slug (e.g. `"flux2-klein-4b"`)
  - `primaryRepo: String` — HF repo string; equals the sole repo for single-repo models
  - `components: [String]` — HF repo strings; `[primaryRepo]` for single-repo models, the full set for multi-component models. Each component string must already be a manifest-resolvable repo.
  Update the manifest type, the manifest-fetch path, and the in-memory cache.
- [ ] **Slug-keyed `availability(_:)`.** Today `Acervo.availability(_:)` forwards directly to repo-keyed Acervo state. After: detect slug vs HF repo string (heuristic: presence of `/`, or registry lookup), fetch manifest by slug, aggregate when multi-component:
  - All components `.available` → `.available`
  - Any component `.downloading(progress:)` → `.downloading(progress: weightedAggregate)` where the weight is `bytesTotal` per component (treat `.notAvailable` as 0, `.available` as 1; equal-weight where bytes are unknown)
  - Otherwise → `.notAvailable`

  Backwards-compat: existing HF-repo-keyed callers keep working. Both flavors funnel through the same telemetry emission per the existing `recordModelAvailability` invariant.
- [ ] **Slug-keyed `ensureAvailable(_:files:progress:)`.** For multi-component slugs, iterate components and share the existing `InFlightDownloads` dedup per `(modelId, file)`. The `progress:` callback emits the same bytes-weighted aggregate that `availability(_:)` returns so a UI progress bar driven by the callback agrees with availability polls.
- [ ] **Slug-keyed `deleteModel(_:)`.** Already sync/throws. For a multi-component slug, delete every component.
- [ ] **`acervo ship` tooling.** Accept a `--slug` arg (or a per-model spec file) so uploaded manifests carry the new fields. Update `Docs/CDN_UPLOAD.md` with the flow. For multi-component models, the tool should make it ergonomic to upload N component manifests that share one `modelId`.
- [ ] **Data migration — re-upload three Vinetas manifests** with the new fields populated. **Code changes above are dead weight until the manifests on the CDN actually carry the fields.**
  - `pixart-sigma-xl` (single-component)
  - `flux2-klein-4b` (multi-component; coordinated upload of all component manifests under one shared `modelId`)
  - `flux2-klein-9b` (same component set, 9B variant)

### 1.3 Cross-package coordination

- [ ] **SwiftVinetas D2 cleanup** (parallel — not blocking) — once the manifest registry is live, `Flux2Engine.isAvailable`'s per-component aggregation loop (`Sources/SwiftVinetas/Engine/Flux2Engine.swift:426-433`) becomes dead code (Acervo aggregates now). The engine's internal slug → HF mapping for Flux2 can also shrink. Worth landing alongside this work to avoid leaving SwiftVinetas with stale aggregation logic.

### 1.4 Acceptance

1. `await Acervo.availability("pixart-sigma-xl")` returns `.available` when the PixArt repo files are on disk at manifest-recorded sizes; `.notAvailable` otherwise.
2. `await Acervo.availability("flux2-klein-4b")` returns `.downloading(progress: 0.43)` (or similar weighted aggregate) when any component is in flight; `.available` only when *every* component is on disk and size-matched.
3. `try await Acervo.ensureAvailable("flux2-klein-4b", files: []) { p in ... }` downloads every component, and `p.overallProgress` matches the aggregate that `availability(_:)` would report mid-flight.
4. `try Acervo.deleteModel("flux2-klein-4b")` removes every component in one call.
5. `acervo ship --slug pixart-sigma-xl <...>` produces a manifest with `modelId`, `primaryRepo`, and `components` set correctly.
6. A repo-keyed call like `await Acervo.availability("black-forest-labs/FLUX.2-klein-4B")` continues to return today's repo-scoped result (backwards-compat).

### 1.5 Out of scope

- `AsyncStream<ModelAvailability>` push subscription (Vinetas can poll; see linked doc §G).
- Cancel-in-flight-download API.
- Cross-process UI notification (each consumer process polls independently).

---

## 2. Chunk `streamDownloadFile`

Carried over from the predecessor doc's §4.4. Deferred at execution time of the v0.14.0 mission per the commit message: *"Deferred: REQUIREMENTS §4.4 chunked streaming (own mission)"*.

### 2.1 Why

This is the original symptom that drove the predecessor doc: Vinetas reported "the model downloads every time, step 0 of 20 sticks for a long time." A live `sample` of the running process showed the dominant CPU cost is byte-at-a-time `Data.append` inside the streaming download loop. The predecessor's §4.5 (resumable `.part` files) and §4.2 (`InFlightDownloads` dedup) addressed the "downloads every time" half. The "sticks for a long time" half — CPU-bound during the actual transfer — is still open.

Acceptance signal #3 from the predecessor doc remains unmet: *"`sample` of the running process during a download no longer shows `Data.append` and `_platform_memmove` as the dominant cost."*

### 2.2 What

**Replace the byte-at-a-time loop** at `Sources/SwiftAcervo/AcervoDownloader.swift:745` (`for try await byte in asyncBytes { buffer.append(byte); ... }`) with a chunked variant.

**Recommended shape:** switch to a `URLSessionDataDelegate` and write chunks straight from `urlSession(_:dataTask:didReceive:)`. The `AsyncBytes` API does not expose a chunk size, so the only way to get true chunked reads without an extra batching layer is to leave `bytes(for:)` behind for streaming. Keep `bytes(for:)` for the manifest fetch (small).

**Alternative** if delegate plumbing is too disruptive: wrap `URLSession.AsyncBytes` in an `AsyncSequence` extension that batches up to `streamChunkSize` bytes per yield. Acceptable, slightly slower than the delegate path, but a strict improvement over byte-at-a-time. Choose this path if the delegate route requires reworking `SecureDownloadSession`.

**Both shapes must:**

- Feed each `Data` chunk into the SHA-256 hasher and the file handle in one shot (no intermediate per-byte accumulation).
- Update progress at the chunk boundary, not the byte boundary.
- Preserve cancellation: `try Task.checkCancellation()` at each chunk boundary, or use the delegate's `cancel()` on task cancellation.
- Preserve resume: the `.part` file logic from §4.5 (range header, hasher re-seed from disk) must still work — chunked reads are an inner-loop change, not a control-flow change.
- Preserve `SecureDownloadSession`'s redirect rejection. The delegate route specifically must still enforce non-CDN redirect blocking via `URLSessionTaskDelegate.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`. If integrating the delegate breaks that contract, fall back to the `AsyncBytes`-batching alternative.

### 2.3 Acceptance

- New test `Tests/SwiftAcervoTests/StreamingThroughputTests.swift`:
  - Downloads a 256 MB synthetic file from an in-process `URLProtocol` mock; asserts wall-clock time below a reasonable ceiling on the CI runner (pick the ceiling empirically — the criterion is "no longer CPU-bound").
  - Downloads a 16 MB synthetic file with a hash-update counter and asserts the hasher was called O(file_size / chunk_size) times, not O(file_size) times. This is the in-CI proxy for the `sample` signal.
- All existing `ResumableDownloadTests` continue to pass without modification — chunked streaming must not regress resume.
- All existing `AvailabilityThreeStateTests` continue to pass — the dedup actor isn't touched here.

### 2.4 Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Delegate-based streaming breaks `SecureDownloadSession`'s redirect rejection | Medium | Verify in tests: redirect-blocking still enforced via `URLSessionTaskDelegate.urlSession(_:task:willPerformHTTPRedirection:...)`. If delegate plumbing is too invasive, take the `AsyncBytes`-batching alternative. |
| Chunked reads break the SHA-256 seed-from-disk logic added in §4.5 | Low | The resume path runs *before* the network read begins, so it's not on the chunked codepath. Add an explicit test: resume from a `.part` file, complete via chunked transfer, assert final SHA matches manifest. |

### 2.5 Out of scope

- Persisting hasher state across processes to avoid the seed-from-disk read on resume (predecessor §7 trade-off — still acceptable).
- Touching `fallbackDownloadFile` (`AcervoDownloader.swift:857–928`); it's the second-chance retry that uses `URLSession.download(for:)` whole-file. If we want to delete it after chunked streaming proves stable, that's a follow-up.
