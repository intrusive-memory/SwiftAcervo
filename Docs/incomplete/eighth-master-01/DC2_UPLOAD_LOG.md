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
| Upload performed | IN_PROGRESS |
| Log file | /tmp/acervo-dc2a-pixart-sigma-xl.log |
| PID file | /tmp/acervo-dc2a-pixart-sigma-xl.pid |
| Upload started | 2026-05-23T19:19:45Z |
| Upload duration | PENDING |
| Upload completed | PENDING |

### Post-upload validation

| Check | Result | Notes |
|-------|--------|-------|
| (a) `modelId` = "pixart-sigma-xl" | PENDING | |
| (b) `primaryRepo` = "PixArt-alpha/PixArt-Sigma-XL-2-1024-MS" | PENDING | |
| (c) `components` includes "PixArt-alpha/PixArt-Sigma-XL-2-1024-MS" | PENDING | |
| (d) Any `files[].path` contains `/` (depth ≥ 1) | PENDING | |
| Post-upload manifest SHA-256 digest | PENDING | |
| Timestamp completed | PENDING | |
| Operator initials | TBD | |

---

## flux2-klein-4b

*Assigned to Sortie DC-2b. Not this sortie's scope.*

---

## flux2-klein-9b

*Assigned to Sortie DC-2c. Not this sortie's scope.*
