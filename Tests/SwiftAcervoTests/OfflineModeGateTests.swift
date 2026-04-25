import Foundation
import Testing

@testable import SwiftAcervo

extension SharedStaticStateSuite {

  /// Tests for the `ACERVO_OFFLINE=1` environment-variable gate added in
  /// SwiftAcervo 0.8.1.
  ///
  /// The gate is global process state (an environment variable read on every
  /// access via `Acervo.isOfflineModeActive`). Nested under
  /// `SharedStaticStateSuite` (`.serialized`) so the env-var write window
  /// inside `withOfflineModeActive` cannot race against any other test that
  /// reads the gate via the download path. The grandparent serializes
  /// against the MockURLProtocol- and customBaseDirectory-extending suites
  /// that contain almost every download-path test in the project.
  @Suite("Offline Mode Gate")
  struct OfflineModeGateTests {

    // MARK: - Env-var helpers

    private static let envVar = "ACERVO_OFFLINE"

    /// Sets `ACERVO_OFFLINE=1` for the duration of the closure and restores the
    /// prior value (or unsets it) afterwards. Mirrors the `setenv`/`unsetenv`
    /// pattern used in `AcervoToolTests/DownloadCommandTests`.
    private static func withOfflineModeActive<T>(
      _ body: () async throws -> T
    ) async rethrows -> T {
      let prior = ProcessInfo.processInfo.environment[envVar]
      setenv(envVar, "1", 1)
      defer {
        if let prior {
          setenv(envVar, prior, 1)
        } else {
          unsetenv(envVar)
        }
      }
      return try await body()
    }

    // MARK: - Test A: gate trips on manifest fetch

    /// With `ACERVO_OFFLINE=1` set, `AcervoDownloader.downloadManifest` must
    /// throw `AcervoError.offlineModeActive` BEFORE invoking the URLSession.
    /// We pass a session whose `URLProtocol` would fail any real request, so
    /// the only way this test passes is if the gate short-circuits the call.
    @Test("Manifest fetch throws offlineModeActive when ACERVO_OFFLINE=1")
    func manifestFetchTrips() async throws {
      try await Self.withOfflineModeActive {
        // Sanity check: the gate is observable from inside the closure.
        #expect(Acervo.isOfflineModeActive == true)

        // A vanilla ephemeral session — if the gate fails to fire, the test
        // would reach out to `pub-8e049ed02be340cbb18f921765fd24f3.r2.dev`
        // for the manifest. We DO NOT want that to happen, which is precisely
        // what the gate is supposed to prevent.
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        do {
          _ = try await AcervoDownloader.downloadManifest(
            for: "offline-test/repo",
            session: session
          )
          Issue.record("expected offlineModeActive to be thrown")
        } catch let error as AcervoError {
          switch error {
          case .offlineModeActive:
            #expect(true)
          default:
            Issue.record("expected offlineModeActive, got \(error)")
          }
        }
      }
    }

    /// Same assertion against the public `Acervo.fetchManifest(for:session:)`
    /// entry point — the path most consumers actually call. This guarantees
    /// the gate covers the public surface and not just the internal helper.
    @Test("Public Acervo.fetchManifest throws offlineModeActive when ACERVO_OFFLINE=1")
    func publicFetchManifestTrips() async throws {
      try await Self.withOfflineModeActive {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        do {
          _ = try await Acervo.fetchManifest(
            for: "offline-test/repo",
            session: session
          )
          Issue.record("expected offlineModeActive to be thrown")
        } catch let error as AcervoError {
          switch error {
          case .offlineModeActive:
            #expect(true)
          default:
            Issue.record("expected offlineModeActive, got \(error)")
          }
        }
      }
    }

    // MARK: - Test B: gate is off by default

    /// With `ACERVO_OFFLINE` unset, `Acervo.isOfflineModeActive` must read
    /// `false`. This is the default contract for every consumer that does not
    /// opt in to offline mode.
    @Test("Gate is off when ACERVO_OFFLINE is unset")
    func gateOffByDefault() {
      let prior = ProcessInfo.processInfo.environment[Self.envVar]
      unsetenv(Self.envVar)
      defer {
        if let prior {
          setenv(Self.envVar, prior, 1)
        } else {
          unsetenv(Self.envVar)
        }
      }

      #expect(Acervo.isOfflineModeActive == false)
    }

    /// Values other than the literal string `"1"` must NOT activate the gate.
    /// The CHANGELOG explicitly pins the contract to `"1"`; downstream tools
    /// should not be able to flip the gate by accident with `"true"`, `"yes"`,
    /// or an empty string.
    @Test("Only ACERVO_OFFLINE=1 trips the gate; other truthy strings do not")
    func onlyLiteralOneTripsGate() {
      let prior = ProcessInfo.processInfo.environment[Self.envVar]
      defer {
        if let prior {
          setenv(Self.envVar, prior, 1)
        } else {
          unsetenv(Self.envVar)
        }
      }

      let nonActivatingValues = ["", "0", "true", "yes", "on", "TRUE"]
      for value in nonActivatingValues {
        setenv(Self.envVar, value, 1)
        #expect(
          Acervo.isOfflineModeActive == false,
          "ACERVO_OFFLINE=\(value) must not activate offline mode"
        )
      }

      setenv(Self.envVar, "1", 1)
      #expect(Acervo.isOfflineModeActive == true)
    }

    // MARK: - Test C: cached read still works under offline mode

    /// `Acervo.modelDirectory(for:)` is a pure path-resolution helper — it does
    /// not touch the network. With `ACERVO_OFFLINE=1` set, calls to it must
    /// continue to return the resolved URL. This is the read-path half of the
    /// offline-mode contract: refuse fetches, keep serving local data.
    @Test("modelDirectory(for:) still resolves under ACERVO_OFFLINE=1")
    func cachedReadStillWorks() async throws {
      try await Self.withOfflineModeActive {
        let modelId = "offline-test/cached-repo"
        let dir = try Acervo.modelDirectory(for: modelId)
        // The slugified directory name is `org_repo`. The exact base directory
        // depends on the test environment (App Group vs. Application Support
        // fallback), but the leaf component is deterministic and is the only
        // assertion the offline-mode contract requires here.
        #expect(dir.lastPathComponent == "offline-test_cached-repo")
      }
    }
  }  // struct OfflineModeGateTests
}  // extension SharedStaticStateSuite
