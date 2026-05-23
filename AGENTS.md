# AGENTS.md

Entry point for AI agents working in this repository.

This file is intentionally minimal. SwiftAcervo ships two surfaces:

## Library

Swift package consumed by other apps and libraries. The full reference — every public symbol, signature, and usage pattern — lives at **[Docs/USAGE-library.md](Docs/USAGE-library.md)**, compiled directly from `Sources/SwiftAcervo/`. Read it before suggesting changes to the public API.

## CLI

`acervo`, the operator-side command-line tool. The full reference — every subcommand with flags and examples — lives at **[Docs/USAGE-cli.md](Docs/USAGE-cli.md)**, captured from `acervo --help` output. Read it before suggesting changes to CLI behavior.

---

For project-level guidance (build commands, test conventions, platform requirements, security rules), read [CLAUDE.md](CLAUDE.md).
