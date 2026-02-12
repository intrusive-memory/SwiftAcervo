# SwiftAcervo Task List

This is an unorganized, unsized list of tasks needed to implement SwiftAcervo v1.0 based on REQUIREMENTS.md.

## Package Structure & Setup

- [ ] Create Package.swift with Swift 6.2 tools version
- [ ] Configure platforms (macOS 26.0+, iOS 26.0+)
- [ ] Set up strict concurrency mode
- [ ] Set up Swift language mode v6
- [ ] Create Sources/SwiftAcervo/ directory structure
- [ ] Create Tests/SwiftAcervoTests/ directory structure
- [ ] Create .github/workflows/ directory
- [ ] Add .gitignore for Swift package

## Core Types & Errors

- [ ] Implement AcervoError enum with all error cases
- [ ] Add LocalizedError conformance to AcervoError
- [ ] Add Sendable conformance to AcervoError
- [ ] Implement AcervoModel struct with all properties
- [ ] Add Identifiable conformance to AcervoModel
- [ ] Add Equatable conformance to AcervoModel
- [ ] Add Codable conformance to AcervoModel
- [ ] Add Sendable conformance to AcervoModel
- [ ] Implement formattedSize computed property
- [ ] Implement slug computed property
- [ ] Implement baseName computed property (strip quantization/size/variant suffixes)
- [ ] Implement familyName computed property
- [ ] Implement AcervoDownloadProgress struct with all properties
- [ ] Add Sendable conformance to AcervoDownloadProgress
- [ ] Implement overallProgress computed property

## Path Handling (Acervo.swift)

- [ ] Implement sharedModelsDirectory static property (~/.Library/SharedModels/)
- [ ] Implement slugify() function (convert "/" to "_")
- [ ] Implement modelDirectory(for:) function
- [ ] Validate model ID format (must contain exactly one "/")
- [ ] Handle edge cases in slugify (empty strings, multiple slashes, etc.)

## Model Discovery

- [ ] Implement listModels() function
- [ ] Scan sharedModelsDirectory for subdirectories
- [ ] Filter directories by presence of config.json
- [ ] Build AcervoModel instances from discovered directories
- [ ] Calculate directory sizes (recursive file enumeration)
- [ ] Extract download dates from directory creation date
- [ ] Implement modelInfo() function for single model lookup
- [ ] Handle modelNotFound error case

## Model Availability

- [ ] Implement isModelAvailable() function
- [ ] Check for config.json presence
- [ ] Implement modelFileExists() function
- [ ] Handle subdirectory file paths

## Pattern Matching & Search

- [ ] Implement findModels(matching:) with case-insensitive substring search
- [ ] Search across full model IDs
- [ ] Return all matching models
- [ ] Implement Levenshtein edit distance algorithm
- [ ] Implement findModels(fuzzyMatching:editDistance:) function
- [ ] Strip common prefixes (mlx-community/) before fuzzy comparison
- [ ] Sort fuzzy results by closeness
- [ ] Implement closestModel(to:editDistance:) function
- [ ] Return best single match or nil
- [ ] Implement modelFamilies() function
- [ ] Group models by base name
- [ ] Return dictionary of family name to model list

## Download Implementation (AcervoDownloader.swift)

- [ ] Implement HuggingFace URL construction
- [ ] Format: https://huggingface.co/{modelId}/resolve/main/{fileName}
- [ ] Implement download() function with file list parameter
- [ ] Implement download() function with optional token parameter
- [ ] Add Authorization: Bearer {token} header when token provided
- [ ] Create model directory with intermediate directories
- [ ] Implement per-file download loop
- [ ] Skip files that already exist (unless force: true)
- [ ] Use URLSession.shared.download(from:)
- [ ] Verify HTTP 200 response
- [ ] Move temporary file to destination (atomic)
- [ ] Handle subdirectory file paths (create intermediate dirs)
- [ ] Implement progress callback
- [ ] Calculate per-file progress
- [ ] Calculate overall progress across all files
- [ ] Track file index in download list
- [ ] Report progress via AcervoDownloadProgress struct
- [ ] Implement ensureAvailable() function
- [ ] Check if model exists before downloading
- [ ] Skip download if available
- [ ] Handle network errors
- [ ] Handle HTTP error codes
- [ ] Implement deleteModel() function
- [ ] Remove entire model directory
- [ ] Validate model exists before deletion

## Thread-Safe Manager (AcervoManager.swift)

- [ ] Implement AcervoManager as actor
- [ ] Add shared singleton instance
- [ ] Implement per-model download lock dictionary
- [ ] Implement download() method with lock serialization
- [ ] Wait loop (50ms sleep) when model is locked
- [ ] Defer lock release
- [ ] Implement withModelAccess() method
- [ ] Provide exclusive access to model directory
- [ ] Prevent concurrent reads/writes to same model
- [ ] Pass URL to closure safely
- [ ] Implement URL cache dictionary
- [ ] Make cache access thread-safe
- [ ] Implement clearCache() method
- [ ] Implement preloadModels() method
- [ ] Cache all model URLs on startup
- [ ] Implement download statistics tracking
- [ ] Implement access count tracking
- [ ] Implement printStatisticsReport() method
- [ ] Ensure all closures are @Sendable

## Migration from Legacy Paths

- [ ] Implement migrateFromLegacyPaths() function
- [ ] Scan ~/Library/Caches/intrusive-memory/Models/LLM/
- [ ] Scan ~/Library/Caches/intrusive-memory/Models/TTS/
- [ ] Scan ~/Library/Caches/intrusive-memory/Models/Audio/
- [ ] Scan ~/Library/Caches/intrusive-memory/Models/VLM/
- [ ] Find subdirectories with config.json
- [ ] Extract slug from directory name
- [ ] Check if destination already exists in SharedModels
- [ ] Move directory if destination does not exist
- [ ] Skip if destination exists
- [ ] Return list of migrated AcervoModel instances
- [ ] Handle migration errors gracefully
- [ ] Do NOT delete old parent directories

## Unit Tests (AcervoTests.swift)

- [ ] Test slugify() with various inputs
- [ ] Test slugify() with edge cases
- [ ] Test modelDirectory(for:) path construction
- [ ] Test sharedModelsDirectory returns correct path
- [ ] Test isModelAvailable() with config.json present
- [ ] Test isModelAvailable() with config.json missing
- [ ] Test modelFileExists() for root files
- [ ] Test modelFileExists() for subdirectory files
- [ ] Test listModels() with empty directory
- [ ] Test listModels() with multiple models
- [ ] Test listModels() filters out directories without config.json
- [ ] Test modelInfo() returns correct metadata
- [ ] Test modelInfo() throws modelNotFound for missing model
- [ ] Test findModels(matching:) with exact substring
- [ ] Test findModels(matching:) case insensitivity
- [ ] Test findModels(matching:) returns all matches
- [ ] Test invalid model ID error (no slash)
- [ ] Test invalid model ID error (multiple slashes)
- [ ] Test AcervoModel formattedSize property
- [ ] Test AcervoModel slug property
- [ ] Test AcervoModel baseName property
- [ ] Test AcervoModel familyName property

## Fuzzy Search Tests

- [ ] Test Levenshtein edit distance implementation
- [ ] Test findModels(fuzzyMatching:) with close matches
- [ ] Test findModels(fuzzyMatching:) respects edit distance threshold
- [ ] Test findModels(fuzzyMatching:) strips prefixes
- [ ] Test findModels(fuzzyMatching:) sorts by closeness
- [ ] Test closestModel(to:) returns best match
- [ ] Test closestModel(to:) returns nil when no match within threshold
- [ ] Test modelFamilies() groups by base name
- [ ] Test base name stripping of quantization suffixes (-4bit, -8bit, -bf16, -fp16)
- [ ] Test base name stripping of size suffixes (-0.6B, -1.7B, -7B)
- [ ] Test base name stripping of variant suffixes (-Base, -Instruct, -VoiceDesign, -CustomVoice)

## Download Tests (AcervoDownloaderTests.swift)

- [ ] Test HuggingFace URL construction
- [ ] Test URL construction with subdirectory files
- [ ] Test progress calculation for single file
- [ ] Test progress calculation for multiple files
- [ ] Test overallProgress computation
- [ ] Test formattedProgress string generation
- [ ] Test file index tracking
- [ ] Test skip-if-exists logic
- [ ] Test force: true re-downloads existing files

## Manager Tests (AcervoManagerTests.swift)

- [ ] Test per-model lock serialization
- [ ] Test concurrent downloads of different models proceed in parallel
- [ ] Test concurrent downloads of same model are serialized
- [ ] Test withModelAccess() provides exclusive access
- [ ] Test lock release on error
- [ ] Test URL cache correctness
- [ ] Test clearCache() empties cache
- [ ] Test preloadModels() populates cache
- [ ] Test download statistics tracking
- [ ] Test access count tracking
- [ ] Test printStatisticsReport() output

## Migration Tests

- [ ] Test migrateFromLegacyPaths() with empty legacy directories
- [ ] Test migrateFromLegacyPaths() moves valid models
- [ ] Test migrateFromLegacyPaths() skips models already in SharedModels
- [ ] Test migrateFromLegacyPaths() handles missing config.json
- [ ] Test migrateFromLegacyPaths() returns correct AcervoModel list
- [ ] Test migration error handling

## Integration Tests (Tagged, Network Required)

- [ ] Test download of real config.json from HuggingFace
- [ ] Verify file lands at correct path
- [ ] Test ensureAvailable() skips existing models
- [ ] Test force: true re-downloads
- [ ] Test auth token header is sent when provided
- [ ] Test subdirectory file download
- [ ] Test error on HTTP 404
- [ ] Test error on HTTP 403 (auth required)
- [ ] Test error on network timeout

## CI/CD Setup

- [ ] Create .github/workflows/tests.yml
- [ ] Configure workflow to run on pull_request to main and development
- [ ] Add concurrency group to cancel in-progress runs
- [ ] Configure macos-26 runner
- [ ] Add checkout step
- [ ] Add Swift version display step
- [ ] Add xcodebuild build step for macOS
- [ ] Add xcodebuild test step for macOS
- [ ] Add xcodebuild build step for iOS Simulator
- [ ] Add xcodebuild test step for iOS Simulator
- [ ] Use correct iOS Simulator destination string (iPhone 17, OS=26.1)
- [ ] Configure branch protection rules
- [ ] Require CI to pass before merging
- [ ] Set required status checks to match workflow job names

## Documentation

- [ ] Update README.md with usage examples
- [ ] Document all public API methods
- [ ] Add inline code documentation
- [ ] Document error cases
- [ ] Document thread safety guarantees
- [ ] Add migration guide for consumers
- [ ] Document HuggingFace auth token usage
- [ ] Document subdirectory file downloads
- [ ] Add examples for SwiftBruja integration
- [ ] Add examples for mlx-audio-swift integration
- [ ] Add examples for SwiftVoxAlta integration
- [ ] Add examples for Produciesta integration

## Final Validation

- [ ] Verify zero external dependencies
- [ ] Verify platforms are macOS 26.0+ and iOS 26.0+ only
- [ ] Verify no @available attributes for older platforms
- [ ] Verify no #available checks for older platforms
- [ ] Verify strict concurrency enabled
- [ ] Verify Swift 6 language mode
- [ ] Run all tests on macOS
- [ ] Run all tests on iOS Simulator
- [ ] Verify CI passes
- [ ] Manual smoke test: Download a real model
- [ ] Manual smoke test: List models
- [ ] Manual smoke test: Fuzzy search
- [ ] Manual smoke test: Migration from legacy paths
- [ ] Manual smoke test: Delete model
- [ ] Code review for security issues
- [ ] Check for command injection vulnerabilities
- [ ] Check for path traversal vulnerabilities
- [ ] Verify auth token is not logged or printed
