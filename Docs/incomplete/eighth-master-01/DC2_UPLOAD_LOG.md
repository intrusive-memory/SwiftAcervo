# DC2_UPLOAD_LOG.md — OPERATION EIGHTH-MASTER iteration 01

This log records per-slug validation and upload outcomes for Sortie DC-2 (live CDN re-upload of three Vinetas manifests).

**Security note**: No credential values, account IDs, endpoint URLs, or signed URLs appear in this log.

---

## pixart-sigma-xl

| Field | Value |
|-------|-------|
| Slug | pixart-sigma-xl |
| HF Repo | PixArt-alpha/PixArt-Sigma-XL-2-1024-MS |
| Spec file | Docs/incomplete/eighth-master-01/dc2-specs/pixart-sigma-xl.json |
| Sortie | DC-2a |

### Pre-validation

| Check | Result | Notes |
|-------|--------|-------|
| Validation timestamp | 2026-05-23T19:19:45Z | |
| Pre-validation manifest SHA-256 digest | N/A | Manifest does not exist on CDN (HTTP 404 at all candidate paths) |
| (a) `modelId` = "pixart-sigma-xl" | FAIL | No manifest exists |
| (b) `primaryRepo` = "PixArt-alpha/PixArt-Sigma-XL-2-1024-MS" | FAIL | No manifest exists |
| (c) `components` includes "PixArt-alpha/PixArt-Sigma-XL-2-1024-MS" | FAIL | No manifest exists |
| (d) Any `files[].path` contains `/` (depth ≥ 1) | FAIL | No manifest exists |
| Decision | RE_UPLOAD_REQUIRED | Manifest entirely absent from CDN |
| Operator initials | TBD | |

### CDN paths checked (all returned HTTP 404)

- `<cdn-base>/models/pixart-sigma-xl/manifest.json`
- `<cdn-base>/models/PixArt-alpha_PixArt-Sigma-XL-2-1024-MS/manifest.json`
- `<cdn-base>/models/pixart-sigma-xl-dit-int4/manifest.json`
- `<cdn-base>/models/t5-xxl-encoder-int4/manifest.json`
- `<cdn-base>/models/sdxl-vae-decoder-fp16/manifest.json`

### Upload

| Field | Value |
|-------|-------|
| Upload performed | CANCELLED (operator decision) |
| Log file | /tmp/acervo-dc2a-pixart-sigma-xl.log (preserved; not committed) |
| PID file | /tmp/acervo-dc2a-pixart-sigma-xl.pid (process killed; file stale) |
| Upload started | 2026-05-23T19:19:45Z |
| Upload duration | ~2h12m before cancellation |
| Upload cancelled | 2026-05-23T~21:32Z (PID 81371 SIGTERM, exited cleanly) |

### Cancellation rationale

The single-threaded upload was measured at ~2.6 MB/s effective throughput against R2 (one TLS connection, sequential per-file PUT). At that rate, the remaining ~15–20 GB of shards (text_encoder shard 2 + transformer shards + vae) would have taken another 3–6 hours. Operator decision to cancel and defer the live-CDN upload work until either (a) a faster pipe is available, or (b) `acervo ship` gains parallel multipart upload, or (c) the upload is driven by a faster tool (rclone parallel, `aws s3 cp --cli-write-timeout=0`).

Files uploaded before cancellation: README.md, asset/4K_image.jpg, asset/logo-sigma.png, asset/model.png, model_index.json, scheduler/scheduler_config.json, text_encoder/config.json (7 small files = ~4.2 MB), plus partial upload of text_encoder/model-00001-of-00002.safetensors (9.99 GB shard, partial — exact byte count unknown without lsof on a now-dead process).

Staging directory `/private/tmp/acervo-staging/PixArt-alpha_PixArt-Sigma-XL-2-1024-MS/` (20 GB) preserved per operator decision for potential resume.

### Post-upload validation — N/A (upload cancelled)

The four post-upload checks would have re-fetched the CDN manifest and asserted `modelId` / `primaryRepo` / `components` / nested paths. With the upload cancelled, the CDN state for `pixart-sigma-xl` remains as it was pre-upload (HTTP 404 at all candidate paths). No post-upload validation possible until the upload is re-attempted.

### Handoff to future mission

See `Docs/incomplete/QUEUE.md` carry-forwards: "DC-2 deferred — Vinetas re-upload of pixart-sigma-xl + flux2-klein-4b + flux2-klein-9b". When revived, the spec at `Docs/incomplete/eighth-master-01/dc2-specs/pixart-sigma-xl.json` is reusable; the staging dir may or may not survive `/private/tmp` clear.

---

## flux2-klein-4b

*Assigned to Sortie DC-2b. Not this sortie's scope.*

---

## flux2-klein-9b

*Assigned to Sortie DC-2c. Not this sortie's scope.*
