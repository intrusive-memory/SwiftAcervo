import ArgumentParser
import Foundation
import SwiftAcervo

/// Re-pulls a model from HuggingFace and atomically republishes it to the
/// CDN.
///
/// `recache` is the full pipeline a maintainer runs to refresh a model on
/// the CDN: it shells out to `hf` to populate a staging directory, then
/// hands that directory to `Acervo.recache` (which composes
/// `Acervo.publishModel`'s 11-step ship sequence). The orphan-prune step
/// runs by default, so any keys that exist on the CDN but are no longer
/// referenced by the new manifest are removed. Pass `--keep-orphans` if
/// you want them retained (catalog migrations that intentionally leak).
struct RecacheCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "recache",
    abstract:
      "Re-fetch a model from HuggingFace and atomically republish it to the CDN.",
    discussion: """
      Pipeline (per REQUIREMENTS-delete-and-recache.md §6.4 / §7):

        1. Run `hf download <modelId>` into the staging directory.
        2. Hand the staging directory to Acervo.publishModel:
             - Generate manifest.json (CHECKs 2 + 3).
             - Re-hash every staged file against the manifest (CHECK 4).
             - List existing CDN keys under models/<slug>/.
             - PUT every file; PUT manifest.json LAST.
             - Re-fetch the manifest from the public URL (CHECK 5).
             - Re-fetch one file from the public URL (CHECK 6).
             - Delete orphan keys (unless --keep-orphans).

      The manifest is the LAST PUT, so if any step before that fails the
      old manifest still references the prior version's complete file set
      and consumers see no disruption.

      REQUIRED ENVIRONMENT VARIABLES
        HF_TOKEN               HuggingFace token (or pass --token)
        R2_ACCESS_KEY_ID       Cloudflare R2 access key
        R2_SECRET_ACCESS_KEY   Cloudflare R2 secret key
        R2_ENDPOINT            R2 S3-compatible endpoint URL
        R2_PUBLIC_URL          Public CDN base URL used by CHECKs 5 + 6

      OPTIONAL ENVIRONMENT VARIABLES
        R2_BUCKET              Bucket name (default: intrusive-memory-models)
        R2_REGION              Region (default: auto)
        STAGING_DIR            Staging root (default: /tmp/acervo-staging)

      EXAMPLES
        acervo recache mlx-community/Qwen2.5-7B-Instruct-4bit
        acervo recache mlx-community/Qwen2.5-7B-Instruct-4bit --keep-orphans
        acervo recache mlx-community/Qwen2.5-7B-Instruct-4bit --yes  # required for non-TTY
      """
  )

  @Argument(help: "HuggingFace model identifier in 'org/repo' form.")
  var modelId: String

  @Argument(help: "Optional subset of files to download. Defaults to the whole repo.")
  var files: [String] = []

  @Option(
    name: [.short, .customLong("output")],
    help: "Override staging directory root (default: $STAGING_DIR or /tmp/acervo-staging)."
  )
  var output: String?

  @Option(
    name: [.short, .customLong("token")],
    help: "HuggingFace token. Falls back to $HF_TOKEN when unset."
  )
  var token: String?

  @Option(
    name: [.short, .customLong("bucket")],
    help: "R2 bucket override (otherwise uses $R2_BUCKET)."
  )
  var bucket: String?

  @Option(
    name: .customLong("endpoint"),
    help: "R2 endpoint override (otherwise uses $R2_ENDPOINT)."
  )
  var endpoint: String?

  @Flag(
    name: .customLong("keep-orphans"),
    help:
      "Skip the orphan-prune step. By default, keys on the CDN not referenced by the new manifest are deleted."
  )
  var keepOrphans: Bool = false

  @Flag(
    name: .customLong("yes"),
    help:
      "Bypass the orphan-prune confirmation prompt. Required for non-TTY (CI) runs that prune."
  )
  var yes: Bool = false

  @OptionGroup var progressOptions: ProgressOptions

  func run() async throws {
    // hf is the one external tool recache still needs.
    if !ToolCheck.isToolOnPath(name: "hf") {
      let message =
        "error: required tool 'hf' not found on PATH. Install it with: brew install huggingface-hub\n"
      FileHandle.standardError.write(Data(message.utf8))
      throw AcervoToolError.missingTool("hf")
    }

    let credentials = try CredentialResolver.resolve(
      bucketOverride: bucket,
      endpointOverride: endpoint
    )

    let stagingRoot = Self.resolveStagingRoot(override: output)
    let slug = modelId.replacingOccurrences(of: "/", with: "_")
    let stagingURL = stagingRoot.appendingPathComponent(slug, isDirectory: true)
    try FileManager.default.createDirectory(
      at: stagingURL, withIntermediateDirectories: true
    )

    // Confirm only when the orphan-prune will actually run. --keep-orphans
    // skips the destructive part, so no prompt is needed in that case.
    if !keepOrphans {
      let proceed = try TTYConfirm.confirm(
        prompt: """
          About to re-publish models/\(slug)/ to \(credentials.bucket) and \
          delete any orphan keys that are no longer referenced by the new \
          manifest. Continue? [y/N]
          """,
        yesBypass: yes
      )
      guard proceed else {
        FileHandle.standardOutput.write(
          Data("recache: cancelled.\n".utf8)
        )
        return
      }
    }

    // Capture flag values that need to cross into the @Sendable closure
    // boundary. ArgumentParser-decorated properties are fine to read here
    // (they're stored), but Swift 6 strict concurrency wants explicit
    // `let`s for closure capture.
    let resolvedToken = token
    let downloadFiles = files
    let quiet = progressOptions.quiet

    let reporter = PublishProgressReporter(quiet: quiet)
    _ = try await Acervo.recache(
      modelId: modelId,
      stagingDirectory: stagingURL,
      credentials: credentials,
      fetchSource: { id, into in
        try Self.runHuggingFaceDownload(
          modelId: id,
          files: downloadFiles,
          token: resolvedToken,
          stagingURL: into,
          quiet: quiet
        )
      },
      keepOrphans: keepOrphans,
      progress: { event in reporter.handle(event) }
    )

    FileHandle.standardOutput.write(
      Data("Recache complete for \(modelId).\n".utf8)
    )
  }

  // MARK: - hf invocation

  /// Shells out to `hf download <modelId> [files…] --local-dir <stagingURL>`.
  ///
  /// Forces `HF_HUB_ENABLE_HF_XET=1` so newer Xet-backed repos download
  /// real bytes instead of metadata stubs (matches the existing logic in
  /// `ShipCommand.runHuggingFaceDownload`).
  private static func runHuggingFaceDownload(
    modelId: String,
    files: [String],
    token: String?,
    stagingURL: URL,
    quiet: Bool
  ) throws {
    #if !os(macOS)
      throw AcervoToolError.missingTool("hf (not available on this platform)")
    #else
      var arguments: [String] = [
        "hf",
        "download",
        modelId,
      ]
      arguments.append(contentsOf: files)
      arguments.append(contentsOf: [
        "--local-dir",
        stagingURL.path,
      ])

      var environment = ProcessInfo.processInfo.environment
      environment["HF_HUB_ENABLE_HF_XET"] = "1"
      if let token, !token.isEmpty {
        environment["HF_TOKEN"] = token
        environment["HUGGING_FACE_HUB_TOKEN"] = token
      }

      let result = try ProcessRunner.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: arguments,
        environment: environment,
        quiet: quiet,
        label: "hf download"
      )

      if result.exitCode != 0 {
        let stderrText =
          result.capturedStderr.isEmpty
          ? "(stderr not captured; subprocess stdio was live — see above)"
          : result.capturedStderr
        FileHandle.standardError.write(
          Data("error: hf download exited \(result.exitCode): \(stderrText)\n".utf8)
        )
        throw AcervoToolError.awsProcessFailed(
          command: "hf download",
          exitCode: result.exitCode,
          stderr: stderrText
        )
      }
    #endif
  }

  private static func resolveStagingRoot(override: String?) -> URL {
    if let override, !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    if let envRoot = ProcessInfo.processInfo.environment["STAGING_DIR"], !envRoot.isEmpty {
      return URL(fileURLWithPath: envRoot, isDirectory: true)
    }
    return URL(fileURLWithPath: "/tmp/acervo-staging", isDirectory: true)
  }
}

/// Lightweight stdout sink for `AcervoPublishProgress`. Mirrors the
/// granularity of the existing CHECK 1/2/3/4/5/6 print statements so an
/// operator watching the terminal sees the same step boundaries as before.
final class PublishProgressReporter: @unchecked Sendable {
  private let quiet: Bool
  init(quiet: Bool) { self.quiet = quiet }

  func handle(_ event: AcervoPublishProgress) {
    if quiet { return }
    let line: String
    switch event {
    case .generatingManifest:
      line = "publish: generating manifest (CHECKs 2 + 3)…\n"
    case .verifyingManifest:
      line = "publish: re-hashing staged files (CHECK 4)…\n"
    case .listingExistingKeys(let found):
      line = "publish: listed \(found) existing keys.\n"
    case .uploadingFile(let name, let bytesSent, let bytesTotal):
      // Suppress the bytesSent==0 "starting" event to halve the noise;
      // a single line per file when it completes is enough for a CLI.
      guard bytesSent > 0 else { return }
      line = "publish: uploaded \(name) (\(bytesTotal) bytes).\n"
    case .uploadingManifest:
      line = "publish: uploading manifest.json (LAST PUT)…\n"
    case .verifyingPublic(let stage):
      line = "publish: verifying public \(stage) (CHECK 5/6)…\n"
    case .pruningOrphans(let count):
      line =
        count == 0
        ? "publish: no orphans to prune.\n"
        : "publish: pruning \(count) orphan key(s)…\n"
    case .complete:
      line = "publish: complete.\n"
    }
    FileHandle.standardOutput.write(Data(line.utf8))
  }
}
