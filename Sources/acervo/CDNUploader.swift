import CryptoKit
import Foundation
import SwiftAcervo

/// Mirrors a locally-staged model directory to the Cloudflare R2 CDN and
/// enforces integrity checks 4-6 from `REQUIREMENTS-acervo-tool.md`.
///
/// `CDNUploader` is an actor so callers can drive the multi-step upload
/// pipeline concurrently while still serializing process launches and
/// URLSession work per uploader instance. It intentionally does *not*
/// take ownership of manifest generation; callers build a `CDNManifest`
/// with `ManifestGenerator` first and then pass it in for verification.
///
/// The uploader runs the following checks:
///
/// - **CHECK 4** (`verifyBeforeUpload`) — Re-hashes every file referenced
///   by the manifest on the local filesystem before any `aws` process is
///   spawned. Any mismatch throws `AcervoToolError.stagingMutation` and
///   aborts the upload.
/// - **CHECK 5** (`verifyManifestOnCDN`) — Fetches the freshly-uploaded
///   `manifest.json` via HTTPS, decodes it, and calls
///   `CDNManifest.verifyChecksum()` to confirm the round-trip succeeded.
/// - **CHECK 6** (`spotCheckFileOnCDN`) — Downloads a single file from
///   the CDN, recomputes its SHA-256, and compares it to the manifest.
///   Used to guarantee at least one file bytestream matches after
///   replication.
///
/// The uploader never passes `--delete` to `aws s3 sync`: orphaned files
/// on the CDN are considered safer than an accidental mass-deletion.
actor CDNUploader {

  /// Absolute path to the `aws` executable. Resolved via `ToolCheck`
  /// before the uploader is constructed; override for testing.
  private let awsExecutableURL: URL

  /// Environment snapshot captured at construction time so tests can
  /// inject fake credentials without touching the real process env.
  private let environmentSnapshot: [String: String]

  init(
    awsExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/env"),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.awsExecutableURL = awsExecutableURL
    self.environmentSnapshot = environment
  }

  // MARK: - CHECK 4: pre-upload staging verification

  /// Re-hashes every file listed in `manifest` on disk and throws the
  /// first mismatch it finds (CHECK 4).
  ///
  /// Runs synchronously, before any `aws` process is spawned, so a
  /// mutation detected here guarantees no bytes ever left the machine.
  ///
  /// - Parameters:
  ///   - directory: Local staging directory whose layout matches the
  ///     `path` fields in `manifest.files`.
  ///   - manifest: The just-generated manifest from `ManifestGenerator`.
  /// - Throws: `AcervoToolError.stagingMutation` on the first file whose
  ///   recomputed SHA-256 does not match the manifest entry.
  func verifyBeforeUpload(directory: URL, manifest: CDNManifest) throws {
    let resolvedDirectory = directory.resolvingSymlinksInPath()
    for entry in manifest.files {
      let fileURL = resolvedDirectory.appendingPathComponent(entry.path)
      let actual: String
      do {
        actual = try IntegrityVerification.sha256(of: fileURL)
      } catch {
        throw AcervoToolError.stagingMutation(
          filename: entry.path,
          expected: entry.sha256,
          actual: "<unreadable: \(error.localizedDescription)>"
        )
      }
      guard actual == entry.sha256 else {
        throw AcervoToolError.stagingMutation(
          filename: entry.path,
          expected: entry.sha256,
          actual: actual
        )
      }
    }
  }

  // MARK: - sync / upload

  /// Mirrors `localDirectory` to `s3://<bucket>/models/<slug>/` using
  /// `aws s3 sync`.
  ///
  /// Never passes `--delete`. When `dryRun` is true, `--dryrun` is
  /// appended so `aws` only prints the actions it would take.
  ///
  /// When `force` is true, `--exact-timestamps` is appended. This flag
  /// changes `aws s3 sync`'s comparison semantics so files are
  /// considered out-of-date when their local mtime is newer than the
  /// remote object's timestamp, which triggers re-upload of files that
  /// size-comparison alone would have skipped. **It is not a
  /// "force-upload-everything" switch** — files whose timestamps happen
  /// to match the remote will still be skipped. See the `force` help
  /// string on `UploadCommand` for the same caveat.
  ///
  /// - Parameters:
  ///   - localDirectory: Directory to sync.
  ///   - slug: The `org_repo` slug; becomes the remote path component.
  ///   - bucket: R2 bucket name.
  ///   - endpoint: R2 endpoint URL passed to `--endpoint-url`.
  ///   - dryRun: If true, appends `--dryrun`.
  ///   - force: If true, appends `--exact-timestamps` (changes sync
  ///     comparison semantics as described above).
  /// - Throws: `AcervoToolError.awsProcessFailed` if `aws` exits
  ///   non-zero.
  func sync(
    localDirectory: URL,
    slug: String,
    bucket: String,
    endpoint: String,
    dryRun: Bool,
    force: Bool
  ) async throws {
    let arguments = Self.buildSyncArguments(
      localDirectory: localDirectory,
      slug: slug,
      bucket: bucket,
      endpoint: endpoint,
      dryRun: dryRun,
      force: force
    )
    try runAWS(arguments: arguments, label: "s3 sync")
  }

  /// Uploads `manifest.json` in a dedicated `aws s3 cp` invocation
  /// immediately after `sync()` completes successfully.
  ///
  /// A separate call ensures the manifest only appears on the CDN once
  /// all referenced files have finished replicating, avoiding a window
  /// where a client could download a manifest that references missing
  /// files.
  func uploadManifest(
    localURL: URL,
    slug: String,
    bucket: String,
    endpoint: String,
    dryRun: Bool
  ) async throws {
    let arguments = Self.buildManifestUploadArguments(
      localManifestURL: localURL,
      slug: slug,
      bucket: bucket,
      endpoint: endpoint,
      dryRun: dryRun
    )
    try runAWS(arguments: arguments, label: "s3 cp")
  }

  // MARK: - CHECK 5: verify manifest on CDN

  /// Fetches `<publicBaseURL>/models/<slug>/manifest.json`, asserts
  /// HTTP 200, decodes it, and runs `verifyChecksum()` (CHECK 5).
  ///
  /// - Returns: The decoded, verified `CDNManifest`.
  /// - Throws:
  ///   - `AcervoToolError.cdnHTTPStatus` if the status code is not 200.
  ///   - `AcervoToolError.cdnManifestChecksumInvalid` if
  ///     `verifyChecksum()` returns false.
  ///   - Errors from `URLSession` / `JSONDecoder`.
  func verifyManifestOnCDN(publicBaseURL: URL, slug: String) async throws -> CDNManifest {
    let manifestURL = publicBaseURL
      .appendingPathComponent("models", isDirectory: true)
      .appendingPathComponent(slug, isDirectory: true)
      .appendingPathComponent("manifest.json")
    let (data, response) = try await URLSession.shared.data(from: manifestURL)
    guard let http = response as? HTTPURLResponse else {
      throw AcervoToolError.cdnHTTPStatus(url: manifestURL.absoluteString, statusCode: -1)
    }
    guard http.statusCode == 200 else {
      throw AcervoToolError.cdnHTTPStatus(
        url: manifestURL.absoluteString, statusCode: http.statusCode)
    }
    let manifest = try JSONDecoder().decode(CDNManifest.self, from: data)
    guard manifest.verifyChecksum() else {
      throw AcervoToolError.cdnManifestChecksumInvalid(url: manifestURL.absoluteString)
    }
    return manifest
  }

  // MARK: - CHECK 6: spot-check a file on the CDN

  /// Downloads `<publicBaseURL>/models/<slug>/<filename>`, recomputes
  /// the SHA-256 of the response body, and compares it to
  /// `expectedSHA256` (CHECK 6).
  ///
  /// - Throws:
  ///   - `AcervoToolError.cdnHTTPStatus` if the status code is not 200.
  ///   - `AcervoToolError.cdnChecksumMismatch` on hash mismatch.
  func spotCheckFileOnCDN(
    publicBaseURL: URL,
    slug: String,
    filename: String,
    expectedSHA256: String
  ) async throws {
    let fileURL = publicBaseURL
      .appendingPathComponent("models", isDirectory: true)
      .appendingPathComponent(slug, isDirectory: true)
      .appendingPathComponent(filename)
    let (data, response) = try await URLSession.shared.data(from: fileURL)
    guard let http = response as? HTTPURLResponse else {
      throw AcervoToolError.cdnHTTPStatus(url: fileURL.absoluteString, statusCode: -1)
    }
    guard http.statusCode == 200 else {
      throw AcervoToolError.cdnHTTPStatus(
        url: fileURL.absoluteString, statusCode: http.statusCode)
    }
    let actual = Self.sha256Hex(of: data)
    guard actual == expectedSHA256 else {
      throw AcervoToolError.cdnChecksumMismatch(
        filename: filename, expected: expectedSHA256, actual: actual)
    }
  }

  // MARK: - Argument builders (package-internal for tests)

  /// Builds the argument array passed to `aws` for an `s3 sync` call.
  /// Exposed at package-internal visibility so unit tests can assert
  /// the exact argv without spawning a real process.
  static func buildSyncArguments(
    localDirectory: URL,
    slug: String,
    bucket: String,
    endpoint: String,
    dryRun: Bool,
    force: Bool
  ) -> [String] {
    var arguments: [String] = [
      "aws",
      "s3",
      "sync",
      localDirectory.path,
      "s3://\(bucket)/models/\(slug)/",
      "--endpoint-url",
      endpoint,
      "--exclude",
      "*.DS_Store",
      "--exclude",
      ".huggingface/*",
    ]
    if dryRun {
      arguments.append("--dryrun")
    }
    if force {
      // Changes `aws s3 sync` comparison semantics to include
      // timestamps; NOT a "force everything" switch. Files whose
      // timestamps already match the remote still get skipped.
      arguments.append("--exact-timestamps")
    }
    return arguments
  }

  /// Builds the argument array passed to `aws` for the separate
  /// `s3 cp manifest.json` call that runs after `sync()`.
  static func buildManifestUploadArguments(
    localManifestURL: URL,
    slug: String,
    bucket: String,
    endpoint: String,
    dryRun: Bool
  ) -> [String] {
    var arguments: [String] = [
      "aws",
      "s3",
      "cp",
      localManifestURL.path,
      "s3://\(bucket)/models/\(slug)/manifest.json",
      "--endpoint-url",
      endpoint,
    ]
    if dryRun {
      arguments.append("--dryrun")
    }
    return arguments
  }

  // MARK: - Process execution

  /// Launches `aws` via `/usr/bin/env` with the given argv and the
  /// R2 credentials remapped into AWS env vars.
  ///
  /// Captures stdout and stderr via `Pipe`. On non-zero exit the
  /// stderr contents are wrapped in `AcervoToolError.awsProcessFailed`.
  private func runAWS(arguments: [String], label: String) throws {
    #if !os(macOS)
    throw AcervoToolError.awsProcessFailed(
      command: label, exitCode: -1, stderr: "Not available on this platform")
    #else
    guard let accessKey = environmentSnapshot["R2_ACCESS_KEY_ID"] else {
      throw AcervoToolError.missingEnvironmentVariable("R2_ACCESS_KEY_ID")
    }
    guard let secretKey = environmentSnapshot["R2_SECRET_ACCESS_KEY"] else {
      throw AcervoToolError.missingEnvironmentVariable("R2_SECRET_ACCESS_KEY")
    }

    let process = Process()
    process.executableURL = awsExecutableURL
    process.arguments = arguments

    var env = environmentSnapshot
    env["AWS_ACCESS_KEY_ID"] = accessKey
    env["AWS_SECRET_ACCESS_KEY"] = secretKey
    process.environment = env

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
      try process.run()
    } catch {
      throw AcervoToolError.awsProcessFailed(
        command: label,
        exitCode: -1,
        stderr: "failed to launch aws: \(error.localizedDescription)"
      )
    }

    // Drain the pipes before waiting so `aws` can't deadlock on a
    // full pipe buffer for large sync output.
    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    _ = stdoutData  // captured but not surfaced on success paths

    process.waitUntilExit()

    if process.terminationStatus != 0 {
      let stderrText =
        String(data: stderrData, encoding: .utf8) ?? "<non-utf8 stderr>"
      throw AcervoToolError.awsProcessFailed(
        command: label,
        exitCode: process.terminationStatus,
        stderr: stderrText
      )
    }
    #endif
  }

  // MARK: - Helpers

  /// Computes a lowercase hex SHA-256 of an in-memory `Data` buffer.
  /// Shared helper so `spotCheckFileOnCDN` does not have to round-trip
  /// through a temporary file just to reuse `IntegrityVerification`.
  private static func sha256Hex(of data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
