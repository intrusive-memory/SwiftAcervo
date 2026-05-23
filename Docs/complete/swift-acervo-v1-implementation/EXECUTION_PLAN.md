# SwiftAcervo — Execution Plan

> Shared AI model discovery and management for HuggingFace models

---

## Work Units

| Name | Directory | Sprints | Layer | Dependencies |
|------|-----------|---------|-------|-------------|
| Foundation | Sources/SwiftAcervo/ | 2 | 1 | none |
| Core API | Sources/SwiftAcervo/ | 3 | 2 | Foundation |
| Search & Fuzzy | Sources/SwiftAcervo/ | 2 | 2 | Foundation |
| Download | Sources/SwiftAcervo/ | 3 | 3 | Foundation, Core API |
| Migration | Sources/SwiftAcervo/ | 1 | 3 | Core API |
| Thread Safety | Sources/SwiftAcervo/ | 2 | 4 | Foundation, Core API, Download |
| Testing | Tests/SwiftAcervoTests/ | 6 | 5 | All previous |
| CI/CD & Docs | .github/, / | 3 | 6 | Testing |

**Dependency structure**: Mostly layered with some parallelism. Layer N cannot start until dependencies are met.

**Parallelization**: Core API and Search & Fuzzy (both in Layer 2) can run in parallel after Foundation completes.

---

## Work Unit: Foundation

### Sprint 1: Package scaffold and error types

**Priority**: 64.2 — blocks all 20 downstream sprints, establishes package foundation

**Entry criteria**: None — first sprint.

**Tasks**:

**1.1 - Create Package.swift** (~60 lines)
- Package name: `SwiftAcervo`
- Swift tools version: 6.2
- Platforms: `.macOS(.v26)`, `.iOS(.v26)`
- Single library target `SwiftAcervo`
- Test target `SwiftAcervoTests`
- Dependencies: none (Foundation only)
- Swift language mode: `.v6`
- Commit: "Create Package.swift with Swift 6.2 and platforms"

**1.2 - Create directory structure** (~10 lines)
- Create `Sources/SwiftAcervo/`
- Create `Tests/SwiftAcervoTests/`
- Add `.gitignore` for Swift package (`.build/`, `.swiftpm/`, `*.xcodeproj`)
- Commit: "Add directory structure and gitignore"

**1.3 - Create AcervoError enum** (~80 lines)
- Create `Sources/SwiftAcervo/AcervoError.swift`
- `enum AcervoError: LocalizedError, Sendable`
- Cases:
  - `directoryCreationFailed(String)`
  - `modelNotFound(String)`
  - `downloadFailed(fileName: String, statusCode: Int)`
  - `networkError(Error)`
  - `modelAlreadyExists(String)`
  - `migrationFailed(source: String, reason: String)`
  - `invalidModelId(String)`
- Implement `errorDescription` for all cases
- Commit: "Add AcervoError enum with LocalizedError conformance"

**1.4 - Test AcervoError descriptions** (~40 lines)
- Create `Tests/SwiftAcervoTests/AcervoErrorTests.swift`
- Test: each error case has non-nil errorDescription
- Test: modelNotFound includes model ID in description
- Test: downloadFailed includes fileName and statusCode
- Commit: "Add AcervoError description tests"

**Exit criteria**:
- [ ] `xcodebuild build -scheme SwiftAcervo -destination 'platform=macOS'` succeeds
- [ ] `xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS'` — all tests pass
- [ ] Package.swift has correct platforms and Swift version
- [ ] AcervoError enum has all 7 cases
- [ ] All error descriptions are implemented and tested

---

### Sprint 2: Core data structures

**Priority**: 61.4 — blocks 19 downstream sprints, establishes core data types

**Entry criteria**: Sprint 1 exit criteria satisfied.

**Tasks**:

**2.1 - Create AcervoDownloadProgress struct** (~60 lines)
- Create `Sources/SwiftAcervo/AcervoDownloadProgress.swift`
- `struct AcervoDownloadProgress: Sendable`
- Properties:
  - `fileName: String`
  - `bytesDownloaded: Int64`
  - `totalBytes: Int64?`
  - `fileIndex: Int`
  - `totalFiles: Int`
- Commit: "Add AcervoDownloadProgress struct"

**2.2 - Add overallProgress computed property** (~30 lines)
- Extend `AcervoDownloadProgress`
- Computed property `overallProgress: Double`
- Formula: `(Double(fileIndex) + progress) / Double(totalFiles)`
- Where `progress = totalBytes != nil ? Double(bytesDownloaded) / Double(totalBytes!) : 0.0`
- Clamp to 0.0...1.0
- Commit: "Add overallProgress computed property"

**2.3 - Create AcervoModel struct - core properties** (~80 lines)
- Create `Sources/SwiftAcervo/AcervoModel.swift`
- `struct AcervoModel: Identifiable, Equatable, Codable, Sendable`
- Properties:
  - `id: String` (HuggingFace ID like "mlx-community/Qwen2.5-7B-Instruct-4bit")
  - `path: URL`
  - `sizeBytes: Int64`
  - `downloadDate: Date`
- Commit: "Add AcervoModel struct with core properties"

**2.4 - Add AcervoModel computed properties** (~70 lines)
- Extend `AcervoModel.swift`
- `formattedSize: String` - format bytes as "4.4 GB", "120 MB", etc.
- `slug: String` - `id` with "/" replaced by "_"
- Commit: "Add formattedSize and slug computed properties"

**2.5 - Add AcervoModel name parsing properties** (~100 lines)
- Extend `AcervoModel.swift`
- `baseName: String` - strip quantization (`-4bit`, `-8bit`, `-bf16`, `-fp16`), size (`-0.6B`, `-1.7B`), variant (`-Base`, `-Instruct`, `-VoiceDesign`) suffixes
- `familyName: String` - org + base model without size/variant (e.g., "mlx-community/Qwen2.5")
- Helper: `private static func stripSuffixes(_ name: String) -> String`
- Commit: "Add baseName and familyName computed properties"

**2.6 - Test AcervoModel properties** (~80 lines)
- Create `Tests/SwiftAcervoTests/AcervoModelTests.swift`
- Test: slug converts "/" to "_"
- Test: formattedSize for various byte counts
- Test: baseName strips quantization suffixes
- Test: baseName strips size suffixes
- Test: baseName strips variant suffixes
- Test: familyName extraction
- Commit: "Add AcervoModel property tests"

**2.7 - Test AcervoDownloadProgress** (~60 lines)
- Create `Tests/SwiftAcervoTests/AcervoDownloadProgressTests.swift`
- Test: overallProgress for first file (fileIndex=0)
- Test: overallProgress for middle file (fileIndex=1 of 3)
- Test: overallProgress for last file (fileIndex=2 of 3)
- Test: overallProgress with unknown totalBytes
- Test: overallProgress clamping (never > 1.0)
- Commit: "Add AcervoDownloadProgress tests"

**Exit criteria**:
- [ ] Build succeeds
- [ ] All tests pass
- [ ] AcervoDownloadProgress has overallProgress computed property
- [ ] AcervoModel has all 8 properties (id, path, sizeBytes, downloadDate, formattedSize, slug, baseName, familyName)
- [ ] formattedSize returns non-empty strings for 0, KB, MB, GB byte values
- [ ] baseName strips quantization, size, and variant suffixes correctly

---

## Work Unit: Core API

### Sprint 3: Path handling and availability

**Priority**: 56.5 — blocks 17 downstream sprints, establishes Acervo static API namespace

**Entry criteria**: Foundation (Sprints 1-2) is COMPLETED.

**Tasks**:

**3.1 - Create Acervo.swift file** (~40 lines)
- Create `Sources/SwiftAcervo/Acervo.swift`
- `public enum Acervo {}` (namespace, no cases)
- Add file header documentation
- Commit: "Add Acervo static API namespace"

**3.2 - Implement sharedModelsDirectory** (~30 lines)
- Extend `Acervo`
- `public static var sharedModelsDirectory: URL`
- Return `FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/SharedModels")`
- Commit: "Add sharedModelsDirectory static property"

**3.3 - Implement slugify()** (~40 lines)
- Extend `Acervo`
- `public static func slugify(_ modelId: String) -> String`
- Replace "/" with "_"
- Handle edge cases: empty string → "", multiple slashes → all replaced
- Commit: "Add slugify() function"

**3.4 - Implement modelDirectory(for:)** (~50 lines)
- Extend `Acervo`
- `public static func modelDirectory(for modelId: String) throws -> URL`
- Validate: must contain exactly one "/"
- Throw `invalidModelId` if validation fails
- Return `sharedModelsDirectory.appendingPathComponent(slugify(modelId))`
- Commit: "Add modelDirectory(for:) function with validation"

**3.5 - Implement isModelAvailable()** (~40 lines)
- Extend `Acervo`
- `public static func isModelAvailable(_ modelId: String) -> Bool`
- Check if `config.json` exists in model directory
- Return false (not throwing) if directory doesn't exist
- Commit: "Add isModelAvailable() function"

**3.6 - Implement modelFileExists()** (~50 lines)
- Extend `Acervo`
- `public static func modelFileExists(_ modelId: String, fileName: String) -> Bool`
- Handle subdirectory paths (e.g., "speech_tokenizer/config.json")
- Return false if model directory or file doesn't exist
- Commit: "Add modelFileExists() function with subdirectory support"

**3.7 - Test path handling** (~100 lines)
- Create `Tests/SwiftAcervoTests/AcervoPathTests.swift`
- Test: sharedModelsDirectory ends with "Library/SharedModels"
- Test: slugify converts "/" to "_"
- Test: slugify handles multiple slashes
- Test: slugify handles empty string
- Test: modelDirectory throws for invalid ID (no slash)
- Test: modelDirectory throws for invalid ID (multiple slashes)
- Test: modelDirectory constructs correct path
- Commit: "Add path handling tests"

**3.8 - Test availability checks** (~80 lines)
- Create `Tests/SwiftAcervoTests/AcervoAvailabilityTests.swift`
- Test: isModelAvailable returns false for nonexistent model
- Test: isModelAvailable returns false when directory exists but no config.json
- Test: isModelAvailable returns true when config.json present
- Test: modelFileExists for root file
- Test: modelFileExists for subdirectory file
- Commit: "Add availability check tests"

**Exit criteria**:
- [ ] Build succeeds
- [ ] All tests pass
- [ ] sharedModelsDirectory returns ~/Library/SharedModels
- [ ] slugify converts "/" to "_"
- [ ] modelDirectory validates model ID format
- [ ] isModelAvailable checks for config.json
- [ ] modelFileExists supports subdirectory paths

---

### Sprint 4: Model discovery

**Priority**: 53.2 — blocks 16 downstream sprints, establishes listModels() used by search and fuzzy

**Entry criteria**: Sprint 3 exit criteria satisfied.

**Tasks**:

**4.1 - Implement directory size calculation helper** (~60 lines)
- Extend `Acervo`
- `private static func directorySize(at url: URL) throws -> Int64`
- Use `FileManager.default.enumerator(at:includingPropertiesForKeys:)`
- Sum `fileSize` resource values
- Handle errors gracefully (skip unreadable files)
- Commit: "Add directorySize helper"

**4.2 - Implement listModels() - scanning** (~80 lines)
- Extend `Acervo`
- `public static func listModels() throws -> [AcervoModel]`
- Scan sharedModelsDirectory for subdirectories
- Filter: must contain `config.json`
- Extract model ID from directory name (reverse slugify: first "_" → "/")
- Commit: "Add listModels() scanning logic"

**4.3 - Implement listModels() - metadata extraction** (~70 lines)
- Extend `listModels()`
- For each valid directory:
  - Get creation date from directory attributes
  - Calculate size via `directorySize(at:)`
  - Create `AcervoModel` instance
- Sort by ID (alphabetical)
- Commit: "Add metadata extraction to listModels()"

**4.4 - Implement modelInfo()** (~40 lines)
- Extend `Acervo`
- `public static func modelInfo(_ modelId: String) throws -> AcervoModel`
- Call `listModels()` and find matching ID
- Throw `modelNotFound` if not found
- Commit: "Add modelInfo() function"

**4.5 - Test listModels with temp directories** (~100 lines)
- Extend `AcervoAvailabilityTests.swift` or create new file
- Test: listModels() returns empty array for empty directory
- Test: listModels() finds model with config.json
- Test: listModels() skips directory without config.json
- Test: listModels() returns multiple models
- Test: model metadata correct (size, date, path)
- Use temporary directory for test isolation
- Commit: "Add listModels() tests"

**4.6 - Test modelInfo()** (~60 lines)
- Extend tests
- Test: modelInfo() returns correct model
- Test: modelInfo() throws modelNotFound for nonexistent model
- Test: modelInfo() metadata matches listModels() result
- Commit: "Add modelInfo() tests"

**Exit criteria**:
- [ ] Build succeeds
- [ ] All tests pass
- [ ] listModels() scans sharedModelsDirectory
- [ ] listModels() filters by config.json presence
- [ ] listModels() extracts correct metadata (size, date, path)
- [ ] modelInfo() returns single model or throws modelNotFound

---

### Sprint 5: Pattern matching

**Priority**: 46.9 — blocks 15 downstream sprints, gates Download and Migration work units

**Entry criteria**: Sprint 4 exit criteria satisfied.

**Tasks**:

**5.1 - Implement findModels(matching:)** (~60 lines)
- Extend `Acervo`
- `public static func findModels(matching pattern: String) throws -> [AcervoModel]`
- Case-insensitive substring search across model IDs
- Call `listModels()` and filter
- Return all matches, sorted by ID
- Commit: "Add findModels(matching:) exact substring search"

**5.2 - Test findModels(matching:)** (~80 lines)
- Create `Tests/SwiftAcervoTests/AcervoSearchTests.swift`
- Test: exact substring match
- Test: case insensitivity
- Test: returns all matches
- Test: returns empty array if no matches
- Test: partial match (e.g., "Qwen" matches "Qwen2.5-7B-Instruct-4bit")
- Use temporary directory with test models
- Commit: "Add findModels(matching:) tests"

**Exit criteria**:
- [ ] Build succeeds
- [ ] All tests pass
- [ ] findModels(matching:) performs case-insensitive substring search
- [ ] findModels(matching:) returns all matching models
- [ ] findModels(matching:) returns empty array if no matches

---

## Work Unit: Search & Fuzzy

### Sprint 6: Levenshtein distance

**Priority**: 29.9 — gates fuzzy search, complex DP algorithm

**Entry criteria**: Foundation (Sprints 1-2) is COMPLETED. Can run in parallel with Core API (Sprints 3-5).

**Tasks**:

**6.1 - Implement Levenshtein distance algorithm** (~100 lines)
- Create `Sources/SwiftAcervo/LevenshteinDistance.swift`
- `func levenshteinDistance(_ s1: String, _ s2: String) -> Int`
- Standard dynamic programming implementation
- Handle empty strings
- Case-insensitive comparison (lowercase both inputs)
- Commit: "Add Levenshtein distance algorithm"

**6.2 - Test Levenshtein distance** (~100 lines)
- Create `Tests/SwiftAcervoTests/LevenshteinDistanceTests.swift`
- Test: identical strings → distance 0
- Test: empty strings
- Test: single character diff → distance 1
- Test: insertion → distance 1
- Test: deletion → distance 1
- Test: substitution → distance 1
- Test: case insensitivity
- Test: known examples (e.g., "kitten" vs "sitting" = 3)
- Commit: "Add Levenshtein distance tests"

**Exit criteria**:
- [ ] Build succeeds
- [ ] All tests pass
- [ ] Levenshtein distance implementation correct for all test cases
- [ ] Case-insensitive comparison works

---

### Sprint 7: Fuzzy search

**Priority**: 27.2 — completes Search & Fuzzy work unit, complex prefix-stripping + distance logic

**Entry criteria**: Sprint 6 exit criteria satisfied AND Sprint 5 exit criteria satisfied (needs Core API).

**Tasks**:

**7.1 - Implement findModels(fuzzyMatching:editDistance:)** (~100 lines)
- Extend `Acervo.swift`
- `public static func findModels(fuzzyMatching query: String, editDistance threshold: Int = 5) throws -> [AcervoModel]`
- Strip common prefixes ("mlx-community/") from both query and model IDs before comparison
- Calculate Levenshtein distance for each model
- Filter: distance ≤ threshold
- Sort by distance (closest first), then by ID
- Return array of models with distances
- Commit: "Add findModels(fuzzyMatching:) function"

**7.2 - Implement closestModel(to:editDistance:)** (~50 lines)
- Extend `Acervo.swift`
- `public static func closestModel(to query: String, editDistance threshold: Int = 5) throws -> AcervoModel?`
- Call `findModels(fuzzyMatching:editDistance:)`
- Return first result (closest) or nil
- Commit: "Add closestModel() function"

**7.3 - Implement modelFamilies()** (~80 lines)
- Extend `Acervo.swift`
- `public static func modelFamilies() throws -> [String: [AcervoModel]]`
- Group models by `familyName`
- Return dictionary: family name → array of models
- Sort models within each family by ID
- Commit: "Add modelFamilies() function"

**7.4 - Test fuzzy search** (~120 lines)
- Create `Tests/SwiftAcervoTests/AcervoFuzzySearchTests.swift`
- Test: finds close matches within threshold
- Test: respects threshold (distance > threshold excluded)
- Test: strips prefixes before comparison
- Test: sorts results by closeness
- Test: returns empty array if no matches within threshold
- Use temporary directory with test models
- Commit: "Add fuzzy search tests"

**7.5 - Test closestModel()** (~60 lines)
- Extend fuzzy search tests
- Test: returns closest match
- Test: returns nil when no match within threshold
- Test: returns first result when multiple equidistant matches
- Commit: "Add closestModel() tests"

**7.6 - Test modelFamilies()** (~80 lines)
- Extend tests
- Test: groups models by family name
- Test: models with same base name in same family
- Test: quantization variants grouped together
- Test: size variants grouped together
- Commit: "Add modelFamilies() tests"

**Exit criteria**:
- [ ] Build succeeds
- [ ] All tests pass
- [ ] findModels(fuzzyMatching:) uses Levenshtein distance
- [ ] Fuzzy search strips prefixes before comparison
- [ ] Fuzzy search sorts by distance
- [ ] closestModel() returns best match or nil
- [ ] modelFamilies() groups by base name correctly

---

## Work Unit: Download

### Sprint 8: Download infrastructure

**Priority**: 42.2 — blocks 12 downstream sprints, external API risk (HuggingFace URLs), establishes downloader

**Entry criteria**: Foundation (Sprints 1-2) AND Core API (Sprints 3-5) are COMPLETED.

**Tasks**:

**8.1 - Create AcervoDownloader.swift file** (~40 lines)
- Create `Sources/SwiftAcervo/AcervoDownloader.swift`
- `struct AcervoDownloader` (internal, not public)
- Add file header documentation
- Commit: "Add AcervoDownloader struct"

**8.2 - Implement HuggingFace URL construction** (~50 lines)
- Extend `AcervoDownloader`
- `static func buildURL(modelId: String, fileName: String) -> URL`
- Format: `https://huggingface.co/{modelId}/resolve/main/{fileName}`
- Handle subdirectory files (e.g., "speech_tokenizer/config.json")
- Commit: "Add HuggingFace URL construction"

**8.3 - Test URL construction** (~60 lines)
- Create `Tests/SwiftAcervoTests/AcervoDownloaderTests.swift`
- Test: URL for root file
- Test: URL for subdirectory file
- Test: URL components correct (scheme, host, path)
- Commit: "Add URL construction tests"

**8.4 - Implement directory creation helper** (~50 lines)
- Extend `AcervoDownloader`
- `static func ensureDirectory(at url: URL) throws`
- Create directory with intermediate directories
- Skip if already exists
- Commit: "Add directory creation helper"

**8.5 - Implement file download helper** (~100 lines)
- Extend `AcervoDownloader`
- `static func downloadFile(from url: URL, to destination: URL, token: String?) async throws`
- Use `URLSession.shared.download(from:delegate:)` (no delegate for now)
- Add `Authorization: Bearer {token}` header if token provided
- Verify HTTP 200 (throw `downloadFailed` otherwise)
- Move temp file to destination atomically
- Create intermediate directories if needed
- Commit: "Add single file download helper"

**8.6 - Test file download (mock)** (~80 lines)
- Extend tests
- Test: builds URLRequest with correct headers
- Test: throws downloadFailed for non-200 status
- Test: creates intermediate directories
- Note: Full integration tests in Sprint 12
- Commit: "Add file download unit tests"

**Exit criteria**:
- [ ] Build succeeds
- [ ] All tests pass
- [ ] URL construction correct for root and subdirectory files
- [ ] Directory creation works with intermediate paths
- [ ] File download helper validates HTTP status
- [ ] Auth token added to header when provided

---

### Sprint 9: Progress tracking

**Priority**: 37.0 — blocks 11 downstream sprints, URLSession delegate integration

**Entry criteria**: Sprint 8 exit criteria satisfied.

**Tasks**:

**9.1 - Implement progress callback in downloadFile** (~60 lines)
- Extend `downloadFile(from:to:token:)` signature
- Add `progress: ((AcervoDownloadProgress) -> Void)?` parameter
- Use `URLSession.shared.download(from:)` with delegate for progress
- Call progress callback with bytes downloaded and total bytes
- Commit: "Add progress callback to downloadFile"

**9.2 - Implement multi-file download** (~120 lines)
- Extend `AcervoDownloader`
- `static func downloadFiles(modelId: String, files: [String], destination: URL, token: String?, progress: ((AcervoDownloadProgress) -> Void)?) async throws`
- Loop through files
- Track file index
- Calculate overall progress
- Call progress callback for each file
- Skip files that already exist (unless force flag)
- Commit: "Add multi-file download with progress"

**9.3 - Add force parameter** (~40 lines)
- Extend `downloadFiles` signature
- Add `force: Bool = false` parameter
- Skip existing files check if force is true
- Commit: "Add force parameter to downloadFiles"

**9.4 - Test progress calculation** (~80 lines)
- Extend tests
- Test: progress for single file
- Test: progress across multiple files
- Test: overallProgress calculation
- Test: file index tracking
- Commit: "Add progress calculation tests"

**9.5 - Test skip-if-exists** (~60 lines)
- Extend tests
- Test: skips existing files when force=false
- Test: re-downloads when force=true
- Use temporary directory
- Commit: "Add skip-if-exists tests"

**Exit criteria**:
- [ ] Build succeeds
- [ ] All tests pass
- [ ] Progress callback provides file-level and overall progress
- [ ] Multi-file download tracks file index
- [ ] Skip-if-exists logic works correctly
- [ ] Force parameter overrides skip-if-exists

---

### Sprint 10: Public download API

**Priority**: 35.0 — blocks 10 downstream sprints, establishes public download/ensureAvailable/delete API

**Entry criteria**: Sprint 9 exit criteria satisfied.

**Tasks**:

**10.1 - Implement Acervo.download()** (~80 lines)
- Extend `Acervo.swift`
- `public static func download(_ modelId: String, files: [String], token: String? = nil, force: Bool = false, progress: ((AcervoDownloadProgress) -> Void)? = nil) async throws`
- Validate model ID format
- Get model directory
- Call `AcervoDownloader.downloadFiles`
- Create directory if needed
- Commit: "Add Acervo.download() public API"

**10.2 - Implement Acervo.ensureAvailable()** (~60 lines)
- Extend `Acervo.swift`
- `public static func ensureAvailable(_ modelId: String, files: [String], token: String? = nil, progress: ((AcervoDownloadProgress) -> Void)? = nil) async throws`
- Check if model is available via `isModelAvailable()`
- Skip download if available
- Otherwise call `download()` with force=false
- Commit: "Add Acervo.ensureAvailable() function"

**10.3 - Implement Acervo.deleteModel()** (~60 lines)
- Extend `Acervo.swift`
- `public static func deleteModel(_ modelId: String) throws`
- Get model directory
- Verify directory exists (throw `modelNotFound` if not)
- Remove directory recursively
- Commit: "Add Acervo.deleteModel() function"

**10.4 - Test download API** (~100 lines)
- Create `Tests/SwiftAcervoTests/AcervoDownloadAPITests.swift`
- Test: download() validates model ID
- Test: download() creates directory
- Test: download() calls downloader with correct parameters
- Test: ensureAvailable() skips if model exists
- Test: ensureAvailable() downloads if model missing
- Use temporary directory
- Commit: "Add download API tests"

**10.5 - Test deleteModel()** (~60 lines)
- Extend tests
- Test: deleteModel() removes directory
- Test: deleteModel() throws modelNotFound if directory doesn't exist
- Use temporary directory
- Commit: "Add deleteModel() tests"

**Exit criteria**:
- [ ] Build succeeds
- [ ] All tests pass
- [ ] download() public API works
- [ ] ensureAvailable() skips existing models
- [ ] deleteModel() removes model directory
- [ ] All APIs validate model ID format

---

## Work Unit: Thread Safety

### Sprint 11: Actor-based manager

**Priority**: 32.2 — blocks 9 downstream sprints, establishes AcervoManager actor with concurrency

**Entry criteria**: Foundation, Core API, and Download (Sprints 1-10) are COMPLETED.

**Tasks**:

**11.1 - Create AcervoManager actor** (~60 lines)
- Create `Sources/SwiftAcervo/AcervoManager.swift`
- `public actor AcervoManager`
- `public static let shared = AcervoManager()`
- Private initializer
- Properties:
  - `private var downloadLocks: [String: Bool] = [:]` (model ID → locked)
  - `private var urlCache: [String: URL] = [:]` (model ID → URL)
- Commit: "Add AcervoManager actor with singleton"

**11.2 - Implement per-model locking** (~80 lines)
- Extend `AcervoManager`
- `private func acquireLock(for modelId: String) async`
- Wait loop: while downloadLocks[modelId] == true, sleep 50ms
- Set downloadLocks[modelId] = true
- `private func releaseLock(for modelId: String)`
- Set downloadLocks[modelId] = false
- Commit: "Add per-model locking mechanism"

**11.3 - Implement download() method** (~100 lines)
- Extend `AcervoManager`
- `public func download(_ modelId: String, files: [String], token: String? = nil, progress: ((AcervoDownloadProgress) -> Void)? = nil) async throws`
- Acquire lock for modelId
- Defer release lock
- Call `Acervo.download()` (non-actor static method)
- Commit: "Add AcervoManager.download() with locking"

**11.4 - Implement withModelAccess()** (~80 lines)
- Extend `AcervoManager`
- `public func withModelAccess<T>(_ modelId: String, perform: @Sendable (URL) throws -> T) async throws -> T`
- Acquire lock for modelId
- Defer release lock
- Get model directory URL
- Execute closure with URL
- Return closure result
- Commit: "Add withModelAccess() for exclusive access"

**11.5 - Test locking serialization** (~100 lines)
- Create `Tests/SwiftAcervoTests/AcervoManagerTests.swift`
- Test: concurrent downloads of same model are serialized
- Test: concurrent downloads of different models proceed in parallel
- Use Task groups for concurrent operations
- Measure execution order with timestamps
- Commit: "Add locking serialization tests"

**11.6 - Test withModelAccess()** (~80 lines)
- Extend tests
- Test: provides exclusive access to model directory
- Test: lock released on success
- Test: lock released on error
- Test: concurrent access serialized
- Commit: "Add withModelAccess() tests"

**Exit criteria**:
- [ ] Build succeeds
- [ ] All tests pass
- [ ] AcervoManager is an actor with shared singleton
- [ ] Per-model locking works (same model serialized, different models parallel)
- [ ] withModelAccess() provides exclusive access
- [ ] Locks released on error

---

### Sprint 12: Cache and statistics

**Priority**: 26.2 — completes Thread Safety work unit, low risk

**Entry criteria**: Sprint 11 exit criteria satisfied.

**Tasks**:

**12.1 - Implement URL cache** (~60 lines)
- Extend `AcervoManager`
- `private func cachedURL(for modelId: String) -> URL?`
- Check urlCache dictionary
- Return cached URL if present
- `private func cacheURL(_ url: URL, for modelId: String)`
- Store in urlCache dictionary
- Commit: "Add URL cache to AcervoManager"

**12.2 - Implement clearCache()** (~30 lines)
- Extend `AcervoManager`
- `public func clearCache()`
- Clear urlCache dictionary
- Commit: "Add clearCache() method"

**12.3 - Implement preloadModels()** (~60 lines)
- Extend `AcervoManager`
- `public func preloadModels() async throws`
- Call `Acervo.listModels()`
- Cache URL for each model
- Commit: "Add preloadModels() method"

**12.4 - Add statistics tracking** (~80 lines)
- Extend `AcervoManager`
- Properties:
  - `private var downloadCount: [String: Int] = [:]` (model ID → count)
  - `private var accessCount: [String: Int] = [:]` (model ID → count)
- Track in download() and withModelAccess()
- `public func printStatisticsReport()`
- Print top 10 downloaded and accessed models
- Commit: "Add statistics tracking and reporting"

**12.5 - Test cache** (~80 lines)
- Extend tests
- Test: URL cache correctness
- Test: clearCache() empties cache
- Test: preloadModels() populates cache
- Use temporary directory
- Commit: "Add cache tests"

**12.6 - Test statistics** (~60 lines)
- Extend tests
- Test: download count increments
- Test: access count increments
- Test: printStatisticsReport() output
- Commit: "Add statistics tests"

**Exit criteria**:
- [ ] Build succeeds
- [ ] All tests pass
- [ ] URL cache works correctly
- [ ] clearCache() clears cache
- [ ] preloadModels() caches all model URLs
- [ ] Statistics tracking works
- [ ] printStatisticsReport() prints top models

---

## Work Unit: Migration

### Sprint 13: Legacy path migration

**Priority**: 27.4 — blocks 8 downstream sprints, file I/O risk (directory moves)

**Entry criteria**: Core API (Sprints 3-5) is COMPLETED.

**Tasks**:

**13.1 - Implement legacy path constants** (~40 lines)
- Create `Sources/SwiftAcervo/AcervoMigration.swift`
- `struct AcervoMigration` (internal)
- Static properties for legacy paths:
  - `legacyBasePath`: "~/Library/Caches/intrusive-memory/Models/"
  - `legacySubdirectories`: ["LLM", "TTS", "Audio", "VLM"]
- Commit: "Add legacy path constants"

**13.2 - Implement Acervo.migrateFromLegacyPaths() - scanning** (~100 lines)
- Extend `Acervo.swift`
- `public static func migrateFromLegacyPaths() throws -> [AcervoModel]`
- Scan each legacy subdirectory
- Find directories containing config.json
- Extract slug from directory name
- Commit: "Add legacy path scanning"

**13.3 - Implement Acervo.migrateFromLegacyPaths() - moving** (~100 lines)
- Extend `migrateFromLegacyPaths()`
- For each valid legacy directory:
  - Check if destination exists in SharedModels
  - Skip if exists (prefer existing)
  - Move directory if not exists
  - Create AcervoModel entry
- Return list of migrated models
- Do NOT delete old parent directories
- Commit: "Add legacy path moving logic"

**13.4 - Test migration with empty directories** (~60 lines)
- Create `Tests/SwiftAcervoTests/AcervoMigrationTests.swift`
- Test: migrateFromLegacyPaths() with no legacy directories
- Test: returns empty array
- Use temporary directories
- Commit: "Add empty directory migration test"

**13.5 - Test migration with valid models** (~100 lines)
- Extend tests
- Test: moves model from legacy LLM directory
- Test: moves model from legacy TTS directory
- Test: skips model already in SharedModels
- Test: handles missing config.json
- Test: returns correct AcervoModel list
- Use temporary directories
- Commit: "Add valid model migration tests"

**13.6 - Test migration error handling** (~60 lines)
- Extend tests
- Test: handles unreadable directories
- Test: handles filesystem errors gracefully
- Test: partial success (some models migrate, some fail)
- Commit: "Add migration error handling tests"

**Exit criteria**:
- [ ] Build succeeds
- [ ] All tests pass
- [ ] migrateFromLegacyPaths() scans all 4 legacy subdirectories
- [ ] Moves valid models to SharedModels
- [ ] Skips models already in SharedModels
- [ ] Returns list of migrated models
- [ ] Does NOT delete old parent directories
- [ ] Handles errors gracefully

---

## Work Unit: Testing

### Sprint 14: Integration tests

**Priority**: 25.4 — blocks 7 downstream sprints, external API risk (real HuggingFace calls)

**Entry criteria**: All previous work units (Sprints 1-13) are COMPLETED.

**Tasks**:

**14.1 - Create integration test infrastructure** (~60 lines)
- Create `Tests/SwiftAcervoTests/IntegrationTests.swift`
- Mark tests with `#if INTEGRATION_TESTS` (compile-time flag)
- Add test helper for temporary SharedModels directory
- Clean up after each test
- Commit: "Add integration test infrastructure"

**14.2 - Test real download from HuggingFace** (~80 lines)
- Extend `IntegrationTests.swift`
- Test: download small config.json from real model
- Verify: file lands at correct path
- Verify: file content is valid JSON
- Use small model (e.g., "mlx-community/Llama-3.2-1B-Instruct-4bit")
- Commit: "Add real download integration test"

**14.3 - Test ensureAvailable() with network** (~60 lines)
- Extend integration tests
- Test: ensureAvailable() skips if model exists
- Test: ensureAvailable() downloads if missing
- Commit: "Add ensureAvailable() integration test"

**14.4 - Test force re-download** (~40 lines)
- Extend integration tests
- Test: force=true re-downloads existing file
- Verify: file is replaced
- Commit: "Add force re-download integration test"

**14.5 - Test auth token header** (~60 lines)
- Extend integration tests
- Test: auth token is sent in Authorization header
- Use network inspection or mock server
- Note: May need to test with gated model (requires real token)
- Commit: "Add auth token integration test"

**14.6 - Test subdirectory file download** (~60 lines)
- Extend integration tests
- Test: download file in subdirectory (e.g., "speech_tokenizer/config.json")
- Verify: intermediate directories created
- Verify: file lands at correct path
- Commit: "Add subdirectory file download test"

**14.7 - Test HTTP error handling** (~80 lines)
- Extend integration tests
- Test: 404 error for nonexistent file
- Test: network timeout
- Verify: descriptive error messages
- Commit: "Add HTTP error handling tests"

**Exit criteria**:
- [ ] Build succeeds (with INTEGRATION_TESTS flag)
- [ ] All integration tests pass (network required)
- [ ] Real download from HuggingFace works
- [ ] ensureAvailable() skips existing models
- [ ] force=true re-downloads
- [ ] Auth token sent in header
- [ ] Subdirectory files download correctly
- [ ] HTTP errors handled gracefully

---

### Sprint 15: Edge case unit tests

**Priority**: 20.0 — blocks 6 downstream sprints, low complexity

**Entry criteria**: Sprint 14 exit criteria satisfied.

**Tasks**:

**15.1 - Add edge case tests for slugify()** (~60 lines)
- Extend `AcervoPathTests.swift`
- Test: model ID with org containing underscore (e.g., "my_org/model")
- Test: model ID with hyphen
- Test: model ID with numbers
- Test: very long model ID
- Commit: "Add slugify() edge case tests"

**15.2 - Add edge case tests for download progress** (~60 lines)
- Extend `AcervoDownloadProgressTests.swift`
- Test: progress with zero totalBytes
- Test: progress with zero totalFiles
- Test: progress at exactly 100%
- Test: progress rounding
- Commit: "Add download progress edge case tests"

**15.3 - Add edge case tests for model metadata** (~80 lines)
- Extend `AcervoModelTests.swift`
- Test: formattedSize for zero bytes
- Test: formattedSize for bytes (< 1 KB)
- Test: formattedSize for KB, MB, GB, TB
- Test: baseName for model without suffixes
- Test: familyName for various model formats
- Commit: "Add model metadata edge case tests"

**Exit criteria**:
- [ ] `xcodebuild build -scheme SwiftAcervo -destination 'platform=macOS'` succeeds
- [ ] `xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS'` — all tests pass
- [ ] AcervoPathTests.swift contains edge case tests for underscores, hyphens, numbers, and long IDs
- [ ] AcervoDownloadProgressTests.swift contains edge case tests for zero values and clamping
- [ ] AcervoModelTests.swift contains edge case tests for formattedSize and baseName edge cases

---

### Sprint 16: Error path and concurrency tests

**Priority**: 17.9 — blocks 5 downstream sprints, concurrency testing complexity

**Entry criteria**: Sprint 15 exit criteria satisfied.

**Tasks**:

**16.1 - Add error path tests** (~80 lines)
- Create `Tests/SwiftAcervoTests/AcervoErrorPathTests.swift`
- Test: download with invalid model ID
- Test: deleteModel() for nonexistent model
- Test: modelInfo() for nonexistent model
- Test: all error cases produce descriptive messages
- Commit: "Add error path tests"

**16.2 - Add concurrency stress tests** (~100 lines)
- Create `Tests/SwiftAcervoTests/AcervoConcurrencyTests.swift`
- Test: 10 concurrent downloads of different models
- Test: 10 concurrent accesses to same model (serialized)
- Test: interleaved downloads and accesses
- Measure performance (not for CI, just informational)
- Commit: "Add concurrency stress tests"

**Exit criteria**:
- [ ] `xcodebuild build -scheme SwiftAcervo -destination 'platform=macOS'` succeeds
- [ ] `xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS'` — all tests pass
- [ ] File exists: `Tests/SwiftAcervoTests/AcervoErrorPathTests.swift`
- [ ] File exists: `Tests/SwiftAcervoTests/AcervoConcurrencyTests.swift`
- [ ] Error path tests cover invalid model ID, nonexistent model, and descriptive error messages
- [ ] Concurrency tests verify serialization of same-model access and parallelism of different-model access

---

### Sprint 17: Test fixtures and documentation

**Priority**: 14.0 — blocks 4 downstream sprints, low risk documentation

**Entry criteria**: Sprint 16 exit criteria satisfied.

**Tasks**:

**17.1 - Create test fixtures directory** (~40 lines)
- Create `Tests/SwiftAcervoTests/Fixtures/`
- Add README explaining fixtures
- Add .gitkeep to preserve directory
- Commit: "Add test fixtures directory"

**17.2 - Add inline documentation to Acervo.swift** (~80 lines)
- Extend `Acervo.swift`
- Add doc comments to all public methods
- Include parameter descriptions
- Include return value descriptions
- Include `throws` descriptions
- Include usage examples
- Commit: "Add inline documentation to Acervo"

**17.3 - Add inline documentation to AcervoManager.swift** (~60 lines)
- Extend `AcervoManager.swift`
- Add doc comments to all public methods
- Include concurrency notes
- Include usage examples
- Commit: "Add inline documentation to AcervoManager"

**17.4 - Add inline documentation to types** (~60 lines)
- Extend `AcervoModel.swift`, `AcervoError.swift`, `AcervoDownloadProgress.swift`
- Add doc comments to all public properties
- Add struct/enum descriptions
- Commit: "Add inline documentation to types"

**Exit criteria**:
- [ ] `xcodebuild build -scheme SwiftAcervo -destination 'platform=macOS'` succeeds
- [ ] Directory exists: `Tests/SwiftAcervoTests/Fixtures/`
- [ ] `grep -c '///' Sources/SwiftAcervo/Acervo.swift` shows doc comments present on public methods
- [ ] `grep -c '///' Sources/SwiftAcervo/AcervoManager.swift` shows doc comments present on public methods
- [ ] `grep -c '///' Sources/SwiftAcervo/AcervoModel.swift` shows doc comments present on public properties

---

### Sprint 18: Final test validation

**Priority**: 11.0 — blocks 3 downstream sprints, validation only

**Entry criteria**: Sprint 17 exit criteria satisfied.

**Tasks**:

**18.1 - Run full test suite on macOS** (~20 lines)
- Run `xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS'`
- Verify all tests pass
- Fix any failures
- Commit: "Verify all macOS tests pass"

**18.2 - Run full test suite on iOS Simulator** (~20 lines)
- Run `xcodebuild test -scheme SwiftAcervo -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.1'`
- Verify all tests pass
- Fix any iOS-specific failures
- Commit: "Verify all iOS tests pass"

**18.3 - Verify zero warnings** (~20 lines)
- Run `xcodebuild build -scheme SwiftAcervo -destination 'platform=macOS' -warnings-as-errors`
- Fix any warnings
- Commit: "Fix all compiler warnings"

**18.4 - Verify strict concurrency** (~20 lines)
- Verify all public types are Sendable
- Verify no Sendable warnings
- Verify actor isolation correct
- Commit: "Verify strict concurrency compliance"

**Exit criteria**:
- [ ] `xcodebuild build -scheme SwiftAcervo -destination 'platform=macOS'` succeeds
- [ ] `xcodebuild build -scheme SwiftAcervo -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.1'` succeeds
- [ ] `xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS'` — all tests pass
- [ ] `xcodebuild test -scheme SwiftAcervo -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.1'` — all tests pass
- [ ] `xcodebuild build -scheme SwiftAcervo -destination 'platform=macOS' -warnings-as-errors` — zero warnings
- [ ] No `Sendable` or actor isolation warnings in build output

---

## Work Unit: CI/CD & Docs

### Sprint 19: GitHub Actions

**Priority**: 7.9 — blocks 2 downstream sprints, CI/CD configuration

**Entry criteria**: Testing (Sprints 14-18) is COMPLETED.

**Tasks**:

**19.1 - Create tests.yml workflow file** (~60 lines)
- Create `.github/workflows/tests.yml`
- Name: "Tests"
- Trigger: pull_request to main and development
- Add concurrency group (cancel in-progress)
- Commit: "Add GitHub Actions workflow file"

**19.2 - Add macOS test job** (~80 lines)
- Extend `tests.yml`
- Job: `test-macos`
- Name: "Test on macOS"
- Runner: `macos-26`
- Steps:
  - Checkout code
  - Show Swift version
  - Build with xcodebuild
  - Test with xcodebuild
- Commit: "Add macOS test job"

**19.3 - Add iOS Simulator test job** (~80 lines)
- Extend `tests.yml`
- Job: `test-ios`
- Name: "Test on iOS Simulator"
- Runner: `macos-26`
- Destination: `'platform=iOS Simulator,name=iPhone 17,OS=26.1'`
- Steps: same as macOS
- Commit: "Add iOS Simulator test job"

**19.4 - Test workflow locally** (~20 lines)
- Use `act` or manual testing
- Verify workflow syntax correct
- Verify jobs run (if possible)
- Commit: "Verify workflow syntax"

**19.5 - Configure branch protection rules** (~40 lines)
- Document branch protection setup in CONTRIBUTING.md or README
- Required status checks: "Test on macOS", "Test on iOS Simulator"
- Require PR before merge to main
- Note: Actual setup done via GitHub UI or gh CLI
- Commit: "Document branch protection requirements"

**Exit criteria**:
- [ ] File exists: `.github/workflows/tests.yml`
- [ ] `grep -q 'test-macos' .github/workflows/tests.yml` — macOS job present
- [ ] `grep -q 'test-ios' .github/workflows/tests.yml` — iOS job present
- [ ] `grep -q 'macos-26' .github/workflows/tests.yml` — correct runner
- [ ] `grep -q 'iPhone 17' .github/workflows/tests.yml` — correct iOS destination
- [ ] `gh workflow view tests.yml` or `yamllint .github/workflows/tests.yml` — syntax valid

---

### Sprint 20: README — Core documentation

**Priority**: 4.9 — blocks 1 downstream sprint, documentation

**Entry criteria**: Sprint 19 exit criteria satisfied.

**Tasks**:

**20.1 - Update README.md - Overview** (~80 lines)
- Update `README.md`
- Add project description
- Add "Why SwiftAcervo?" section
- Add "The Problem" section (duplicated models)
- Add "The Solution" section (canonical path)
- Commit: "Update README with project overview"

**20.2 - Update README.md - Installation** (~60 lines)
- Extend `README.md`
- Add "Installation" section
- Swift Package Manager instructions
- Package.swift example
- Platforms and requirements
- Commit: "Add installation instructions to README"

**20.3 - Update README.md - Quick Start** (~100 lines)
- Extend `README.md`
- Add "Quick Start" section
- Example: Check if model available
- Example: Download a model
- Example: List all models
- Example: Fuzzy search
- Example: Delete a model
- Commit: "Add Quick Start to README"

**20.4 - Update README.md - API Reference** (~120 lines)
- Extend `README.md`
- Add "API Reference" section
- Document Acervo static API
- Document AcervoManager actor
- Document all public methods briefly
- Link to AGENTS.md for details
- Commit: "Add API Reference to README"

**Exit criteria**:
- [ ] `xcodebuild build -scheme SwiftAcervo -destination 'platform=macOS'` succeeds
- [ ] `grep -q '## Why SwiftAcervo' README.md` — overview section exists
- [ ] `grep -q '## Installation' README.md` — installation section exists
- [ ] `grep -q '## Quick Start' README.md` — quick start section exists
- [ ] `grep -q '## API Reference' README.md` — API reference section exists
- [ ] README.md contains Swift code examples (import SwiftAcervo)

---

### Sprint 21: README — Integration, contributing, and license

**Priority**: 2.2 — leaf sprint, no dependents

**Entry criteria**: Sprint 20 exit criteria satisfied.

**Tasks**:

**21.1 - Update README.md - Consumer Integration** (~100 lines)
- Extend `README.md`
- Add "Consumer Integration" section
- Example for SwiftBruja
- Example for mlx-audio-swift
- Example for SwiftVoxAlta
- Example for Produciesta
- Commit: "Add consumer integration examples to README"

**21.2 - Update README.md - Migration** (~80 lines)
- Extend `README.md`
- Add "Migration from Legacy Paths" section
- Explain legacy path structure
- Show migrateFromLegacyPaths() usage
- Note: Safe operation, doesn't delete old directories
- Commit: "Add migration guide to README"

**21.3 - Update README.md - Thread Safety** (~60 lines)
- Extend `README.md`
- Add "Thread Safety" section
- Explain AcervoManager locking
- Example of concurrent downloads
- Example of withModelAccess()
- Commit: "Add thread safety section to README"

**21.4 - Update README.md - Testing** (~40 lines)
- Extend `README.md`
- Add "Testing" section
- Unit tests (no network required)
- Integration tests (network required, INTEGRATION_TESTS flag)
- CI/CD status badge
- Commit: "Add testing section to README"

**21.5 - Create CONTRIBUTING.md** (~80 lines)
- Create `CONTRIBUTING.md`
- Add development setup instructions
- Add testing guidelines
- Add commit message conventions
- Add PR process
- Add code style notes (SwiftFormat, if used)
- Commit: "Add CONTRIBUTING.md"

**21.6 - Create LICENSE** (~20 lines)
- Create `LICENSE` (MIT or Apache 2.0)
- Update README with license badge
- Commit: "Add LICENSE file"

**Exit criteria**:
- [ ] `xcodebuild build -scheme SwiftAcervo -destination 'platform=macOS'` succeeds
- [ ] `grep -q '## Consumer Integration' README.md` — consumer section exists
- [ ] `grep -q '## Migration' README.md` — migration section exists
- [ ] `grep -q '## Thread Safety' README.md` — thread safety section exists
- [ ] `grep -q '## Testing' README.md` — testing section exists
- [ ] File exists: `CONTRIBUTING.md`
- [ ] File exists: `LICENSE`

---

## Dispatch Template

```
You are working on SwiftAcervo in $PROJECT_ROOT/.

FIRST, read these files in order:
1. $PROJECT_ROOT/EXECUTION_PLAN.md
2. $PROJECT_ROOT/REQUIREMENTS.md
3. $PROJECT_ROOT/AGENTS.md
4. $PROJECT_ROOT/CLAUDE.md

You are executing Sprint <SPRINT_NUMBER>: <SPRINT_NAME>.

<SPRINT_DEFINITION>

ENTRY CRITERIA (verify before starting):
<ENTRY_CRITERIA>

EXIT CRITERIA (verify before declaring done):
<EXIT_CRITERIA>

IMPORTANT:
- Do NOT start the next sprint. Your scope ends after this sprint.
- Do NOT modify EXECUTION_PLAN.md.
- Use xcodebuild (not swift build) for all build and test commands.
- All new types must conform to Sendable where possible (Swift 6 strict concurrency).
- NEVER add @available or #available for older platforms (macOS 26+ and iOS 26+ only).
- After completing all tasks, run the exit criteria commands and report results.
- Commit your work after each task with the specified commit message.
```

---

## Summary

| Metric | Value |
|--------|-------|
| Work units | 8 |
| Total sprints | 21 |
| Total tasks | 157 (atomically sized: 30-120 lines each) |
| Dependency structure | Mostly layered with parallelism in Layer 2 |
| Estimated complexity | Medium |
| Parallelism | Layer 2: Core API ∥ Search & Fuzzy (Sprints 3-5 ∥ Sprints 6-7) |

### Execution Order

```
Phase 1 — Foundation (sequential):
    Sprint 1: Package & errors (4 tasks)
    Sprint 2: Data structures (7 tasks)

Phase 2 — PARALLEL EXECUTION (both branches start after Phase 1):

    Branch A — Core API (16 tasks):               Branch B — Search & Fuzzy (8 tasks):
    ├─ Sprint 3: Paths & availability (8)          ├─ Sprint 6: Levenshtein (2)
    ├─ Sprint 4: Discovery (6)                     └─ Sprint 7: Fuzzy search (6) ← needs Sprint 5
    └─ Sprint 5: Pattern matching (2)

    Note: Sprint 7 needs Sprint 5 to complete (uses Core API)

Phase 3 — PARALLEL EXECUTION (both start after Core API completes):

    Branch C — Download (16 tasks):                Branch D — Migration (6 tasks):
    ├─ Sprint 8: Download infrastructure (6)        └─ Sprint 13: Legacy paths (6)
    ├─ Sprint 9: Progress tracking (5)
    └─ Sprint 10: Public API (5)

Phase 4 — Thread Safety (waits for Download):
    Sprint 11: Actor manager (6 tasks)
    Sprint 12: Cache & statistics (6 tasks)

Phase 5 — Testing (waits for all previous):
    Sprint 14: Integration tests (7 tasks)
    Sprint 15: Edge case tests (3 tasks)
    Sprint 16: Error & concurrency tests (2 tasks)
    Sprint 17: Fixtures & docs (4 tasks)
    Sprint 18: Final validation (4 tasks)

Phase 6 — CI/CD & Docs (waits for Phase 5):
    Sprint 19: GitHub Actions (5 tasks)
    Sprint 20: README core (4 tasks)
    Sprint 21: README integration & contributing (6 tasks)
```

### Critical Path

**Longest path (sequential execution):**

```
Sprint 1 → Sprint 2 → Sprint 3 → Sprint 4 → Sprint 5 → Sprint 8 → Sprint 9 → Sprint 10
→ Sprint 11 → Sprint 12 → Sprint 14 → Sprint 15 → Sprint 16 → Sprint 17 → Sprint 18
→ Sprint 19 → Sprint 20 → Sprint 21
```

**Supervisor Behavior**:
- After Sprint 2: Launch Sprint 3 AND Sprint 6 in parallel (Layer 2)
- Sprint 5 completes before Sprint 7 needs it
- Branch A (Sprints 3-5) is longer than Branch B (Sprints 6-7)
- After Sprint 5 (Core API complete): Launch Sprint 8 AND Sprint 13 in parallel (Layer 3)
- Sprint 13 (Migration) runs entirely parallel with Sprints 8-10 (Download)
- Sprint 11 waits for Sprint 10 (Download complete), NOT for Sprint 13
- Best parallelization: 3 parallel dispatch points (Layers 2, 3, and Migration completes before Download)

---

## Appendix A: Model ID Validation

Model IDs must contain exactly one "/" to separate org from repo:
- ✅ Valid: "mlx-community/Qwen2.5-7B-Instruct-4bit"
- ❌ Invalid: "Qwen2.5-7B-Instruct-4bit" (no slash)
- ❌ Invalid: "mlx-community/models/Qwen2.5" (multiple slashes)

---

## Appendix B: Canonical Path Structure

```
~/Library/SharedModels/
├── mlx-community_Qwen2.5-7B-Instruct-4bit/
│   ├── config.json                 ← Validity marker
│   ├── tokenizer.json
│   ├── tokenizer_config.json
│   └── model.safetensors
├── mlx-community_Qwen3-TTS-12Hz-1.7B-Base-bf16/
│   ├── config.json
│   └── speech_tokenizer/           ← Subdirectory support
│       ├── config.json
│       └── model.safetensors
└── mlx-community_Phi-3-mini-4k-instruct-4bit/
    ├── config.json
    └── ...
```

**Key facts**:
- Base: `~/Library/SharedModels/` (persistent, not in Caches)
- Slug: Replace "/" with "_" in HuggingFace ID
- Validity: `config.json` presence is the universal marker
- Subdirectories: Supported for complex models (e.g., speech_tokenizer/)

---

## Appendix C: Suffix Stripping for Base Names

Base name extraction strips these suffixes:
- **Quantization**: `-4bit`, `-8bit`, `-bf16`, `-fp16`
- **Size**: `-0.6B`, `-1.7B`, `-7B`, `-8B`, `-70B`
- **Variant**: `-Base`, `-Instruct`, `-VoiceDesign`, `-CustomVoice`

Examples:
- `"mlx-community/Qwen2.5-7B-Instruct-4bit"` → base: `"Qwen2.5"`, family: `"mlx-community/Qwen2.5"`
- `"mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"` → base: `"Qwen3-TTS-12Hz"`, family: `"mlx-community/Qwen3-TTS-12Hz"`
- `"mlx-community/Phi-3-mini-4k-instruct-4bit"` → base: `"Phi-3-mini-4k"`, family: `"mlx-community/Phi-3-mini-4k"`

---

## Appendix D: HuggingFace URL Format

```
https://huggingface.co/{modelId}/resolve/main/{fileName}
```

Examples:
- `https://huggingface.co/mlx-community/Qwen2.5-7B-Instruct-4bit/resolve/main/config.json`
- `https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16/resolve/main/speech_tokenizer/config.json`

**Auth header** (for gated models):
```
Authorization: Bearer hf_xxxxxxxxxxxxxxxxxxxxx
```

---

## Appendix E: Legacy Paths

These legacy paths are scanned during migration:
```
~/Library/Caches/intrusive-memory/Models/LLM/
~/Library/Caches/intrusive-memory/Models/TTS/
~/Library/Caches/intrusive-memory/Models/Audio/
~/Library/Caches/intrusive-memory/Models/VLM/
```

Migration behavior:
- Scan for subdirectories with `config.json`
- Move to `~/Library/SharedModels/{slug}/` if not already there
- Skip if destination exists (prefer existing copy)
- Do NOT delete old parent directories
- Return list of migrated models
