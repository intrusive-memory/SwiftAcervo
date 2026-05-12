# Documentation Audit: SwiftAcervo (April 2026)

## Current State

### Files Audited
- **AGENTS.md** — 393 lines, comprehensive but monolithic
- **CLAUDE.md** — 34 lines, thin quick reference
- **README.md** — 584 lines, user-focused introduction
- **ARCHITECTURE.md** — 148 lines, ecosystem dependency map
- **REQUIREMENTS.md** — 300+ lines, v2 component registry spec (draft)
- **CONTRIBUTING.md** — Guidelines for development
- **Docs/** directory — Archive, completed plans, examples

### Problems Identified

1. **AGENTS.md is the single source of truth** for all AI agent documentation, resulting in:
   - 13 distinct topics crammed into one file
   - Hard to navigate (no clear entry points for different use cases)
   - No dedicated "consuming library" usage guide (scattered across sections)
   - No dedicated API reference document (mixed with examples)
   - No dedicated build/CLI documentation (mixed with architecture)

2. **CLAUDE.md is too thin** — references AGENTS.md but doesn't surface all supporting docs:
   - Missing ARCHITECTURE.md reference
   - Missing REQUIREMENTS.md reference  
   - Missing link to consuming library usage patterns
   - Doesn't prioritize the "Usage for Consuming Libraries" section

3. **"Usage for Consuming Libraries" is buried** in AGENTS.md:
   - Located at lines 218–321 under "CDN-First Validation Pattern"
   - No dedicated document for consuming libraries
   - Consuming libraries have to search through architecture/design patterns to find integration examples

4. **Project structure information** (lines 34–67 of AGENTS.md) is implementation detail, not user-facing documentation.

---

## Recommended Structure

### Decentralized Documentation Hub

Split AGENTS.md into focused, single-purpose documents:

```
CLAUDE.md (Updated Quick Reference)
├── Quick facts (version, platforms, key components)
├── Critical notes (dependencies, platform requirements)
├── Links to all supporting docs
└── **Prominent link to USAGE.md for consuming libraries**

├─── USAGE.md (NEW - HIGHLIGHTED FOR CONSUMING LIBRARIES)
│    ├── For consuming library developers
│    ├── Integration checklist
│    ├── Real-world examples (SwiftBruja, mlx-audio-swift, etc.)
│    └── Common patterns and best practices
│
├─── API_REFERENCE.md (NEW)
│    ├── Acervo static API (all methods)
│    ├── AcervoManager actor API
│    ├── ComponentRegistry methods
│    ├── ModelDownloadManager
│    ├── Error types
│    └── Supporting types (AcervoModel, ComponentDescriptor, etc.)
│
├─── BUILD_AND_TEST.md (NEW)
│    ├── Make targets (build, test, lint, clean, resolve)
│    ├── acervo CLI tool
│    │   ├── ship (full pipeline)
│    │   ├── download, manifest, verify, upload (steps)
│    │   └── Environment variables
│    ├── Unit vs integration tests
│    ├── CI/CD (GitHub Actions)
│    └── Local development workflow
│
├─── CDN_ARCHITECTURE.md (NEW - from AGENTS.md lines 69–98)
│    ├── CDN base URL and URL patterns
│    ├── Download flow (7 steps)
│    ├── Manifest format
│    └── Security (redirect rejection, integrity verification)
│
├─── CDN_UPLOAD.md (NEW - from AGENTS.md lines 364–386)
│    ├── Uploading models to R2
│    ├── Using acervo ship/upload commands
│    ├── Required environment variables
│    ├── Legacy shell scripts (reference only)
│    └── Troubleshooting
│
├─── DESIGN_PATTERNS.md (NEW - from AGENTS.md lines 323–336)
│    ├── Static API + Actor pattern
│    ├── CDN-only downloads
│    ├── Per-file manifest verification
│    ├── Streaming SHA-256
│    ├── Concurrent file downloads
│    ├── Per-model locking
│    ├── Atomic downloads
│    ├── Zero external dependencies
│    └── Strict concurrency (Swift 6)
│
├─── PROJECT_STRUCTURE.md (NEW - from AGENTS.md lines 34–67)
│    ├── Source files (SwiftAcervo library)
│    ├── acervo CLI tool
│    ├── Tests
│    └── Tools (legacy scripts)
│
├─── SHARED_MODELS_DIRECTORY.md (NEW - from AGENTS.md lines 15–32)
│    ├── Canonical path (App Group container)
│    ├── Directory structure
│    ├── Naming conventions
│    ├── Validity marker (config.json)
│    ├── Model families
│    └── Critical rules for all projects
│
├─── ARCHITECTURE.md (Existing - kept as-is)
│    └── Ecosystem dependency map + interface contracts
│
├─── REQUIREMENTS.md (Existing - kept as-is)
│    └── v2 component registry spec
│
├─── README.md (Existing - user-facing introduction)
│    └── Installation, quick start, examples
│
├─── AGENTS.md (UPDATED - becomes hub/summary)
│    ├── Link to all supporting docs
│    ├── Quick facts (version, status)
│    └── Navigation for different user types
│
└─── CLAUDE.md (UPDATED - for Claude Code usage)
     ├── Quick reference for AI agents
     ├── Critical rules (dependencies, platforms)
     ├── Links to all documentation
     └── Build/test quick commands
```

---

## Migration Plan

### Phase 1: Create New Documents
1. Create **USAGE.md** (most important for consuming libraries)
2. Create **API_REFERENCE.md**
3. Create **BUILD_AND_TEST.md**
4. Create **CDN_ARCHITECTURE.md**
5. Create **CDN_UPLOAD.md**
6. Create **DESIGN_PATTERNS.md**
7. Create **PROJECT_STRUCTURE.md**
8. Create **SHARED_MODELS_DIRECTORY.md**

### Phase 2: Update Navigation
1. Update **CLAUDE.md** to reference all new documents and highlight USAGE.md
2. Update **AGENTS.md** to be a navigation hub
3. Update **README.md** to link to USAGE.md for consuming libraries

### Phase 3: Cleanup
1. Archive old AGENTS.md as Docs/archive/AGENTS_v1_monolithic.md (if needed for history)
2. Remove redundancy between README.md and new docs
3. Ensure no information is lost (audit for completeness)

---

## Key Recommendations

### For Consuming Libraries (HIGHEST PRIORITY)

**USAGE.md should contain:**
1. **Quick start** — "I want to integrate Acervo into my library. What do I do?"
2. **Integration checklist**
   - [ ] Add SwiftAcervo to Package.swift
   - [ ] Call `Acervo.ensureAvailable()` or `ModelDownloadManager` at startup
   - [ ] Define required files for your models
   - [ ] Handle download errors
   - [ ] Provide progress feedback to users
3. **Real-world examples** (already in AGENTS.md, move to USAGE.md):
   - SwiftBruja (MLX inference)
   - mlx-audio-swift (Text-to-speech)
   - SwiftVoxAlta (Voice processing)
   - Produciesta (Production app)
4. **Common patterns**:
   - Single-model validation (`Acervo.modelInfo()`)
   - Multi-model batch downloads (`ModelDownloadManager`)
   - Progress UI integration
   - Error handling and recovery
   - Thread-safe access (`AcervoManager`)
5. **FAQ**
   - "What files does my model need?"
   - "How do I handle downloads in background?"
   - "Can multiple apps share models?"
   - "What if download fails partway?"

### Highlight in All Entry Points

- **README.md** — Add prominent section: "For Consuming Libraries → See [USAGE.md](USAGE.md)"
- **CLAUDE.md** — First link under "See also": **[USAGE.md](USAGE.md)** "Integration guide for consuming libraries"
- **AGENTS.md** — Navigation hub with "Consuming Libraries" as top category

### CLAUDE.md Structure (Proposed Update)

```markdown
# CLAUDE.md

This file provides guidance to Claude Code when working with SwiftAcervo.

## Quick Reference
- Project: SwiftAcervo v0.7.2
- Platforms: iOS 26.0+, macOS 26.0+
- Key Components: [list as before]

## For Different Users

### 🔗 Consuming Libraries (Highest Priority)
Start here if you're integrating Acervo into your app or library:
- **[USAGE.md](USAGE.md)** — Integration guide, examples, best practices

### 📚 API Documentation  
Complete method reference and type documentation:
- **[API_REFERENCE.md](API_REFERENCE.md)** — All Acervo, AcervoManager, ComponentRegistry methods
- **[ARCHITECTURE.md](ARCHITECTURE.md)** — Ecosystem types and contracts

### 🛠️ Building and Testing
For developers working on SwiftAcervo itself:
- **[BUILD_AND_TEST.md](BUILD_AND_TEST.md)** — Make targets, acervo CLI, CI/CD

### 🌐 CDN Operations
For managing models on the CDN:
- **[CDN_ARCHITECTURE.md](CDN_ARCHITECTURE.md)** — How downloads work
- **[CDN_UPLOAD.md](CDN_UPLOAD.md)** — How to upload models to R2

### 🏗️ Architecture & Design
For understanding the system design:
- **[DESIGN_PATTERNS.md](DESIGN_PATTERNS.md)** — Core patterns (Static+Actor, streaming SHA-256, per-model locking)
- **[PROJECT_STRUCTURE.md](PROJECT_STRUCTURE.md)** — File organization
- **[SHARED_MODELS_DIRECTORY.md](SHARED_MODELS_DIRECTORY.md)** — Canonical storage location
- **[REQUIREMENTS.md](REQUIREMENTS.md)** — v2 component registry spec

## Critical Notes
- [Same as before: zero dependencies, iOS 26+, etc.]
```

---

## Expected Benefits

| Aspect | Before | After |
|--------|--------|-------|
| **Consuming library integration** | Scattered across AGENTS.md | Dedicated USAGE.md, highlighted in all entry points |
| **API discovery** | Mixed with patterns and examples | Dedicated API_REFERENCE.md |
| **Navigation** | One 393-line file | Clear hub (AGENTS/CLAUDE.md) + focused docs |
| **Build/CLI info** | Lines 350–386 of AGENTS.md | Dedicated BUILD_AND_TEST.md |
| **CDN operations** | Scattered (lines 69–98, 364–386) | CDN_ARCHITECTURE.md + CDN_UPLOAD.md |
| **Onboarding time** | "Which sections of AGENTS.md do I read?" | "Start with USAGE.md or API_REFERENCE.md" |

---

## Next Steps

1. ✅ **Approve structure** — Does this decentralization plan align with your vision?
2. 📝 **Create new documents** — Extract content from AGENTS.md
3. 🔗 **Update navigation** — Refresh CLAUDE.md and AGENTS.md as hubs
4. 🧹 **Audit for completeness** — Ensure no information is lost
5. 🚀 **Commit and communicate** — PR with documentation restructuring

---

## Notes for Claude Code

When working on SwiftAcervo going forward:
- **Consuming library question?** → Refer to USAGE.md
- **API question?** → Refer to API_REFERENCE.md
- **Architecture question?** → Refer to DESIGN_PATTERNS.md or ARCHITECTURE.md
- **Build/test question?** → Refer to BUILD_AND_TEST.md

This keeps documentation maintenance burden low and makes each doc a single source of truth for its domain.
