# TODO

## 2026-05-18 — Three-state model-availability API + resumable downloads

Source-of-truth doc: [`Docs/MODEL_AVAILABILITY_PATH.md`](Docs/MODEL_AVAILABILITY_PATH.md).

Driven by a user-reported symptom in Vinetas: "the model downloads every time, step 0 of 20 sticks for a long time." A live `sample` of the running app confirmed the dominant CPU cost is byte-at-a-time `Data.append` in `AcervoDownloader.streamDownloadFile`, plus no resume support, plus no in-flight dedup.

The user's stated invariant: Vinetas/SwiftVinetas should depend entirely on Acervo for model state, and Acervo should answer with one of three states — `notAvailable`, `downloading`, `available`. The library is currently two-state.

### Items

- [ ] **Add a three-state status API.** `public static func availability(_ modelId: String) async -> ModelAvailability` returning `.notAvailable | .downloading(progress:) | .available`. This becomes the only API SwiftVinetas/Vinetas need to call to decide what to show in the UI.
- [ ] **Add an `InFlightDownloads` actor** that maps `modelId → Task<URL, Error>`. `ensureAvailable` first asks the actor for an existing task; if one exists, it `await`s it. If not, it registers a new task and runs `downloadFiles`. Two parallel callers must converge on one network download.
- [ ] **Tighten `isModelAvailable(_:)` semantics.** Today it returns `true` if `config.json` exists at the model root. That's a footgun — `Flux2Engine` and `Flux2ModelDownloader` had to add stricter parallel checks (`verifyModel(at:).complete`) precisely because "config.json exists" doesn't imply "all weight shards are present and size-matched." New contract: `isModelAvailable` returns `true` only if every file in the cached manifest exists with the manifest's recorded `sizeBytes`. Optionally: verify SHA on a slower `isModelAvailableVerified(_:)`.
- [ ] **Chunk `streamDownloadFile`.** Replace the `for try await byte in asyncBytes` byte-at-a-time loop (`Sources/SwiftAcervo/AcervoDownloader.swift:513-534`) with chunked reads. Two viable shapes:
  - Use `URLSession.bytes(for:)` plus a `Data` buffer the way it is, but consume from `asyncBytes` in larger reads (the `AsyncBytes` API doesn't expose a chunk size — wrap it in an `AsyncSequence` extension that batches up to `streamChunkSize` bytes before yielding).
  - Or switch to a `URLSessionDataDelegate` and write chunks straight from `urlSession(_:dataTask:didReceive:)`.
  - Acceptance: a `sample` during a multi-GB download no longer shows `_platform_memmove` / `Data._Representation.replaceSubrange` as the dominant cost.
- [ ] **Resumable downloads.** Today `streamDownloadFile` writes to `temporaryDirectory/UUID` and `try? fm.removeItem(...)` on every failure path (`Sources/SwiftAcervo/AcervoDownloader.swift:500, 548, 563, 585`). Replace with:
  - Temp path = `destination + ".part"` (same volume — `moveItem` is rename-only on the final hop, no copy).
  - On retry, if `.part` exists and `.part`'s size < `manifestFile.sizeBytes`, send `Range: bytes=<size>-` and append to the file handle. Seed the running SHA-256 from the partial bytes (or fall back to re-hashing the prefix from disk).
  - Acceptance: kill the app mid-shard; reopen; the same shard resumes from the partial offset, not byte 0.
- [ ] **Drop `.fileExists` / `.tempFileURL` cleanup-only paths** that exist purely because we treat any interruption as fatal. Once resume is in, an interrupted download is the normal case, not an error.

### Out of scope for this work item

- Component registry / `ComponentDescriptor` (keep as-is — engines should keep registering components; the change is the read API on top).
- App-Group / `ACERVO_APP_GROUP_ID` directory resolution (unchanged).
- Telemetry event surface (`cacheHit` / `cacheMiss` / `downloadOperationStart` / `downloadOperationComplete` is enough to derive the three states).
