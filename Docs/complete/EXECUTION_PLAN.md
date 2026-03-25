---
feature_name: "SwiftAcervo v2 — Component Registry"
iteration: 1
wave: 0
repository: SwiftAcervo
status: complete
---

# SwiftAcervo v2 — Execution Plan: Component Registry

> Evolve SwiftAcervo from filesystem-only discovery to a declarative Component Registry.
> Wave 0: foundation layer. No model-specific code. Zero external dependencies.

**Source spec**: [REQUIREMENTS.md](REQUIREMENTS.md) (sections A1--A12)
**Architecture**: [AGENTS.md](AGENTS.md)

---

## Terminology

> **Mission** — A definable, testable scope of work that decomposes into one or more sorties dispatched to autonomous agents. A mission defines the scope, acceptance criteria, and dependency structure; the sorties are attempts to accomplish the mission.

> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. A sortie has a defined objective, machine-verifiable entry/exit criteria, and bounded scope (fits within a single agent context window). The term is borrowed from military aviation: one aircraft, one mission, one return.

> **Work Unit** — A grouping of sorties (package, component, phase). This plan has a single work unit: the SwiftAcervo Component Registry.

---

## Dependency Graph

```
Sortie 0  (Recon)
    │
    ├──────────────────────┐
    v                      v
Sortie 1  (ComponentDescriptor)      Sortie 2  (Error types)     ── A1.1, A6
    │                                    │
    ├──────────────────────┐             │
    v                      │             │
Sortie 3  (ComponentRegistry) ◄─────────┘                        ── A1.2 (internal)
    │
    v
Sortie 4  (Registration API)                                     ── A1.2 (public)
    │
    ├──────────────────────┐
    v                      v
Sortie 5  (Catalog queries)   Sortie 6  (ComponentHandle)        ── A1.3, A2.1
    │                              │
    │    ┌─────────────────────────┤
    │    v                         │
    │  Sortie 7  (Integrity)       │                              ── A4
    │    │                         │
    │    ├─────────────────────────┘
    v    v
Sortie 8  (withComponentAccess)                                   ── A2.2
    │
    v
Sortie 9  (Registry-aware downloads)                              ── A3
    │
    v
Sortie 10 (Integration tests & coverage sweep)                    ── A11
```

---

## Parallelism Structure

**Critical Path**: Sortie 0 → Sortie 1 → Sortie 3 → Sortie 4 → Sortie 5 → Sortie 8 → Sortie 9 → Sortie 10 (8 sorties)

**Parallel Execution Groups**:

- **Group 0** (sequential, bootstraps everything):
  - Sortie 0 — Reconnaissance (Supervising Agent)

- **Group 1** (can run in parallel after Group 0):
  - Sortie 1 — ComponentDescriptor types (Agent 1) — NO BUILD (sub-agent)
  - Sortie 2 — Error types (Agent 2) — NO BUILD (sub-agent)

- **Group 2** (sequential after Group 1, depends on both Sortie 1 and Sortie 2):
  - Sortie 3 — ComponentRegistry (Agent 1) — NO BUILD (sub-agent)

- **Group 3** (sequential after Group 2):
  - Sortie 4 — Registration API (Agent 1) — **SUPERVISING AGENT ONLY** (has build step)

- **Group 4** (can run in parallel after Group 3):
  - Sortie 5 — Catalog queries (Agent 1) — NO BUILD (sub-agent)
  - Sortie 6 — ComponentHandle (Agent 2) — NO BUILD (sub-agent)

- **Group 5** (sequential after Group 4, depends on Sortie 5 and Sortie 6):
  - Sortie 7 — Integrity verification (Agent 1) — NO BUILD (sub-agent)

- **Group 6** (sequential after Sortie 6 and Sortie 7):
  - Sortie 8 — withComponentAccess (Agent 1) — **SUPERVISING AGENT ONLY** (has build step)

- **Group 7** (sequential after Sortie 5 and Sortie 7):
  - Sortie 9 — Registry-aware downloads (Agent 1) — **SUPERVISING AGENT ONLY** (has build step)

- **Group 8** (sequential after all):
  - Sortie 10 — Integration tests & coverage (Supervising Agent) — **SUPERVISING AGENT ONLY** (has build + test steps)

**Agent Constraints**:
- **Supervising agent**: Handles all sorties with build/compile/test steps (Sorties 0, 4, 8, 9, 10)
- **Sub-agents (up to 2)**: Handle code creation without build steps (Sorties 1, 2, 3, 5, 6, 7)

---

## Sortie 0: Reconnaissance

**Priority**: 25.0 — Foundational; blocks every other sortie. Must run first.

**Objective**: Confirm what exists, identify every file to create or modify, and validate assumptions before writing code.

**Model**: sonnet (moderate complexity, high read volume, judgement calls on insertion points)

**Entry Criteria**:
- Repository is cloned at `/Users/stovak/Projects/SwiftAcervo/`
- No prior v2 work has been started

**Tasks**:
- Read all existing source files in `Sources/SwiftAcervo/` (8 files) and all test files in `Tests/SwiftAcervoTests/` (16 files)
- Verify `Package.swift` is Swift 6.2, platforms macOS 26 / iOS 26, zero dependencies
- Confirm the v1 public API surface (all `Acervo` static methods, `AcervoManager` actor methods, `AcervoModel`, `AcervoError`, `AcervoDownloadProgress`) matches AGENTS.md
- Confirm the build compiles and all existing tests pass
- Map the exact insertion points for v2 additions (which MARK sections in `Acervo.swift` and `AcervoManager.swift` to extend, which new files to create)

**Files to create (v2)**:
| New file | Purpose |
|----------|---------|
| `Sources/SwiftAcervo/ComponentDescriptor.swift` | `ComponentDescriptor`, `ComponentType`, `ComponentFile` |
| `Sources/SwiftAcervo/ComponentRegistry.swift` | Internal thread-safe in-memory registry |
| `Sources/SwiftAcervo/ComponentHandle.swift` | Opaque scoped access handle |
| `Sources/SwiftAcervo/IntegrityVerification.swift` | SHA-256 checksum verification helper |
| `Tests/SwiftAcervoTests/ComponentDescriptorTests.swift` | Type tests |
| `Tests/SwiftAcervoTests/ComponentRegistryTests.swift` | Registry unit tests |
| `Tests/SwiftAcervoTests/ComponentHandleTests.swift` | Handle unit tests |
| `Tests/SwiftAcervoTests/ComponentAccessTests.swift` | `withComponentAccess` tests |
| `Tests/SwiftAcervoTests/ComponentDownloadTests.swift` | Registry-aware download tests |
| `Tests/SwiftAcervoTests/IntegrityVerificationTests.swift` | SHA-256 tests |
| `Tests/SwiftAcervoTests/ComponentIntegrationTests.swift` | Full lifecycle tests |

**Files to modify (v2)**:
| Existing file | Change |
|---------------|--------|
| `Sources/SwiftAcervo/AcervoError.swift` | Add 4 new error cases |
| `Sources/SwiftAcervo/Acervo.swift` | Add registry, catalog, download, integrity, and deletion static methods |
| `Sources/SwiftAcervo/AcervoManager.swift` | Add `withComponentAccess` method |
| `Tests/SwiftAcervoTests/AcervoErrorTests.swift` | Extend to cover new error cases |

**Dependencies**: None (first sortie).

**Estimated Turns**: 35 (R=24, C=0, M=0, B=2, L=0, V=4)

**Exit Criteria**:
- [ ] Build succeeds: `xcodebuild build -scheme SwiftAcervo -destination 'platform=macOS'` exits with code 0
- [ ] All existing tests pass: `xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS'` exits with code 0
- [ ] File-level plan validated: `grep -r 'ComponentDescriptor\|ComponentRegistry\|ComponentHandle' Sources/` returns zero matches (no v2 types exist yet)
- [ ] No v2 test files exist: `ls Tests/SwiftAcervoTests/Component*.swift 2>/dev/null` returns nothing

---

## Sortie 1: ComponentDescriptor Types (A1.1)

**Priority**: 22.0 — Foundation types; 6 downstream sorties depend transitively on these types.

**Objective**: Define the three pure value types that describe downloadable components. These are data-only structs with no logic, no side effects, and no dependencies on other v2 code.

**Model**: haiku (well-specified, mechanical type definitions and tests, no ambiguity)

**Entry Criteria**:
- Sortie 0 complete (build passes, no v2 files exist)
- `Sources/SwiftAcervo/ComponentDescriptor.swift` does not exist
- `Tests/SwiftAcervoTests/ComponentDescriptorTests.swift` does not exist

**Files**:
- **Create**: `Sources/SwiftAcervo/ComponentDescriptor.swift`
- **Create**: `Tests/SwiftAcervoTests/ComponentDescriptorTests.swift`

**Implementation**:

1. **`ComponentType` enum** (~15 lines)
   - `public enum ComponentType: String, Sendable, CaseIterable, Codable`
   - Cases: `.encoder`, `.backbone`, `.decoder`, `.scheduler`, `.tokenizer`, `.auxiliary`, `.languageModel`
   - Raw values are lowercase strings matching the case names

2. **`ComponentFile` struct** (~15 lines)
   - `public struct ComponentFile: Sendable, Equatable`
   - Properties: `relativePath: String`, `expectedSizeBytes: Int64?`, `sha256: String?`
   - Public memberwise initializer

3. **`ComponentDescriptor` struct** (~25 lines)
   - `public struct ComponentDescriptor: Sendable, Identifiable, Equatable`
   - Properties per spec: `id`, `type`, `displayName`, `huggingFaceRepo`, `files: [ComponentFile]`, `estimatedSizeBytes`, `minimumMemoryBytes`, `metadata: [String: String]`
   - Public memberwise initializer
   - `Equatable` conformance compares by `id` only (deduplication semantics per REQUIREMENTS A1.2)

4. **Tests** (~80 lines)
   - `ComponentType.allCases.count == 7`
   - `ComponentType` raw values round-trip through `RawRepresentable`
   - `ComponentFile` equality by all three properties
   - `ComponentDescriptor` equality by `id` only (two descriptors with same `id` but different `displayName` are equal)
   - `ComponentDescriptor.id` conforms to `Identifiable`
   - Metadata dictionary is preserved as-is

**Dependencies**: Sortie 0 (reconnaissance confirms clean state).

**Estimated Turns**: 20 (R=2, C=4, M=0, B=1, L=2, V=6)

**Exit Criteria**:
- [ ] `Sources/SwiftAcervo/ComponentDescriptor.swift` exists and contains `ComponentType`, `ComponentFile`, `ComponentDescriptor`
- [ ] `ComponentType.allCases.count` equals 7 (verified by test)
- [ ] `ComponentType` conforms to `String, Sendable, CaseIterable, Codable`
- [ ] `ComponentFile` conforms to `Sendable, Equatable` and has properties `relativePath`, `expectedSizeBytes`, `sha256`
- [ ] `ComponentDescriptor` conforms to `Sendable, Identifiable, Equatable` and has all 8 properties per REQUIREMENTS A1.1
- [ ] `ComponentDescriptor` equality compares by `id` only (test: two descriptors with same id, different displayName, are `==`)
- [ ] All tests in `ComponentDescriptorTests.swift` pass: `xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS' -only-testing:SwiftAcervoTests/ComponentDescriptorTests`
- [ ] Build succeeds with zero warnings on new file: `xcodebuild build -scheme SwiftAcervo -destination 'platform=macOS'`

---

## Sortie 2: Error Types (A6)

**Priority**: 18.0 — Independent of Sortie 1; enables Sorties 3, 6, 7, 8, 9. Low complexity, high dependency count.

**Objective**: Extend `AcervoError` with the four new error cases required by the component registry.

**Model**: haiku (mechanical additions to existing enum, well-specified)

**Entry Criteria**:
- Sortie 0 complete
- `Sources/SwiftAcervo/AcervoError.swift` exists and contains exactly 7 error cases
- `Tests/SwiftAcervoTests/AcervoErrorTests.swift` exists

**Files**:
- **Modify**: `Sources/SwiftAcervo/AcervoError.swift`
- **Modify**: `Tests/SwiftAcervoTests/AcervoErrorTests.swift`

**Implementation**:

1. **New error cases** (~20 lines added to enum)
   - `case componentNotRegistered(String)` -- component ID not in registry
   - `case componentNotDownloaded(String)` -- registered but files missing
   - `case integrityCheckFailed(file: String, expected: String, actual: String)` -- SHA-256 mismatch
   - `case componentFileNotFound(component: String, file: String)` -- specific file missing from component

2. **`errorDescription` additions** (~16 lines added to switch)
   - Each new case returns a descriptive message including all associated values

3. **Test updates** (~30 lines added)
   - Each new error case has a dedicated test verifying `errorDescription` is non-nil, non-empty, and contains the associated values
   - `componentNotRegistered("foo")` description contains `"foo"`
   - `integrityCheckFailed(file: "model.safetensors", expected: "abc", actual: "xyz")` description contains all three values
   - `componentFileNotFound(component: "comp-1", file: "weights.bin")` description contains both values

**Dependencies**: Sortie 0 only (modifies existing file, no dependency on new v2 types).

**Estimated Turns**: 18 (R=2, C=0, M=4, B=1, L=1, V=5)

**Exit Criteria**:
- [ ] `AcervoError` has exactly 11 cases: `grep 'case ' Sources/SwiftAcervo/AcervoError.swift | wc -l` equals 11
- [ ] All 4 new cases have non-nil `errorDescription`: verified by `XCTAssertNotNil` in tests
- [ ] `componentNotRegistered("test-id").errorDescription!.contains("test-id")` is true
- [ ] `integrityCheckFailed(file: "f", expected: "e", actual: "a").errorDescription!` contains all three values
- [ ] `componentFileNotFound(component: "c", file: "f").errorDescription!` contains both values
- [ ] All existing error tests still pass (no regressions): `xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS' -only-testing:SwiftAcervoTests/AcervoErrorTests`
- [ ] Build succeeds with zero warnings

---

## Sortie 3: ComponentRegistry (A1.2 internal)

**Priority**: 21.0 — Core data structure; 7 downstream sorties depend on it. Highest foundation score.

**Objective**: Build the internal, thread-safe, in-memory registry that stores `ComponentDescriptor` entries. This is the backing store for all registry operations. Not publicly exposed -- only `Acervo` static methods touch it.

**Model**: sonnet (thread-safety requires careful design, deduplication logic has edge cases)

**Entry Criteria**:
- Sortie 1 complete (`ComponentDescriptor.swift` exists and builds)
- Sortie 2 complete (error types available for conflict warnings)
- `Sources/SwiftAcervo/ComponentRegistry.swift` does not exist

**Files**:
- **Create**: `Sources/SwiftAcervo/ComponentRegistry.swift`
- **Create**: `Tests/SwiftAcervoTests/ComponentRegistryTests.swift`

**Implementation**:

1. **`ComponentRegistry` class** (~100 lines)
   - `final class ComponentRegistry: @unchecked Sendable` (internal, not public)
   - Private storage: `private var descriptors: [String: ComponentDescriptor]` (keyed by `id`)
   - Thread safety: `private let lock = NSLock()`
   - Singleton: `static let shared = ComponentRegistry()`
   - Methods:
     - `func register(_ descriptor: ComponentDescriptor)` -- deduplication per REQUIREMENTS A1.2 rules:
       - Same `id`, same `huggingFaceRepo` and `files` -> silent overwrite
       - Same `id`, different `huggingFaceRepo` or `files` -> log warning via `print` to stderr, last wins
       - Merge `metadata` (newer keys overwrite on conflict)
       - `estimatedSizeBytes` and `minimumMemoryBytes` take `max` of both values
     - `func register(_ descriptors: [ComponentDescriptor])`
     - `func unregister(_ componentId: String)`
     - `func component(_ id: String) -> ComponentDescriptor?`
     - `func allComponents() -> [ComponentDescriptor]`
     - `func components(ofType type: ComponentType) -> [ComponentDescriptor]`
     - `func removeAll()` (for testing)

2. **Tests** (~120 lines)
   - Register a descriptor -> `component(_:)` returns it
   - Register same ID twice with identical repo/files -> silent dedup, `allComponents().count == 1`
   - Register same ID with different repo -> last wins, `component(_:)!.huggingFaceRepo` matches second registration
   - Metadata merge: first registers `["a": "1"]`, second registers `["b": "2"]` -> merged result has both keys
   - `estimatedSizeBytes` takes max: first registers 100, second registers 200 -> result is 200
   - Unregister -> `component(_:)` returns nil
   - `allComponents()` returns all registered (register 3, get 3 back)
   - `components(ofType: .encoder)` returns correct subset (register 2 encoders + 1 decoder, filter returns 2)
   - `removeAll()` empties the registry: `allComponents().isEmpty` is true
   - Thread safety: concurrent register/unregister from 100 tasks via `TaskGroup` does not crash

**Dependencies**: Sortie 1 (needs `ComponentDescriptor`, `ComponentType`, `ComponentFile`), Sortie 2 (warning for dedup conflicts).

**Estimated Turns**: 21 (R=2, C=4, M=0, B=1, L=3, V=6)

**Exit Criteria**:
- [ ] `ComponentRegistry` access level is `internal`: `grep 'public.*ComponentRegistry' Sources/SwiftAcervo/ComponentRegistry.swift` returns zero matches
- [ ] Register + query round-trip works (test: register, then `component(_:)` returns same descriptor)
- [ ] Deduplication: same ID + same repo = one entry (test: `allComponents().count == 1` after two identical registrations)
- [ ] Deduplication: same ID + different repo = last wins (test: verify `huggingFaceRepo` matches second registration)
- [ ] Metadata merge works (test: merged dictionary has keys from both registrations)
- [ ] `estimatedSizeBytes` takes max (test: max of 100 and 200 is 200)
- [ ] Unregister removes entry (test: `component(_:)` returns nil after unregister)
- [ ] `removeAll()` empties registry (test: `allComponents().isEmpty`)
- [ ] Thread safety: 100 concurrent operations via `TaskGroup` completes without crash
- [ ] All tests pass: `xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS' -only-testing:SwiftAcervoTests/ComponentRegistryTests`

---

## Sortie 4: Registration API on Acervo (A1.2 public surface)

**Priority**: 19.5 — Gateway; all downstream public API depends on this.

**Objective**: Wire the public `Acervo` static methods for component registration to the internal `ComponentRegistry`. These are the methods model plugins call to declare their components.

**Model**: haiku (trivial delegation, 3 methods, ~20 lines)

**Entry Criteria**:
- Sortie 3 complete (`ComponentRegistry.swift` exists, builds, tests pass)
- Sortie 1 complete (`ComponentDescriptor.swift` exists)
- `Acervo.swift` does not contain a `// MARK: - Component Registration` section

**Files**:
- **Modify**: `Sources/SwiftAcervo/Acervo.swift` (add a new `// MARK: - Component Registration` section)

**Implementation**:

1. **Static registration methods** (~20 lines)
   ```swift
   extension Acervo {
       public static func register(_ descriptor: ComponentDescriptor)
       public static func register(_ descriptors: [ComponentDescriptor])
       public static func unregister(_ componentId: String)
   }
   ```
   - Each delegates directly to `ComponentRegistry.shared`

2. **No new test file** -- registration is tested indirectly through Sortie 5 (catalog queries) which exercises the full register-then-query path via the public API.

**Dependencies**: Sortie 3 (needs `ComponentRegistry`), Sortie 1 (needs `ComponentDescriptor`).

**Estimated Turns**: 15 (R=1, C=0, M=2, B=1, L=1, V=5)

**Exit Criteria**:
- [ ] `Acervo.register(_:)` (single) exists and is public: `grep 'public static func register.*ComponentDescriptor)' Sources/SwiftAcervo/Acervo.swift` returns a match
- [ ] `Acervo.register(_:)` (array) exists and is public: `grep 'public static func register.*\[ComponentDescriptor\]' Sources/SwiftAcervo/Acervo.swift` returns a match
- [ ] `Acervo.unregister(_:)` exists and is public: `grep 'public static func unregister' Sources/SwiftAcervo/Acervo.swift` returns a match
- [ ] Build succeeds: `xcodebuild build -scheme SwiftAcervo -destination 'platform=macOS'` exits with code 0
- [ ] All existing tests pass: `xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS'` exits with code 0

---

## Sortie 5: Catalog Query API (A1.3)

**Priority**: 17.5 — Enables Sortie 9 (downloads) and Sortie 10 (integration). Core user-facing API.

**Objective**: Implement the "what exists in the world?" query API. These methods let consumers inspect the registry and determine download status.

**Model**: sonnet (filesystem interaction for `isComponentReady`, multiple methods with testability overloads)

**Entry Criteria**:
- Sortie 4 complete (`Acervo.register` exists and builds)
- `Acervo.swift` does not contain a `// MARK: - Component Catalog` section
- `Tests/SwiftAcervoTests/ComponentCatalogTests.swift` does not exist

**Files**:
- **Modify**: `Sources/SwiftAcervo/Acervo.swift` (add `// MARK: - Component Catalog` section)
- **Create**: `Tests/SwiftAcervoTests/ComponentCatalogTests.swift`

**Implementation**:

1. **Catalog query methods** (~60 lines)
   ```swift
   extension Acervo {
       public static func registeredComponents() -> [ComponentDescriptor]
       public static func registeredComponents(ofType type: ComponentType) -> [ComponentDescriptor]
       public static func component(_ id: String) -> ComponentDescriptor?
       public static func isComponentReady(_ id: String) -> Bool
       public static func pendingComponents() -> [ComponentDescriptor]
       public static func totalCatalogSize() -> (downloaded: Int64, pending: Int64)
   }
   ```

2. **`isComponentReady` logic** (~20 lines)
   - Look up descriptor in registry; return `false` if not found
   - For each `ComponentFile` in the descriptor:
     - Compute the expected path: `sharedModelsDirectory / slugify(descriptor.huggingFaceRepo) / file.relativePath`
     - Check file exists on disk
     - If `expectedSizeBytes` is non-nil, check actual file size matches
   - Return `true` only if ALL files pass

3. **`pendingComponents` logic** (~5 lines)
   - Filter `registeredComponents()` where `!isComponentReady(descriptor.id)`

4. **`totalCatalogSize` logic** (~15 lines)
   - Sum `estimatedSizeBytes` for ready components (downloaded) and not-ready components (pending)

5. **Internal overloads** for testability (~30 lines)
   - `isComponentReady(_:in:)` accepting a base directory
   - `pendingComponents(in:)` accepting a base directory

6. **Tests** (~100 lines)
   - `registeredComponents()` returns empty array when nothing registered
   - Register 3 descriptors -> `registeredComponents().count == 3`
   - `registeredComponents(ofType: .encoder)` returns correct subset (2 encoders registered, 1 decoder -> filter returns 2)
   - `component("known-id")` returns the descriptor; `component("known-id")!.id == "known-id"`
   - `component("unknown-id")` returns nil
   - `isComponentReady` returns `false` for registered-but-not-downloaded component (no files on disk)
   - `isComponentReady` returns `true` after creating all expected files in temp directory with correct sizes
   - `pendingComponents()` returns only undownloaded (register 2, create files for 1 -> pending has 1 entry)
   - `totalCatalogSize()` sums correctly: ready component with 100 bytes + pending with 200 bytes = `(downloaded: 100, pending: 200)`

**Dependencies**: Sortie 4 (needs registration API on Acervo), Sortie 1 (needs types).

**Estimated Turns**: 22 (R=2, C=2, M=2, B=1, L=4, V=6)

**Exit Criteria**:
- [ ] All 6 catalog query methods exist and are public on `Acervo`
- [ ] `isComponentReady` returns `false` when files do not exist on disk (test with temp directory)
- [ ] `isComponentReady` returns `true` when all files exist with correct sizes (test with temp directory)
- [ ] `pendingComponents` returns only components where `isComponentReady` is false
- [ ] `totalCatalogSize` returns correct `(downloaded: Int64, pending: Int64)` tuple
- [ ] All tests pass: `xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS' -only-testing:SwiftAcervoTests/ComponentCatalogTests`
- [ ] Tests use temp directories exclusively, never `~/Library/SharedModels/`
- [ ] No v1 test regressions

---

## Sortie 6: ComponentHandle (A2.1)

**Priority**: 16.0 — Enables Sortie 8 (withComponentAccess). Core abstraction type.

**Objective**: Implement the opaque handle that provides scoped file access to a component's files without exposing filesystem paths to consumers.

**Model**: sonnet (filesystem interaction, error handling, suffix matching logic)

**Entry Criteria**:
- Sortie 1 complete (`ComponentDescriptor`, `ComponentFile` available)
- Sortie 2 complete (`componentFileNotFound` error case available)
- `Sources/SwiftAcervo/ComponentHandle.swift` does not exist

**Files**:
- **Create**: `Sources/SwiftAcervo/ComponentHandle.swift`
- **Create**: `Tests/SwiftAcervoTests/ComponentHandleTests.swift`

**Implementation**:

1. **`ComponentHandle` struct** (~60 lines)
   ```swift
   public struct ComponentHandle: Sendable {
       public let descriptor: ComponentDescriptor
       // Internal: the resolved base directory for this component
       let baseDirectory: URL

       public func url(for relativePath: String) throws -> URL
       public func url(matching suffix: String) throws -> URL
       public func urls(matching suffix: String) throws -> [URL]
       public func availableFiles() -> [String]
   }
   ```
   - `url(for:)`: resolve `baseDirectory / relativePath`, throw `componentFileNotFound` if not on disk
   - `url(matching:)`: find first file in `descriptor.files` whose `relativePath` ends with `suffix`, then call `url(for:)`. Throw `componentFileNotFound` if no match.
   - `urls(matching:)`: find ALL files whose `relativePath` ends with `suffix`, resolve each. Throw `componentFileNotFound` if none match.
   - `availableFiles()`: return `descriptor.files.map(\.relativePath)` filtered to those that exist on disk
   - Initializer is `internal` (consumers never construct handles directly)

2. **Tests** (~80 lines)
   - Create a temp directory with known files (`model.safetensors`, `config.json`, `model-00001-of-00003.safetensors`, `model-00002-of-00003.safetensors`, `model-00003-of-00003.safetensors`), construct a handle, verify:
     - `url(for: "model.safetensors")` returns URL ending with `model.safetensors` and file exists at that URL
     - `url(for: "nonexistent.txt")` throws `AcervoError.componentFileNotFound`
     - `url(matching: ".safetensors")` returns a URL ending with `.safetensors`
     - `url(matching: ".xyz")` throws `AcervoError.componentFileNotFound`
     - `urls(matching: ".safetensors")` returns 4 URLs (all safetensors files)
     - `availableFiles()` returns exactly the files that exist on disk

**Dependencies**: Sortie 1 (needs `ComponentDescriptor`, `ComponentFile`), Sortie 2 (needs `componentFileNotFound` error).

**Estimated Turns**: 20 (R=2, C=4, M=0, B=1, L=2, V=6)

**Exit Criteria**:
- [ ] `ComponentHandle` is `public`: `grep 'public struct ComponentHandle' Sources/SwiftAcervo/ComponentHandle.swift` returns a match
- [ ] `ComponentHandle.init` is NOT public: `grep 'public init' Sources/SwiftAcervo/ComponentHandle.swift` returns zero matches
- [ ] `url(for:)` resolves paths correctly and throws `componentFileNotFound` on missing files
- [ ] `url(matching:)` finds by suffix and throws `componentFileNotFound` on no match
- [ ] `urls(matching: ".safetensors")` returns all 4 matching files (sharded weight support test)
- [ ] `availableFiles()` returns only files present on disk (not files in descriptor but missing from disk)
- [ ] All tests pass using temp directories: `xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS' -only-testing:SwiftAcervoTests/ComponentHandleTests`

---

## Sortie 7: Integrity Verification (A4)

**Priority**: 15.5 — Enables Sortie 8 (withComponentAccess) and Sortie 9 (downloads). Uses CryptoKit.

**Objective**: Implement SHA-256 checksum verification for component files. This is used both post-download and pre-access.

**Model**: sonnet (CryptoKit framework choice, public API design, error handling)

**Entry Criteria**:
- Sortie 1 complete (`ComponentFile`, `ComponentDescriptor` available)
- Sortie 3 complete (`ComponentRegistry` available for `verifyComponent`)
- Sortie 2 complete (`integrityCheckFailed`, `componentNotRegistered`, `componentNotDownloaded` errors available)
- Sortie 4 complete (registration API available for test setup)
- `Sources/SwiftAcervo/IntegrityVerification.swift` does not exist

**Files**:
- **Create**: `Sources/SwiftAcervo/IntegrityVerification.swift` (internal helper)
- **Modify**: `Sources/SwiftAcervo/Acervo.swift` (add `// MARK: - Integrity Verification` section)
- **Create**: `Tests/SwiftAcervoTests/IntegrityVerificationTests.swift`

**Implementation**:

1. **Internal SHA-256 helper** (~40 lines)
   - `struct IntegrityVerification: Sendable` (internal)
   - `static func sha256(of fileURL: URL) throws -> String` -- reads file data, computes SHA-256 using `CryptoKit.SHA256`
   - **Decision**: Use `CryptoKit` (not `CommonCrypto`). `CryptoKit` is a system framework shipping on macOS 26 / iOS 26 (the project's minimum targets). It is NOT an external dependency. AGENTS.md says "zero external dependencies" meaning no SPM/CocoaPods packages; system frameworks are fine.
   - Returns lowercase hex string
   - `import CryptoKit` at top of file

2. **File-level verification** (~20 lines)
   - `static func verify(file: ComponentFile, in directory: URL) throws -> Bool`
   - If `sha256` is nil, return `true` (skip)
   - Compute actual hash, compare to expected
   - Return `true` on match, `false` on mismatch

3. **Public verification API on Acervo** (~50 lines)
   ```swift
   extension Acervo {
       public static func verifyComponent(_ componentId: String) throws -> Bool
       public static func verifyAllComponents() throws -> [String]
   }
   ```
   - `verifyComponent`: look up descriptor in `ComponentRegistry.shared`, check all files, return `false` if any checksum fails. Throw `componentNotRegistered` if ID not found. Throw `componentNotDownloaded` if files missing.
   - `verifyAllComponents`: iterate registered components that are downloaded, return IDs of failures. Skip not-downloaded components.
   - Internal overloads accepting `baseDirectory` for testability

4. **Tests** (~80 lines)
   - Write `"Hello, world!"` to temp file, compute SHA-256, verify equals known hash `"315f5bdb76d078c43b8ac0064e4a0164612b1fce77c869345bfc94c75894edd3"`
   - Modify file content to `"Hello, world!!"`, verify SHA-256 differs from expected
   - `IntegrityVerification.verify(file:in:)` with nil checksum returns `true`
   - `IntegrityVerification.verify(file:in:)` with correct checksum returns `true`
   - `IntegrityVerification.verify(file:in:)` with wrong checksum returns `false`
   - `Acervo.verifyComponent` on a valid component with correct files -> returns `true`
   - `Acervo.verifyComponent` on a component with one corrupted file -> returns `false`
   - `Acervo.verifyComponent` on unregistered component -> throws `componentNotRegistered`
   - `Acervo.verifyComponent` on registered but not-downloaded component -> throws `componentNotDownloaded`
   - `Acervo.verifyAllComponents` returns empty array when all pass
   - `Acervo.verifyAllComponents` returns IDs of failures only

**Dependencies**: Sortie 1 (needs types), Sortie 3 (needs `ComponentRegistry`), Sortie 2 (needs error types), Sortie 4 (needs registration API for test setup).

**Estimated Turns**: 25 (R=3, C=4, M=2, B=1, L=3, V=7)

**Exit Criteria**:
- [ ] `IntegrityVerification` is internal: `grep 'public.*IntegrityVerification' Sources/SwiftAcervo/IntegrityVerification.swift` returns zero matches
- [ ] SHA-256 of `"Hello, world!"` equals `"315f5bdb76d078c43b8ac0064e4a0164612b1fce77c869345bfc94c75894edd3"` (test)
- [ ] File with correct checksum passes `verify(file:in:)` (returns `true`)
- [ ] File with wrong checksum fails `verify(file:in:)` (returns `false`)
- [ ] File with nil checksum skips verification (returns `true`)
- [ ] `Acervo.verifyComponent("unregistered")` throws `AcervoError.componentNotRegistered`
- [ ] `Acervo.verifyComponent("registered-not-downloaded")` throws `AcervoError.componentNotDownloaded`
- [ ] `Acervo.verifyAllComponents()` returns empty array when all components pass
- [ ] All tests pass: `xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS' -only-testing:SwiftAcervoTests/IntegrityVerificationTests`
- [ ] `import CryptoKit` present in `IntegrityVerification.swift`
- [ ] No v1 regressions

---

## Sortie 8: withComponentAccess on AcervoManager (A2.2)

**Priority**: 14.0 — Primary consumer API. Integrates handle + integrity + registry. Complex coordination.

**Objective**: Add the scoped, exclusive-access method to `AcervoManager` that provides a `ComponentHandle` for loading component files. This is the primary consumer API for abstracted model access.

**Model**: opus (complex integration of 4 subsystems, concurrency/locking, critical correctness)

**Entry Criteria**:
- Sortie 6 complete (`ComponentHandle.swift` exists and builds)
- Sortie 7 complete (`IntegrityVerification.swift` exists and builds)
- Sortie 3 complete (`ComponentRegistry` available)
- Sortie 2 complete (error types available)
- `AcervoManager.swift` does not contain `withComponentAccess`

**Files**:
- **Modify**: `Sources/SwiftAcervo/AcervoManager.swift` (add `// MARK: - Component Access` section)
- **Create**: `Tests/SwiftAcervoTests/ComponentAccessTests.swift`

**Implementation**:

1. **`withComponentAccess` method** (~40 lines)
   ```swift
   extension AcervoManager {
       public func withComponentAccess<T: Sendable>(
           _ componentId: String,
           perform: @Sendable (ComponentHandle) throws -> T
       ) async throws -> T
   }
   ```
   - Look up descriptor in `ComponentRegistry.shared`; throw `componentNotRegistered` if not found
   - Check component is downloaded (all files present); throw `componentNotDownloaded` if not
   - Verify integrity (all files with checksums); throw `integrityCheckFailed` if any fail
   - Acquire per-component lock (reuse existing `acquireLock`/`releaseLock` pattern with component ID)
   - Construct `ComponentHandle` with `descriptor` and resolved `baseDirectory`
   - Call `perform(handle)`, release lock in `defer`
   - Track access statistics (reuse `trackAccess`)

2. **Tests** (~100 lines)
   - Setup: register a component, create its files in temp directory
   - `withComponentAccess` for a downloaded, registered component -> handle provides valid URLs; `handle.url(for: "config.json")` does not throw
   - `withComponentAccess` for an unregistered component -> throws `AcervoError.componentNotRegistered`
   - `withComponentAccess` for a registered-but-not-downloaded component -> throws `AcervoError.componentNotDownloaded`
   - Handle's `url(for:)` works within the closure: returned URL path contains expected filename
   - Handle's `url(matching: ".json")` works within the closure
   - Concurrent `withComponentAccess` for the SAME component -> serialized (second call starts after first completes; verify via ordered result array)
   - Concurrent `withComponentAccess` for DIFFERENT components -> both complete (verify both results are non-nil)
   - Integrity check failure during access -> throws `AcervoError.integrityCheckFailed` before closure runs (verify closure was NOT invoked by checking a flag)

**Dependencies**: Sortie 6 (needs `ComponentHandle`), Sortie 7 (needs integrity verification), Sortie 3 (needs `ComponentRegistry`), Sortie 2 (needs error types).

**Estimated Turns**: 23 (R=3, C=2, M=2, B=1, L=2, V=8)

**Exit Criteria**:
- [ ] `AcervoManager` has `withComponentAccess` method: `grep 'func withComponentAccess' Sources/SwiftAcervo/AcervoManager.swift` returns a match
- [ ] Method is `public`: `grep 'public func withComponentAccess' Sources/SwiftAcervo/AcervoManager.swift` returns a match
- [ ] Throws `componentNotRegistered` for unknown IDs (test)
- [ ] Throws `componentNotDownloaded` for registered-but-missing components (test)
- [ ] Throws `integrityCheckFailed` for corrupted files; closure is NOT invoked (test with flag check)
- [ ] Handle provides valid URLs within closure (test)
- [ ] Same-component access is serialized (test with ordered results)
- [ ] Different-component access is concurrent (test with parallel tasks)
- [ ] All tests pass: `xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS' -only-testing:SwiftAcervoTests/ComponentAccessTests`
- [ ] Existing `AcervoManagerTests` still pass: `xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS' -only-testing:SwiftAcervoTests/AcervoManagerTests`

---

## Sortie 9: Registry-Aware Downloads (A3)

**Priority**: 12.0 — Key usability feature. Integrates registry + downloads + integrity.

**Objective**: Implement download methods that leverage the registry instead of requiring callers to specify file lists, plus component deletion. This is the key usability improvement: callers say "download component X" and Acervo knows what files to fetch.

**Model**: sonnet (integrates existing download infrastructure, error handling, deletion logic)

**Entry Criteria**:
- Sortie 5 complete (`isComponentReady`, catalog queries available)
- Sortie 7 complete (integrity verification available)
- Sortie 2 complete (error types available)
- `Acervo.swift` does not contain `// MARK: - Component Downloads`
- `Tests/SwiftAcervoTests/ComponentDownloadTests.swift` does not exist

**Files**:
- **Modify**: `Sources/SwiftAcervo/Acervo.swift` (add `// MARK: - Component Downloads` and `// MARK: - Component Deletion` sections)
- **Create**: `Tests/SwiftAcervoTests/ComponentDownloadTests.swift`

**Implementation**:

1. **Component download methods** (~60 lines)
   ```swift
   extension Acervo {
       public static func downloadComponent(
           _ componentId: String,
           token: String? = nil,
           force: Bool = false,
           progress: @Sendable (AcervoDownloadProgress) -> Void = { _ in }
       ) async throws

       public static func ensureComponentReady(
           _ componentId: String,
           token: String? = nil,
           progress: @Sendable (AcervoDownloadProgress) -> Void = { _ in }
       ) async throws

       public static func ensureComponentsReady(
           _ componentIds: [String],
           token: String? = nil,
           progress: @Sendable (AcervoDownloadProgress) -> Void = { _ in }
       ) async throws
   }
   ```

2. **`downloadComponent` logic** (~30 lines)
   - Look up descriptor in `ComponentRegistry.shared`; throw `componentNotRegistered` if not found
   - Delegate to existing `Acervo.download(descriptor.huggingFaceRepo, files: descriptor.files.map(\.relativePath), ...)`
   - After download: verify integrity for files with checksums
   - On integrity failure: delete the bad file, throw `integrityCheckFailed`

3. **`ensureComponentReady` logic** (~15 lines)
   - If `isComponentReady(componentId)` is true, return immediately
   - Otherwise call `downloadComponent`

4. **`ensureComponentsReady` logic** (~10 lines)
   - Iterate `componentIds`, call `ensureComponentReady` for each
   - Sequential for v2 wave 0

5. **Component deletion** (~20 lines)
   ```swift
   extension Acervo {
       public static func deleteComponent(_ componentId: String) throws
   }
   ```
   - Look up descriptor; throw `componentNotRegistered` if not found
   - If not downloaded, no-op (no error)
   - If downloaded, delete the model directory (delegate to existing `deleteModel` with repo ID)
   - Does NOT unregister the component

6. **Internal overloads** for testability (accept `baseDirectory`)

7. **Tests** (~80 lines, no network calls per REQUIREMENTS A11.3)
   - `downloadComponent("unregistered-id")` throws `AcervoError.componentNotRegistered`
   - `ensureComponentReady` when files already exist on disk -> returns without error (verify via checking no download attempt; use internal testable overload with temp directory)
   - `deleteComponent` for registered + downloaded -> files removed from temp directory; component still in registry (`Acervo.component(id)` is non-nil)
   - `deleteComponent` for registered + not downloaded -> no error, no-op
   - `deleteComponent("unregistered-id")` throws `AcervoError.componentNotRegistered`
   - `deleteComponent` preserves registration: after delete, `Acervo.component(id)` still returns descriptor

**Dependencies**: Sortie 5 (needs `isComponentReady`, catalog queries), Sortie 7 (needs integrity verification), Sortie 2 (needs error types).

**Estimated Turns**: 23 (R=3, C=2, M=2, B=1, L=3, V=7)

**Exit Criteria**:
- [ ] `Acervo.downloadComponent` is public: `grep 'public static func downloadComponent' Sources/SwiftAcervo/Acervo.swift` returns a match
- [ ] `Acervo.ensureComponentReady` is public: `grep 'public static func ensureComponentReady' Sources/SwiftAcervo/Acervo.swift` returns a match
- [ ] `Acervo.ensureComponentsReady` is public: `grep 'public static func ensureComponentsReady' Sources/SwiftAcervo/Acervo.swift` returns a match
- [ ] `Acervo.deleteComponent` is public: `grep 'public static func deleteComponent' Sources/SwiftAcervo/Acervo.swift` returns a match
- [ ] `downloadComponent` throws `componentNotRegistered` for unknown IDs (test)
- [ ] `deleteComponent` removes files but preserves registration (test: component still in registry after delete)
- [ ] `deleteComponent` for not-downloaded is a no-op (test: no error thrown)
- [ ] All tests pass: `xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS' -only-testing:SwiftAcervoTests/ComponentDownloadTests`
- [ ] No network calls in tests (no URLSession usage in test file)
- [ ] No v1 regressions

---

## Sortie 10: Integration Tests & Coverage Sweep (A11)

**Priority**: 8.0 — Final verification. Depends on all previous sorties.

**Objective**: Add full lifecycle integration tests and sweep all new code for >= 90% line coverage. Verify backward compatibility with v1 API.

**Model**: opus (broad judgment required, coverage analysis, backward compatibility verification)

**Entry Criteria**:
- All sorties 1--9 complete and their individual tests passing
- Full build succeeds: `xcodebuild build -scheme SwiftAcervo -destination 'platform=macOS'`
- `Tests/SwiftAcervoTests/ComponentIntegrationTests.swift` does not exist

**Files**:
- **Create**: `Tests/SwiftAcervoTests/ComponentIntegrationTests.swift`
- **Modify**: Various test files as needed (add edge case tests for coverage gaps)

**Implementation**:

1. **Full lifecycle integration tests** (~100 lines, all using temp directories)
   - Register component -> verify `registeredComponents()` contains it -> `isComponentReady` returns false -> create files on disk simulating download -> `isComponentReady` returns true -> access via `withComponentAccess` -> verify `handle.url(for:)` returns valid URL -> `deleteComponent` -> `isComponentReady` returns false, `component(id)` still returns descriptor -> `unregister` -> `component(id)` returns nil
   - Register 3 components of different types (2 encoders, 1 decoder) -> `registeredComponents(ofType: .encoder).count == 2` and `registeredComponents(ofType: .decoder).count == 1`
   - Register same component from "two plugins" (same ID, same repo, same files) -> `registeredComponents().count == 1` (dedup)
   - Register same component from "two plugins" (same ID, different repo) -> `component(id)!.huggingFaceRepo` matches second registration (last wins)

2. **Backward compatibility tests** (~40 lines)
   - `Acervo.listModels()` still returns `[AcervoModel]` (type check, no runtime error)
   - `Acervo.isModelAvailable("nonexistent/model")` returns `false` (still works)
   - `AcervoManager.shared.withModelAccess("nonexistent/model") { _ in }` still callable (compiles and runs)
   - Three-state verification using temp directory:
     - Registered + downloaded (files on disk + registered): appears in both `registeredComponents()` and `listModels()` if `config.json` present
     - Not-registered + on-disk: appears only in `listModels()`
     - Registered + not-downloaded: appears only in `registeredComponents()`

3. **Coverage sweep**
   - Run: `xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS' -enableCodeCoverage YES`
   - Check coverage report for all new source files:
     - `ComponentDescriptor.swift` >= 90%
     - `ComponentRegistry.swift` >= 90%
     - `ComponentHandle.swift` >= 90%
     - `IntegrityVerification.swift` >= 90%
   - Add targeted tests for any uncovered branches

4. **CI stability review**
   - `grep -r 'sleep' Tests/SwiftAcervoTests/Component*.swift Tests/SwiftAcervoTests/IntegrityVerification*.swift` returns zero matches (no timed waits in new tests)
   - No tests reference `~/Library/SharedModels/` directly (all use temp directories)
   - All async tests use `async/await` or `AsyncStream`, not polling

**Dependencies**: All previous sorties (1--9).

**Estimated Turns**: 34 (R=10, C=2, M=4, B=2, L=4, V=7)

**Exit Criteria**:
- [ ] Full register -> download-simulate -> access -> verify -> delete -> unregister lifecycle test passes
- [ ] All v1 API methods compile and run without error (backward compatibility tests pass)
- [ ] Three states verified: registered+downloaded, not-registered+on-disk, registered+not-downloaded (integration test)
- [ ] Code coverage >= 90% on all 4 new source files: `ComponentDescriptor.swift`, `ComponentRegistry.swift`, `ComponentHandle.swift`, `IntegrityVerification.swift`
- [ ] `grep -r 'sleep' Tests/SwiftAcervoTests/Component*.swift Tests/SwiftAcervoTests/IntegrityVerification*.swift` returns zero matches
- [ ] No tests reference `~/Library/SharedModels/` path directly (grep verification)
- [ ] All tests pass: `xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS'` exits with code 0
- [ ] Build succeeds with no warnings: `xcodebuild build -scheme SwiftAcervo -destination 'platform=macOS'` exits with code 0

---

## Summary Table

| Sortie | Name | Priority | Model | New Files | Modified Files | Depends On | Spec | Est. Turns |
|--------|------|----------|-------|-----------|----------------|------------|------|------------|
| 0 | Reconnaissance | 25.0 | sonnet | 0 | 0 | -- | -- | 35 |
| 1 | ComponentDescriptor types | 22.0 | haiku | 2 | 0 | 0 | A1.1 | 20 |
| 2 | Error types | 18.0 | haiku | 0 | 2 | 0 | A6 | 18 |
| 3 | ComponentRegistry | 21.0 | sonnet | 2 | 0 | 1, 2 | A1.2 (int) | 21 |
| 4 | Registration API | 19.5 | haiku | 0 | 1 | 3 | A1.2 (pub) | 15 |
| 5 | Catalog queries | 17.5 | sonnet | 1 | 1 | 4 | A1.3 | 22 |
| 6 | ComponentHandle | 16.0 | sonnet | 2 | 0 | 1, 2 | A2.1 | 20 |
| 7 | Integrity verification | 15.5 | sonnet | 2 | 1 | 1, 3, 2, 4 | A4 | 25 |
| 8 | withComponentAccess | 14.0 | opus | 1 | 1 | 6, 7 | A2.2 | 23 |
| 9 | Registry-aware downloads | 12.0 | sonnet | 1 | 1 | 5, 7 | A3 | 23 |
| 10 | Integration & coverage | 8.0 | opus | 1+ | varies | all | A11 | 34 |

**Total new source files**: 4 (`ComponentDescriptor.swift`, `ComponentRegistry.swift`, `ComponentHandle.swift`, `IntegrityVerification.swift`)
**Total new test files**: 7 (`ComponentDescriptorTests`, `ComponentRegistryTests`, `ComponentHandleTests`, `ComponentAccessTests`, `ComponentDownloadTests`, `IntegrityVerificationTests`, `ComponentIntegrationTests`)
**Total modified source files**: 3 (`AcervoError.swift`, `Acervo.swift`, `AcervoManager.swift`)
**Total modified test files**: 1 (`AcervoErrorTests.swift`)
**Total estimated turns**: 256 (across 11 sorties)

---

## Resolved Questions

These items were listed as "Open Questions" in the v0 plan and are now resolved:

1. **Lock implementation**: **RESOLVED** — Use `NSLock` for `ComponentRegistry`. It is the simplest Foundation-only synchronous lock. The registry must NOT be an actor since `Acervo` static methods are synchronous. `NSLock` is correct.

2. **SHA-256 framework**: **RESOLVED** — Use `CryptoKit`. It is a system framework that ships on macOS 26+ / iOS 26+ (the project's minimum deployment targets). AGENTS.md says "zero external dependencies" meaning no SPM or CocoaPods packages; system frameworks like CryptoKit, Foundation, and Combine are not external dependencies. Add `import CryptoKit` to `IntegrityVerification.swift`.

3. **Warning logging for deduplication conflicts**: **RESOLVED** — Use `print` to stderr via `FileHandle.standardError`. This is the simplest Foundation-only approach. The REQUIREMENTS say "warning logged" but do not specify a mechanism. `os_log` and `Logger` are system frameworks but add complexity for a single warning path. `print` to stderr is sufficient for Wave 0. Can be upgraded to `os_log` in a future wave if structured logging is needed.

4. **`Package.swift` changes**: **RESOLVED** — No changes needed. All new files are in the existing `SwiftAcervo` target. `CryptoKit` is a system framework that does not require a package dependency declaration. No new targets or test targets are needed.

5. **Parallel sorties**: **RESOLVED** — See "Parallelism Structure" section above. Sorties 1 and 2 can run in parallel (Group 1). Sorties 5 and 6 can run in parallel (Group 4). All parallelism opportunities are annotated with agent assignments.

---

## Open Questions & Missing Documentation

### Unresolved Items

| Sortie | Issue Type | Description | Blocking? | Recommendation |
|--------|-----------|-------------|-----------|----------------|
| -- | None | All open questions from v0 plan have been resolved | No | -- |

No blocking issues remain. The plan is ready for execution.
