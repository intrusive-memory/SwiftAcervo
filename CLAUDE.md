# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

For detailed project documentation, see **[AGENTS.md](AGENTS.md)**.

## Quick Reference

**Project**: SwiftAcervo - Shared AI model discovery and management for HuggingFace models

**Platforms**: iOS 26.0+, macOS 26.0+

**Key Components**:
- Static `Acervo` API for model path resolution, discovery, and download
- `AcervoManager` actor for thread-safe operations with per-model locking
- URLSession-based HuggingFace file downloads with progress reporting
- Migration utility for legacy `intrusive-memory/Models/` cache paths

**Important Notes**:
- Canonical path: `~/Library/SharedModels/{org}_{repo}/`
- ONLY supports iOS 26.0+ and macOS 26.0+ (NEVER add code for older platforms)
- Zero external dependencies (Foundation only)
- This library does NOT load models -- it finds and downloads them. Loading is the consumer's job.
- `config.json` presence is the universal model validity marker
- See [AGENTS.md](AGENTS.md) for complete API reference and design patterns
- See [REQUIREMENTS.md](REQUIREMENTS.md) for full specification
