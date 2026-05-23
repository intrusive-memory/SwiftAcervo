import ArgumentParser
import CryptoKit
import Foundation
import SwiftAcervo

/// Verifies a model's on-disk or on-CDN integrity.
///
/// Two modes:
/// 1. With `directory`: regenerates a fresh manifest via
///    `ManifestGenerator` and then walks the manifest to assert every
///    file still matches its recorded SHA-256. This catches local
///    mutation between manifest runs.
/// 2. Without `directory`: resolves the staging directory from
///    `$STAGING_DIR`, downloads the authoritative `manifest.json` from
///    the CDN (CHECK 5), and verifies every local file against the
///    CDN manifest. Useful for auditing a staging tree before a ship.
struct VerifyCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "verify",
    abstract: "Verify a local or CDN-hosted model against its manifest.",
    discussion: """
      Two modes depending on whether <directory> is supplied:

      LOCAL MODE (with <directory>)
        Regenerates a fresh manifest from the directory and re-hashes every
        file to confirm nothing has changed since the manifest was written.
        Exits non-zero and lists all mismatches.

      CDN MODE (without <directory>)
        Resolves the staging directory from $STAGING_DIR, fetches the
        authoritative manifest.json from the CDN (CHECK 5), and verifies
        every local file against the CDN manifest. Useful for auditing a
        staging tree against what was previously published.

      OPTIONAL ENVIRONMENT VARIABLES (CDN mode only)
        R2_PUBLIC_URL   Public CDN base URL (default: https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev)
        STAGING_DIR     Staging root (default: /tmp/acervo-staging)

      EXAMPLES
        # Local mode: verify staged files match the manifest
        acervo verify mlx-community/Qwen2.5-7B-Instruct-4bit \\
          /tmp/acervo-staging/mlx-community_Qwen2.5-7B-Instruct-4bit

        # CDN mode: compare staging directory against live CDN manifest
        acervo verify mlx-community/Qwen2.5-7B-Instruct-4bit
      """
  )

  @Argument(help: "HuggingFace model identifier in 'org/repo' form.")
  var modelId: String

  @Argument(help: "Local directory to verify; omit to use staging directory")
  var directory: String?

  @OptionGroup var progressOptions: ProgressOptions

  func run() async throws {
    if let directory {
      try await verifyLocalDirectory(path: directory)
    } else {
      try await verifyAgainstCDN()
    }
  }

  // MARK: - Mode 1: local directory

  private func verifyLocalDirectory(path: String) async throws {
    let directoryURL = URL(fileURLWithPath: path, isDirectory: true)

    let generator = ManifestGenerator(modelId: modelId)
    let reporterBox = ManifestProgressReporterBox(quiet: progressOptions.quiet)
    let manifestURL = try await generator.generate(
      directory: directoryURL,
      progress: { completed, total in
        reporterBox.handle(completed: completed, total: total)
      }
    )

    let manifestData = try Data(contentsOf: manifestURL)
    let manifest = try JSONDecoder().decode(CDNManifest.self, from: manifestData)

    let reporter = ProgressReporter(
      label: "Verifying local: ",
      total: manifest.files.count,
      quiet: progressOptions.quiet
    )
    var failures: [String] = []
    for entry in manifest.files {
      defer { reporter.advance() }
      let fileURL = directoryURL.appendingPathComponent(entry.path)
      let actual: String
      do {
        actual = try IntegrityVerification.sha256(of: fileURL)
      } catch {
        failures.append("\(entry.path): unreadable — \(error.localizedDescription)")
        continue
      }
      if actual != entry.sha256 {
        failures.append(
          "\(entry.path): expected \(entry.sha256), got \(actual)"
        )
      }
    }

    if !failures.isEmpty {
      let body = failures.joined(separator: "\n")
      FileHandle.standardError.write(
        Data("error: local verification failed:\n\(body)\n".utf8)
      )
      throw ExitCode.failure
    }

    FileHandle.standardOutput.write(
      Data("Verified \(manifest.files.count) files in \(directoryURL.path)\n".utf8)
    )
  }

  // MARK: - Mode 2: verify staging against CDN manifest

  private func verifyAgainstCDN() async throws {
    let stagingRoot = Self.resolveStagingRoot()
    let slug = Self.slug(from: modelId)
    let stagingURL = stagingRoot.appendingPathComponent(slug, isDirectory: true)

    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: stagingURL.path, isDirectory: &isDir),
      isDir.boolValue
    else {
      FileHandle.standardError.write(
        Data("error: staging directory does not exist: \(stagingURL.path)\n".utf8)
      )
      throw ExitCode.failure
    }

    let publicBase = Self.resolvePublicBaseURL()

    let manifest: CDNManifest
    do {
      manifest = try await Self.fetchCDNManifest(
        publicBaseURL: publicBase,
        slug: slug,
        session: .shared
      )
    } catch {
      FileHandle.standardError.write(
        Data("error: failed to fetch CDN manifest: \(error)\n".utf8)
      )
      throw ExitCode.failure
    }

    let reporter = ProgressReporter(
      label: "Verifying vs CDN: ",
      total: manifest.files.count,
      quiet: progressOptions.quiet
    )
    var failures: [String] = []
    for entry in manifest.files {
      defer { reporter.advance() }
      let fileURL = stagingURL.appendingPathComponent(entry.path)
      guard FileManager.default.fileExists(atPath: fileURL.path) else {
        failures.append("\(entry.path): missing in staging")
        continue
      }
      let actual: String
      do {
        actual = try IntegrityVerification.sha256(of: fileURL)
      } catch {
        failures.append("\(entry.path): unreadable — \(error.localizedDescription)")
        continue
      }
      if actual != entry.sha256 {
        failures.append("\(entry.path): expected \(entry.sha256), got \(actual)")
      }
    }

    if !failures.isEmpty {
      let body = failures.joined(separator: "\n")
      FileHandle.standardError.write(
        Data("error: staging does not match CDN manifest:\n\(body)\n".utf8)
      )
      throw ExitCode.failure
    }

    FileHandle.standardOutput.write(
      Data(
        "Verified \(manifest.files.count) files in \(stagingURL.path) against CDN manifest\n".utf8)
    )
  }

  // MARK: - Helpers

  private static func resolveStagingRoot() -> URL {
    if let envRoot = ProcessInfo.processInfo.environment["STAGING_DIR"], !envRoot.isEmpty {
      return URL(fileURLWithPath: envRoot, isDirectory: true)
    }
    return URL(fileURLWithPath: "/tmp/acervo-staging", isDirectory: true)
  }

  private static func resolvePublicBaseURL() -> URL {
    if let raw = ProcessInfo.processInfo.environment["R2_PUBLIC_URL"],
      let url = URL(string: raw)
    {
      return url
    }
    return URL(string: "https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev")!
  }

  private static func slug(from modelId: String) -> String {
    modelId.replacingOccurrences(of: "/", with: "_")
  }

  /// Fetches `<publicBaseURL>/models/<slug>/manifest.json` over plain
  /// HTTPS, decodes it, and runs `verifyChecksum()` (CHECK 5 readback).
  ///
  /// `session` is injectable so smoke tests can drive this against a
  /// stubbed URLSession instead of the live CDN.
  static func fetchCDNManifest(
    publicBaseURL: URL,
    slug: String,
    session: URLSession
  ) async throws -> CDNManifest {
    let manifestURL =
      publicBaseURL
      .appendingPathComponent("models", isDirectory: true)
      .appendingPathComponent(slug, isDirectory: true)
      .appendingPathComponent("manifest.json")
    let request = URLRequest.cacheBypassing(
      url: manifestURL,
      cacheBuster: UUID().uuidString
    )
    let (data, response) = try await session.data(for: request)
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

  /// Spot-checks a single file on the CDN by SHA-256 (CHECK 6 readback).
  static func spotCheckCDNFile(
    publicBaseURL: URL,
    slug: String,
    filename: String,
    expectedSHA256: String,
    session: URLSession
  ) async throws {
    let fileURL =
      publicBaseURL
      .appendingPathComponent("models", isDirectory: true)
      .appendingPathComponent(slug, isDirectory: true)
      .appendingPathComponent(filename)
    let request = URLRequest.cacheBypassing(
      url: fileURL,
      cacheBuster: expectedSHA256
    )
    let (data, response) = try await session.data(for: request)
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

  private static func sha256Hex(of data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
