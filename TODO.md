# SwiftAcervo TODO: Local Path Access API

## Background

SwiftTuberia's `WeightLoader` currently has a `loadFromPath()` method that bypasses Acervo entirely — it calls `FileManager.fileExists()` and constructs `URL(fileURLWithPath:)` directly. This is a layering violation: **Acervo owns all interaction with model files on disk; Tuberia should never touch the filesystem directly.**

The fix requires a new API in `AcervoManager` that provides the same scoped-access guarantee as `withComponentAccess`, but for caller-provided local URLs (e.g., LoRA adapter files) that are not registered in the component registry.

---

## What to Add

### 1. `AcervoManager.withLocalAccess(_:perform:)`

Add a new public method to `AcervoManager` that accepts a caller-provided `URL` pointing to a local directory or file, validates it exists, and provides a `LocalHandle` (or reuses `ComponentHandle` with a synthetic descriptor) for scoped access.

**Proposed signature** (adjust naming to match Acervo conventions):

```swift
/// Provides scoped access to a caller-supplied local directory or file that
/// is not registered in the Acervo component registry.
///
/// Use this when the caller holds a URL to a local adapter or weight file
/// that Acervo did not download — e.g., a user-supplied LoRA adapter on disk.
/// Acervo validates the path exists and provides an access handle; the caller
/// never needs to touch `FileManager` or construct URLs themselves.
///
/// - Parameters:
///   - url: The local URL to access. Must point to an existing file or directory.
///   - perform: A `@Sendable` closure that receives a `LocalHandle` for
///     path-agnostic file access. The handle is valid only within this closure.
/// - Returns: The value returned by `perform`.
/// - Throws: `AcervoError.localPathNotFound(url:)` if `url` does not exist on disk.
///
/// ```swift
/// let weights = try await AcervoManager.shared.withLocalAccess(loraURL) { handle in
///     let url = try handle.url(matching: ".safetensors")
///     return try loadSafetensors(from: url)
/// }
/// ```
public func withLocalAccess<T: Sendable>(
    _ url: URL,
    perform: @Sendable (LocalHandle) throws -> T
) async throws -> T
```

### 2. `LocalHandle`

A lightweight struct parallel to `ComponentHandle` but backed by a caller-supplied URL rather than a registered descriptor:

```swift
public struct LocalHandle: Sendable {
    /// The resolved root URL (file or directory) provided by the caller.
    public let rootURL: URL

    /// Resolves a file by relative path from the root URL.
    /// Throws `AcervoError.localPathNotFound` if the file does not exist.
    public func url(for relativePath: String) throws -> URL

    /// Resolves the first file under `rootURL` whose path ends with `suffix`.
    /// Searches non-recursively in the root directory.
    /// Throws `AcervoError.localPathNotFound` if no match is found.
    public func url(matching suffix: String) throws -> URL

    /// Lists all files under `rootURL` (non-recursive) matching `suffix`.
    public func urls(matching suffix: String) throws -> [URL]
}
```

If `url` points directly to a single file (not a directory), `url(for:)` should return `rootURL` itself when `relativePath` is empty or `"."`, and `url(matching:)` should check the file's own path suffix.

### 3. New `AcervoError` case

```swift
case localPathNotFound(url: URL)
```

---

## What Changes in SwiftTuberia After This

`WeightLoader.loadFromPath()` (in `Sources/Tuberia/Infrastructure/WeightLoader.swift`, ~line 131) currently:

```swift
// BEFORE (layering violation)
guard FileManager.default.fileExists(atPath: path) else {
    throw WeightLoaderError.pathNotFound(path)
}
let url = URL(fileURLWithPath: path)
// ... parse safetensors from url
```

After this API exists, it becomes:

```swift
// AFTER (Acervo-routed)
let localURL = URL(fileURLWithPath: path)
return try await AcervoManager.shared.withLocalAccess(localURL) { handle in
    let fileURL = try handle.url(matching: ".safetensors")
    // ... parse safetensors from fileURL
}
```

All `FileManager` and path-construction code moves out of Tuberia entirely.

---

## Also Worth Noting

`WeightLoader` has a dev-only `/tmp/vinetas-test-models/` fallback (~lines 59–74 in the same file) gated on `VINETAS_TEST_MODELS_DIR` environment variable. Once `withLocalAccess` exists, this fallback can also be routed through Acervo rather than doing direct `FileManager` lookups — or at minimum it should be clearly documented as a dev-only escape hatch that bypasses registry validation.

---

## Test Requirements

Any implementation of `withLocalAccess` / `LocalHandle` must include tests that cover:

1. `withLocalAccess` with a valid directory URL — closure receives a handle and can resolve files by suffix
2. `withLocalAccess` with a valid single-file URL — `url(matching:)` matches the file's own suffix
3. `withLocalAccess` with a non-existent URL — throws `AcervoError.localPathNotFound`
4. Concurrent calls to `withLocalAccess` with distinct URLs — no data races (Swift 6 `Sendable` check must pass)
