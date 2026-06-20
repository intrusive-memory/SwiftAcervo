# AGENTS.md

Entry point for AI agents working in this repository.

This file is intentionally minimal. SwiftAcervo ships three surfaces:

## Library

Swift package consumed by other apps and libraries. The full reference — every public symbol, signature, and usage pattern — lives at **[Docs/USAGE-library.md](Docs/USAGE-library.md)**, compiled directly from `Sources/SwiftAcervo/`. Read it before suggesting changes to the public API.

## CLI

`acervo`, the operator-side command-line tool. The full reference — every subcommand with flags and examples — lives at **[Docs/USAGE-cli.md](Docs/USAGE-cli.md)**, captured from `acervo --help` output. Read it before suggesting changes to CLI behavior.

Subcommands: `list`, `download`, `upload`, `ship`, `manifest`, `verify`, `delete`, `recache`. `acervo list` prints one model slug per line for every directory under `models/` in the CDN bucket (sorted); it is a raw inventory and does not validate models.

### Environment variables

The CLI resolves every credential and path from the environment — the library never reads `ProcessInfo.environment` itself.

| Variable | Required for | Default | Purpose |
| --- | --- | --- | --- |
| `HF_TOKEN` | private/gated HF downloads | — | HuggingFace API token (or pass `--token`) |
| `R2_ACCESS_KEY_ID` | `list`, `upload`, `ship`, `recache`, `delete --cdn` | — | R2 access key id |
| `R2_SECRET_ACCESS_KEY` | CDN operations | — | R2 secret access key |
| `R2_ENDPOINT` | CDN operations | — | R2 S3-compatible API endpoint (signed writes + listing) |
| `R2_PUBLIC_URL` | CDN operations | — | Public CDN base URL (readback verification) |
| `R2_BUCKET` | optional | `intrusive-memory-models` | Bucket name |
| `R2_REGION` | optional | `auto` | Region literal |
| `STAGING_DIR` | optional | `/tmp/acervo-staging` | Staging root for `download` / `recache` |
| `ACERVO_APP_GROUP_ID` | cache-scoped ops | — | App Group id locating the shared models directory |
| `ACERVO_MODELS_DIR` | optional | — | Absolute override for the shared models directory (takes precedence over the App Group) |
| `ACERVO_OFFLINE` | optional | — | When set (e.g. `=1`), forbid all network access; serve only on-disk content |

## UI Components

`SwiftAcervoUI`, the SwiftUI surface (rows, sections, the full catalog manager, the add/edit sheet, SwiftData persistence). The full reference lives at **[Docs/USAGE-ui-components.md](Docs/USAGE-ui-components.md)**. Each component has a `#### For coding agents` subsection with trigger phrases, prerequisites, the wiring contract, and anti-patterns — read it before wiring a host app's model UI.

## Queryable Codemap

A prebuilt [graphify](https://pypi.org/project/graphifyy/) knowledge graph of this
codebase lives in [`graphify-out/`](graphify-out/) (2958 nodes · 5961 edges). **Prefer
querying it before grepping** for architecture or "what connects to what" questions:

```bash
graphify query "How does X flow through the system?"
graphify path "TypeA" "TypeB"      # shortest path between two nodes
graphify explain "SomeType"        # plain-language node explanation
```

Human-readable summary: [`graphify-out/GRAPH_REPORT.md`](graphify-out/GRAPH_REPORT.md).
Refresh after significant changes with `/codemap` (or
`graphify . --backend claude-cli`).

---

For project-level guidance (build commands, test conventions, platform requirements, security rules), read [CLAUDE.md](CLAUDE.md).
