# SwiftAcervo

Manifest-driven shared AI model discovery, download, and verification for iOS 26.0+ and macOS 26.0+. Zero external dependencies (Foundation + CryptoKit only).

This repository ships two things:

## Library

A Swift package that consuming apps and libraries add as a dependency to discover, download, and verify shared AI models from a private CDN. The full reference is at **[Docs/USAGE-library.md](Docs/USAGE-library.md)** — that document is compiled from the public API surface in `Sources/SwiftAcervo/` and is the source of truth for how to integrate SwiftAcervo.

## CLI

`acervo`, a command-line tool for operator-side workflows: downloading models from HuggingFace, generating CDN manifests, uploading to R2, verifying integrity, and managing local cache. The full reference is at **[Docs/USAGE-cli.md](Docs/USAGE-cli.md)** — that document is the captured `acervo --help` output for every subcommand.

---

License: see [LICENSE](LICENSE). Contributing: see [Docs/CONTRIBUTING.md](Docs/CONTRIBUTING.md).
