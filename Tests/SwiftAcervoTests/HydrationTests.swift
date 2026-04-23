import Foundation
import Testing

@testable import SwiftAcervo

extension MockURLProtocolSuite {

  /// The canonical 7 hydration tests enumerated in `docs/complete/hydration_todo.md`
  /// § Tests to Add (Sortie 6 of OPERATION DESERT BLUEPRINT). Nested under
  /// `MockURLProtocolSuite` so every test inherits the parent's `.serialized`
  /// trait — required because `MockURLProtocol` uses process-wide static
  /// storage that cannot be raced by sibling test suites.
  ///
  /// Overlap note: Tests 3, 5, and 7 have precedents in `HydrateComponentTests`
  /// (Sortie 3) and `AutoHydrateTests` (Sortie 4). The "canonical 7" is the
  /// deliverable per EXECUTION_PLAN.md; duplicates are intentional.
  @Suite("Canonical Hydration Tests")
  struct HydrationTests {

    // MARK: - Shared helpers

    /// Returns fresh (modelId, componentId) pair. UUID-suffixed so parallel
    /// test shards don't collide on registry IDs.
    private static func uniqueIds() -> (modelId: String, componentId: String) {
      let uid = UUID().uuidString.prefix(8)
      return (
        modelId: "hydration-test/repo-\(uid)",
        componentId: "hydration-comp-\(uid)"
      )
    }

    /// Creates a fresh empty temporary directory.
    private static func makeTempDir() throws -> URL {
      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("HydrationTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      return dir
    }

    private static func removeTempDir(_ dir: URL) {
      try? FileManager.default.removeItem(at: dir)
    }

    private static func makeBareDescriptor(id: String, repoId: String) -> ComponentDescriptor {
      ComponentDescriptor(
        id: id,
        type: .backbone,
        displayName: "Hydration Test",
        repoId: repoId,
        minimumMemoryBytes: 0
      )
    }

    /// Builds a valid 2-file manifest. `sizeBytes: 0` so the on-disk file
    /// fixtures can be empty and still satisfy readiness checks.
    private static func makeTwoFileManifest(
      modelId: String,
      paths: [String] = ["config.json", "model.safetensors"]
    ) -> CDNManifest {
      let files = paths.enumerated().map { (idx, path) in
        CDNManifestFile(
          path: path,
          sha256: String(repeating: "0", count: 63) + String(idx + 1),
          sizeBytes: 0
        )
      }
      let slug = modelId.replacingOccurrences(of: "/", with: "_")
      return CDNManifest(
        manifestVersion: CDNManifest.supportedVersion,
        modelId: modelId,
        slug: slug,
        updatedAt: "2026-04-22T00:00:00Z",
        files: files,
        manifestChecksum: CDNManifest.computeChecksum(from: files.map(\.sha256))
      )
    }

    private static func stubManifest(_ manifest: CDNManifest) throws {
      let encoded = try JSONEncoder().encode(manifest)
      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        )!
        return (response, encoded)
      }
    }

    /// Writes zero-byte files on disk for every file in the hydrated descriptor
    /// so `isComponentReady` succeeds (our manifests declare `sizeBytes: 0` and
    /// `sha256` digests that `isComponentReady` does not re-verify; verification
    /// happens in `downloadComponent`).
    private static func createFilesOnDisk(
      for descriptor: ComponentDescriptor,
      in baseDirectory: URL
    ) throws {
      let slug = Acervo.slugify(descriptor.repoId)
      let componentDir = baseDirectory.appendingPathComponent(slug)
      let fm = FileManager.default
      for file in descriptor.files {
        let fileURL = componentDir.appendingPathComponent(file.relativePath)
        try fm.createDirectory(
          at: fileURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        let content: Data
        if let size = file.expectedSizeBytes {
          content = size > 0 ? Data(repeating: 0x42, count: Int(size)) : Data()
        } else {
          content = Data()
        }
        try content.write(to: fileURL)
      }
    }

    // MARK: - Test 1: Register-without-files round trip

    /// Registers a bare descriptor (no `files:`), stubs a 2-file manifest,
    /// hydrates via the session-injectable internal overload, stages the
    /// declared files on disk, then calls `ensureComponentReady` and asserts
    /// it completes without error. This exercises the end-to-end
    /// bare-descriptor → hydrated → ready path.
    ///
    /// Practical note: `downloadComponent` uses a non-injectable CDN session
    /// for file bodies, so we pre-stage the files on disk to bypass that
    /// code path. The intent (bare round-trip produces a working component)
    /// is preserved.
    @Test("Register-without-files round trip hydrates and reports ready")
    func registerWithoutFilesRoundTrip() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let tempDir = try Self.makeTempDir()
      defer { Self.removeTempDir(tempDir) }

      let (modelId, componentId) = Self.uniqueIds()
      let bare = Self.makeBareDescriptor(id: componentId, repoId: modelId)
      Acervo.register(bare)
      defer { Acervo.unregister(componentId) }

      // Precondition: bare descriptor is not hydrated.
      #expect(ComponentRegistry.shared.component(componentId)?.isHydrated == false)

      let manifest = Self.makeTwoFileManifest(modelId: modelId)
      try Self.stubManifest(manifest)

      // Hydrate via the session-injectable overload (stubs the manifest fetch).
      try await Acervo.hydrateComponent(componentId, session: MockURLProtocol.session())

      let hydrated = try #require(ComponentRegistry.shared.component(componentId))
      #expect(hydrated.isHydrated == true)
      #expect(hydrated.files.count == 2)
      #expect(hydrated.files.map(\.relativePath) == ["config.json", "model.safetensors"])

      // Stage files on disk so `ensureComponentReady` sees an already-ready component.
      try Self.createFilesOnDisk(for: hydrated, in: tempDir)

      // `ensureComponentReady` with a hydrated descriptor + files present = no-op.
      try await Acervo.ensureComponentReady(componentId, in: tempDir)

      // Post-conditions: descriptor still hydrated, files still match the stubbed manifest.
      let final = try #require(ComponentRegistry.shared.component(componentId))
      #expect(final.isHydrated == true)
      #expect(final.files.map(\.relativePath) == ["config.json", "model.safetensors"])
      #expect(Acervo.isComponentReady(componentId, in: tempDir) == true)
    }

    // MARK: - Test 2: Hydration picks up manifest drift (and warning is logged)

    /// Registers a descriptor with a stale declared `files: [old.bin]` list,
    /// stubs the manifest to return a different list (`[new.bin, other.bin]`),
    /// calls `hydrateComponent`, and asserts:
    ///   - registry now holds the manifest's file list (Replace semantics per Blocker 1).
    ///   - the drift warning was emitted to stderr (captured via `dup2` + `Pipe`).
    @Test("Hydration replaces declared files with manifest and logs drift warning")
    func hydrationPicksUpManifestDrift() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let (modelId, componentId) = Self.uniqueIds()

      // Declared descriptor: one file, "old.bin".
      let declared = ComponentDescriptor(
        id: componentId,
        type: .backbone,
        displayName: "Drift Test",
        repoId: modelId,
        files: [ComponentFile(relativePath: "old.bin")],
        estimatedSizeBytes: 100,
        minimumMemoryBytes: 0
      )
      Acervo.register(declared)
      defer { Acervo.unregister(componentId) }

      // Sanity: descriptor is already hydrated via declared init.
      let beforeHydrate = try #require(ComponentRegistry.shared.component(componentId))
      #expect(beforeHydrate.isHydrated == true)
      #expect(beforeHydrate.files.map(\.relativePath) == ["old.bin"])

      // Manifest returns two different files.
      let manifest = Self.makeTwoFileManifest(
        modelId: modelId,
        paths: ["new.bin", "other.bin"]
      )
      try Self.stubManifest(manifest)

      // Capture stderr via dup2 + Pipe while hydration runs. The drift warning
      // is emitted with `FileHandle.standardError.write` in Acervo.swift.
      let savedStderr = dup(STDERR_FILENO)
      #expect(savedStderr >= 0)
      let pipe = Pipe()
      dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

      // Drain the read end asynchronously so the write-side never blocks on a full pipe buffer.
      let collector = StderrCollector()
      let readHandle = pipe.fileHandleForReading
      readHandle.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty {
          handle.readabilityHandler = nil
        } else {
          collector.append(chunk)
        }
      }

      do {
        try await Acervo.hydrateComponent(componentId, session: MockURLProtocol.session())
      } catch {
        // Restore stderr before rethrowing so test output isn't captured.
        dup2(savedStderr, STDERR_FILENO)
        close(savedStderr)
        readHandle.readabilityHandler = nil
        try? pipe.fileHandleForWriting.close()
        throw error
      }

      // Flush & restore stderr.
      try? pipe.fileHandleForWriting.close()
      // Give the readabilityHandler a moment to drain the remaining bytes.
      try? await Task.sleep(for: .milliseconds(50))
      readHandle.readabilityHandler = nil
      dup2(savedStderr, STDERR_FILENO)
      close(savedStderr)

      // Primary assertion: registry replaced, not merged (Blocker 1 "replace" semantics).
      let hydrated = try #require(ComponentRegistry.shared.component(componentId))
      #expect(hydrated.files.count == 2)
      #expect(hydrated.files.map(\.relativePath) == ["new.bin", "other.bin"])
      #expect(hydrated.files.contains { $0.relativePath == "old.bin" } == false)

      // Log assertion: drift warning is present in captured stderr.
      let captured = collector.stringValue()
      #expect(
        captured.contains("Manifest drift detected for"),
        "Expected drift warning in stderr. Captured: \(captured)"
      )
    }

    // MARK: - Test 3: `isHydrated` transitions

    /// Bare descriptor starts un-hydrated; after `hydrateComponent` it is hydrated.
    @Test("isHydrated transitions from false to true after hydrateComponent")
    func isHydratedTransitions() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let (modelId, componentId) = Self.uniqueIds()
      let bare = Self.makeBareDescriptor(id: componentId, repoId: modelId)
      Acervo.register(bare)
      defer { Acervo.unregister(componentId) }

      // Before: not hydrated.
      #expect(ComponentRegistry.shared.component(componentId)?.isHydrated == false)
      #expect(ComponentRegistry.shared.component(componentId)?.needsHydration == true)

      let manifest = Self.makeTwoFileManifest(modelId: modelId)
      try Self.stubManifest(manifest)

      try await Acervo.hydrateComponent(componentId, session: MockURLProtocol.session())

      // After: hydrated.
      #expect(ComponentRegistry.shared.component(componentId)?.isHydrated == true)
      #expect(ComponentRegistry.shared.component(componentId)?.needsHydration == false)
    }

    // MARK: - Test 4: Manifest 404 on hydration

    /// Stubs a 404 response for the manifest URL. `hydrateComponent` must
    /// throw `AcervoError.manifestDownloadFailed(statusCode: 404)` and the
    /// registry descriptor must remain un-hydrated (no partial state).
    @Test("Manifest 404 throws manifestDownloadFailed and leaves registry un-hydrated")
    func manifest404OnHydration() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let (modelId, componentId) = Self.uniqueIds()
      let bare = Self.makeBareDescriptor(id: componentId, repoId: modelId)
      Acervo.register(bare)
      defer { Acervo.unregister(componentId) }

      // Stub responder with an HTTP 404.
      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 404,
          httpVersion: "HTTP/1.1",
          headerFields: nil
        )!
        return (response, Data())
      }

      do {
        try await Acervo.hydrateComponent(componentId, session: MockURLProtocol.session())
        Issue.record("Expected manifestDownloadFailed(statusCode: 404) to be thrown")
      } catch let error as AcervoError {
        switch error {
        case .manifestDownloadFailed(let statusCode):
          #expect(statusCode == 404)
        default:
          Issue.record("Expected .manifestDownloadFailed, got \(error)")
        }
      }

      // No partial state leaked into the registry.
      let current = try #require(ComponentRegistry.shared.component(componentId))
      #expect(current.isHydrated == false)
      #expect(current.needsHydration == true)
    }

    // MARK: - Test 5: Concurrent hydration (single-flight)

    /// Launches 10 concurrent `hydrateComponent` calls for the same ID. The
    /// stubbed responder sleeps ~100ms before returning, keeping the fetch
    /// open long enough for all 10 tasks to race on the coalescer. Exactly
    /// one HTTP request should be issued; all 10 tasks complete.
    ///
    /// Overlap note: `HydrateComponentTests.concurrentHydrationCoalesces`
    /// covers the same scenario. Re-asserted here as part of the canonical 7.
    @Test("10 concurrent hydrateComponent calls coalesce into one network fetch")
    func concurrentHydration() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let (modelId, componentId) = Self.uniqueIds()
      let bare = Self.makeBareDescriptor(id: componentId, repoId: modelId)
      Acervo.register(bare)
      defer { Acervo.unregister(componentId) }

      let manifest = Self.makeTwoFileManifest(modelId: modelId)
      let encoded = try JSONEncoder().encode(manifest)

      // Responder is @Sendable + synchronous. The only way to inject delay is
      // `Thread.sleep`, which blocks the URLSession loading thread (NOT the
      // Swift Testing async context). This is the same proven pattern used by
      // HydrateComponentTests.concurrentHydrationCoalesces.
      MockURLProtocol.responder = { request in
        Thread.sleep(forTimeInterval: 0.1)
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        )!
        return (response, encoded)
      }

      let session = MockURLProtocol.session()

      try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<10 {
          group.addTask {
            try await Acervo.hydrateComponent(componentId, session: session)
          }
        }
        try await group.waitForAll()
      }

      // Single-flight: exactly one HTTP request.
      #expect(MockURLProtocol.requestCount == 1)

      let hydrated = try #require(ComponentRegistry.shared.component(componentId))
      #expect(hydrated.isHydrated == true)
      #expect(hydrated.files.count == 2)
    }

    // MARK: - Test 6: Manifest ID mismatch

    /// Register `foo/bar-<uuid>`, stub a manifest whose `modelId` is `baz/qux-<uuid>`.
    /// `hydrateComponent` must throw `AcervoError.manifestModelIdMismatch(expected:actual:)`
    /// with the expected/actual strings populated; the registry must still hold the
    /// original un-hydrated descriptor (unchanged).
    @Test("Manifest modelId mismatch throws and leaves registry unchanged")
    func manifestIdMismatch() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let uid = UUID().uuidString.prefix(8)
      let componentId = "hydration-mismatch-\(uid)"
      let expectedModelId = "foo/bar-\(uid)"
      let wrongModelId = "baz/qux-\(uid)"

      let bare = Self.makeBareDescriptor(id: componentId, repoId: expectedModelId)
      Acervo.register(bare)
      defer { Acervo.unregister(componentId) }

      // Manifest claims the wrong modelId.
      let manifest = Self.makeTwoFileManifest(modelId: wrongModelId)
      try Self.stubManifest(manifest)

      do {
        try await Acervo.hydrateComponent(componentId, session: MockURLProtocol.session())
        Issue.record("Expected manifestModelIdMismatch to be thrown")
      } catch let error as AcervoError {
        switch error {
        case .manifestModelIdMismatch(let expected, let actual):
          #expect(expected == expectedModelId)
          #expect(actual == wrongModelId)
        default:
          Issue.record("Expected .manifestModelIdMismatch, got \(error)")
        }
      }

      // Registry still holds the original un-hydrated descriptor.
      let current = try #require(ComponentRegistry.shared.component(componentId))
      #expect(current.isHydrated == false)
      #expect(current.repoId == expectedModelId)
      #expect(current.id == componentId)
    }

    // MARK: - Test 7: Backwards compatibility — no hydration for declared descriptors

    /// A descriptor registered WITH declared `files:` is already hydrated;
    /// `ensureComponentReady` must NOT trigger a manifest network fetch.
    /// The stubbed responder is booby-trapped to fail loudly (HTTP 418) so
    /// any unintended request is detected.
    ///
    /// Overlap note: `AutoHydrateTests.preDeclaredDescriptorBackwardsCompat`
    /// asserts the same property. Re-asserted here as part of the canonical 7.
    @Test("Pre-declared descriptor does not trigger a manifest fetch")
    func backwardsCompatibilityNoHydrationForDeclared() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let tempDir = try Self.makeTempDir()
      defer { Self.removeTempDir(tempDir) }

      let uid = UUID().uuidString.prefix(8)
      let componentId = "declared-compat-\(uid)"
      let modelId = "compat-org/repo-\(uid)"

      let declared = ComponentDescriptor(
        id: componentId,
        type: .backbone,
        displayName: "Declared Compat",
        repoId: modelId,
        files: [
          ComponentFile(relativePath: "config.json"),
          ComponentFile(relativePath: "model.safetensors"),
        ],
        estimatedSizeBytes: 100,
        minimumMemoryBytes: 0
      )
      Acervo.register(declared)
      defer { Acervo.unregister(componentId) }

      // Booby trap: any network call returns 418 "I'm a teapot". If the
      // declared path accidentally triggers a manifest fetch, the test
      // captures it both via requestCount and (likely) a thrown error.
      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 418,
          httpVersion: "HTTP/1.1",
          headerFields: nil
        )!
        return (response, Data())
      }

      // Sanity: descriptor is already hydrated.
      #expect(ComponentRegistry.shared.component(componentId)?.isHydrated == true)

      // Pre-stage files on disk so `isComponentReady` succeeds.
      try Self.createFilesOnDisk(for: declared, in: tempDir)

      // Call `ensureComponentReady`. Because the descriptor is declared (already
      // hydrated) and files are present on disk, this should NOT hit the network.
      try await Acervo.ensureComponentReady(componentId, in: tempDir)

      // Zero network requests for the manifest (or anything else).
      #expect(MockURLProtocol.requestCount == 0)
      #expect(Acervo.isComponentReady(componentId, in: tempDir) == true)
    }

    // MARK: - Sortie 6: HydrationCoalescer error-path and re-fetch tests

    // MARK: - Test 8: Error-then-success re-fetch after failed hydration

    /// Registers a bare descriptor. Configures the responder to return HTTP 500
    /// on the first call and HTTP 200 (with a valid manifest) on the second call.
    /// Invokes `hydrateComponent` twice sequentially (awaiting the first before
    /// starting the second). Asserts:
    ///   - First call throws an error (from the 500 status).
    ///   - Second call succeeds (200 response yields a hydrated descriptor).
    ///   - `MockURLProtocol.requestCount == 2` (two separate network calls, not coalesced).
    ///
    /// This proves the coalescer does not poison its state on error; a failed
    /// hydration does not prevent a subsequent hydration from proceeding.
    @Test("Error-then-success re-fetch proves coalescer resets after error")
    func errorThenSuccessReFetch() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let (modelId, componentId) = Self.uniqueIds()
      let bare = Self.makeBareDescriptor(id: componentId, repoId: modelId)
      Acervo.register(bare)
      defer { Acervo.unregister(componentId) }

      let manifest = Self.makeTwoFileManifest(modelId: modelId)
      let encoded = try JSONEncoder().encode(manifest)

      // Thread-safe counter: first call returns 500, second returns 200 with manifest.
      let callCounter = CallCounter()

      // Counter-based responder: first call returns 500, second returns 200 with manifest.
      MockURLProtocol.responder = { request in
        let count = callCounter.increment()
        if count == 1 {
          let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 500,
            httpVersion: "HTTP/1.1",
            headerFields: nil
          )!
          return (response, Data())
        } else {
          let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
          )!
          return (response, encoded)
        }
      }

      let session = MockURLProtocol.session()

      // First call: expect it to throw.
      var firstThrew = false
      do {
        try await Acervo.hydrateComponent(componentId, session: session)
      } catch let error as AcervoError {
        switch error {
        case .manifestDownloadFailed(let statusCode):
          #expect(statusCode == 500)
          firstThrew = true
        default:
          Issue.record("Expected manifestDownloadFailed(statusCode: 500), got \(error)")
        }
      }
      #expect(firstThrew, "First hydration should have thrown manifestDownloadFailed")

      // Descriptor must still be unhydrated after the failed attempt.
      #expect(ComponentRegistry.shared.component(componentId)?.isHydrated == false)

      // Second call: should succeed (the responder now returns 200).
      try await Acervo.hydrateComponent(componentId, session: session)

      // Descriptor must now be hydrated.
      let hydrated = try #require(ComponentRegistry.shared.component(componentId))
      #expect(hydrated.isHydrated == true)
      #expect(hydrated.files.count == 2)

      // Critical assertion: two separate network calls (not coalesced after error).
      #expect(MockURLProtocol.requestCount == 2)
    }

    // MARK: - Test 9: Sequential re-fetch after completion

    /// Registers a bare descriptor. Configures the responder to return HTTP 200
    /// (with a valid manifest) on all calls. Invokes `hydrateComponent` twice
    /// sequentially (awaiting the first before starting the second). Asserts:
    ///   - Both calls succeed.
    ///   - `MockURLProtocol.requestCount == 2` (two separate network calls).
    ///
    /// This proves that after a completed hydration, the coalescer does NOT cache
    /// the result. A subsequent hydration for the same ID actually goes to the wire
    /// again. This is distinct from the existing single-flight coalesce test (which
    /// proves concurrent calls share one inflight task). Here we prove that once
    /// inflight is cleared (after completion), the next call for the same ID will
    /// create a fresh task.
    @Test("Sequential post-completion re-fetch goes to the wire again")
    func sequentialReFetchAfterCompletion() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let (modelId, componentId) = Self.uniqueIds()
      let bare = Self.makeBareDescriptor(id: componentId, repoId: modelId)
      Acervo.register(bare)
      defer { Acervo.unregister(componentId) }

      let manifest = Self.makeTwoFileManifest(modelId: modelId)
      let encoded = try JSONEncoder().encode(manifest)

      // Simple responder: always returns 200 with the same manifest.
      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        )!
        return (response, encoded)
      }

      let session = MockURLProtocol.session()

      // First hydration: should succeed.
      try await Acervo.hydrateComponent(componentId, session: session)
      let first = try #require(ComponentRegistry.shared.component(componentId))
      #expect(first.isHydrated == true)

      // Second hydration: also succeeds (same ID, but inflight was cleared after the first).
      try await Acervo.hydrateComponent(componentId, session: session)
      let second = try #require(ComponentRegistry.shared.component(componentId))
      #expect(second.isHydrated == true)

      // Critical assertion: two separate network calls (not coalesced after completion).
      #expect(MockURLProtocol.requestCount == 2)
    }
  }
}

/// Thread-safe accumulator for captured stderr bytes. Used in Test 2 to
/// assemble the drift-warning log line across multiple pipe-read callbacks.
private final class StderrCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = Data()

  func append(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    buffer.append(data)
  }

  func stringValue() -> String {
    lock.lock()
    defer { lock.unlock() }
    return String(data: buffer, encoding: .utf8) ?? ""
  }
}

/// Thread-safe counter for tracking responder calls. Used in Sortie 6 tests
/// to implement multi-response behavior (e.g., 500 then 200).
private final class CallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count: Int = 0

  func increment() -> Int {
    lock.lock()
    defer { lock.unlock() }
    count += 1
    return count
  }
}
