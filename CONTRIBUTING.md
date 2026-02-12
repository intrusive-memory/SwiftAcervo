# Contributing to SwiftAcervo

Thank you for your interest in contributing to SwiftAcervo. This document covers the development setup, testing guidelines, commit conventions, and pull request process.

## Development Setup

### Prerequisites

| Requirement | Minimum Version |
|------------|----------------|
| macOS      | 26.0+          |
| Xcode      | 26+            |
| Swift      | 6.2+           |

### Clone and Build

```bash
git clone https://github.com/intrusive-memory/SwiftAcervo.git
cd SwiftAcervo
xcodebuild build -scheme SwiftAcervo -destination 'platform=macOS'
```

### Open in Xcode

Double-click `Package.swift` or open the directory in Xcode via **File > Open**. Xcode will resolve the package automatically (there are no external dependencies).

## Testing

### Running Unit Tests

Unit tests use temporary directories and require no network access:

```bash
xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS'
```

### Running Integration Tests

Integration tests that download from HuggingFace are gated behind the `INTEGRATION_TESTS` environment variable:

```bash
INTEGRATION_TESTS=1 xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS'
```

### Test Guidelines

- All new public API methods must have corresponding unit tests.
- Unit tests must not require network access. Use temporary directories to isolate filesystem operations.
- Integration tests must be gated behind `INTEGRATION_TESTS` so they do not run in CI by default.
- Tests must pass on both macOS and iOS Simulator targets.

## Commit Conventions

Use clear, imperative-mood commit messages that describe the "why" rather than the "what":

```
Add fuzzy search with Levenshtein edit distance
Fix migration skipping models with nested config files
Update download progress to report per-file byte counts
```

### Prefixes

- **Add** -- A wholly new feature or file.
- **Update** -- An enhancement to existing functionality.
- **Fix** -- A bug fix.
- **Remove** -- Removal of code, files, or features.
- **Refactor** -- Code restructuring with no behavior change.
- **Test** -- Adding or updating tests only.
- **Docs** -- Documentation-only changes.

### Rules

- Keep the first line under 72 characters.
- Use the body for additional context when the change is non-obvious.
- Reference related issues when applicable (e.g., `Fixes #42`).

## Pull Request Process

1. **Branch from `development`.** Create a feature branch off `development`, not `main`. Use a descriptive name (e.g., `feature/fuzzy-search`, `fix/migration-nested-config`).

2. **Keep changes focused.** Each PR should address a single concern. If you find yourself changing unrelated code, split it into separate PRs.

3. **Ensure tests pass.** Before opening a PR, verify locally:
   ```bash
   xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS'
   ```

4. **Open the PR against `development`.** Provide a clear title and description. The description should explain what changed and why.

5. **CI must pass.** GitHub Actions runs tests on macOS and iOS Simulator for every PR. Both jobs must pass before merging.

6. **Review.** PRs require at least one approving review before merging.

## Code Style

- Follow Swift API Design Guidelines (https://www.swift.org/documentation/api-design-guidelines/).
- Use `///` doc comments for all public API. Include a brief description, parameter documentation, and a code example where helpful.
- Mark internal-only helpers with `internal` or `private` access control.
- Use `// MARK: -` to organize file sections.
- All closures in public API must be `@Sendable` (Swift 6 strict concurrency).
- Zero external dependencies. Do not add any third-party packages.

## Platform Requirements

SwiftAcervo targets iOS 26.0+ and macOS 26.0+ exclusively. Do not add `@available` or `#available` checks for older platform versions.

## Questions?

Open an issue on the repository if you have questions about contributing.
