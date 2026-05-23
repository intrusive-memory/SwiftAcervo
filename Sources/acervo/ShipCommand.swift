import ArgumentParser
import Foundation
import SwiftAcervo

/// Downloads a model from HuggingFace and immediately mirrors it to the
/// intrusive-memory CDN in a single atomic pipeline.
///
/// `ship` is the primary day-to-day entry point: it combines the full
/// `download` pipeline (CHECK 0 + CHECK 1) with the full upload pipeline
/// (CHECKs 2–6 + orphan-prune). The staging directory is the bridge
/// between the two phases and defaults to `$STAGING_DIR/<slug>` or
/// `/tmp/acervo-staging/<slug>`.
///
/// **Download phase (CHECK 0 + CHECK 1)**:
/// - Shells out to `hf download` into the staging directory.
/// - Walks the HF tree listing to confirm every advertised file is present
///   at the expected size (CHECK 0).
/// - Verifies each downloaded file's SHA-256 against the HuggingFace LFS
///   API (CHECK 1; skipped if `--no-verify` is set).
///
/// **Upload phase (CHECKs 2–6 + orphan prune)**:
/// All CDN-side work is delegated to `Acervo.publishModel(...)`, which
/// runs the frozen 11-step ship sequence (manifest gen, CHECK 4 re-hash,
/// existing-key list, file PUTs, manifest-LAST PUT, CHECK 5/6 readback,
/// orphan prune).
struct ShipCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ship",
    abstract: "Download a model from HuggingFace and mirror it to the CDN.",
    discussion: """
      Runs the full integrity pipeline in one command:

        CHECK 0  HF tree completeness — every file the HF API advertises
                 must be present in staging at the expected size.
        CHECK 1  HF LFS verify — recompute each downloaded file's SHA-256
                 and assert it matches the HF LFS API. (Skip with --no-verify.)
        CHECK 2  Refuse to generate a manifest if any file is zero bytes.
        CHECK 3  Re-read manifest.json after writing and verify its checksum.
        CHECK 4  Re-hash every staged file against the manifest before uploading.
        CHECK 5  Fetch manifest.json from the CDN and validate its checksum.
        CHECK 6  Download config.json (or the first manifest entry) from the
                 CDN and verify its SHA-256.

      Orphan prune runs by default — CDN keys not referenced by the new
      manifest are deleted after CHECK 6 passes. Pass `--keep-orphans` to
      preserve the previous additive-only behavior.

      REQUIRED ENVIRONMENT VARIABLES
        HF_TOKEN               HuggingFace token (or pass --token)
        R2_ACCESS_KEY_ID       Cloudflare R2 access key
        R2_SECRET_ACCESS_KEY   Cloudflare R2 secret key
        R2_ENDPOINT            S3-compatible endpoint URL
        R2_PUBLIC_URL          Public CDN base URL used for CHECK 5/6

      OPTIONAL ENVIRONMENT VARIABLES
        R2_BUCKET              Bucket name (default: intrusive-memory-models)
        R2_REGION              Region (default: auto)
        STAGING_DIR            Staging root (default: /tmp/acervo-staging)

      EXAMPLES
        acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit
        acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit config.json tokenizer.json
        acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit --no-verify --dry-run
        acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit --keep-orphans
      """
  )

  // MARK: - Download options

  @Argument(help: "HuggingFace model identifier in 'org/repo' form.")
  var modelId: String

  @Argument(help: "Optional subset of files to download. Defaults to the whole repo.")
  var files: [String] = []

  @Option(
    name: [.short, .customLong("source")], help: "Source registry (only 'hf' is supported today).")
  var source: String = "hf"

  @Option(
    name: [.short, .customLong("output")],
    help: "Override staging directory root (default: $STAGING_DIR or /tmp/acervo-staging)."
  )
  var output: String?

  @Option(
    name: [.short, .customLong("token")],
    help: "HuggingFace token. Falls back to $HF_TOKEN when unset.")
  var token: String?

  @Flag(
    name: .customLong("no-verify"), help: "Skip HuggingFace LFS SHA-256 verification (CHECK 1).")
  var noVerify: Bool = false

  // MARK: - Upload options

  @Option(
    name: [.short, .customLong("bucket")],
    help: "R2 bucket name. Defaults to $R2_BUCKET environment variable."
  )
  var bucket: String?

  @Option(
    name: [.short, .customLong("prefix")],
    help: "Key prefix for uploaded objects (default: 'models/')."
  )
  var prefix: String = "models/"

  @Option(
    name: .customLong("endpoint"),
    help: "R2 endpoint URL. Defaults to $R2_ENDPOINT environment variable."
  )
  var endpoint: String?

  @Flag(
    name: .customLong("dry-run"),
    help:
      "Generate and verify the manifest, then print a 'would upload' summary without contacting the CDN."
  )
  var dryRun: Bool = false

  @Flag(
    name: .customLong("force"),
    help:
      "Reserved flag retained for argv compatibility with the pre-v0.14.x shell-out pipeline. The native publish path always uploads exactly the manifest's file set, so this flag is a no-op today."
  )
  var force: Bool = false

  @Flag(
    name: .customLong("keep-orphans"),
    help:
      "Skip the orphan-prune step. By default, keys on the CDN not referenced by the new manifest are deleted."
  )
  var keepOrphans: Bool = false

  @OptionGroup var progressOptions: ProgressOptions

  // MARK: - run()

  func run() async throws {
    try ToolCheck.validate()

    guard source == "hf" else {
      throw ValidationError("Unsupported --source '\(source)'. Only 'hf' is supported.")
    }

    // Resolve every required env var up front so we fail fast before
    // touching disk or the network.
    let credentials = try CredentialResolver.resolve(
      bucketOverride: bucket,
      endpointOverride: endpoint
    )

    let stagingRoot = Self.resolveStagingRoot(override: output)
    let slug = Self.slug(from: modelId)
    let stagingURL = stagingRoot.appendingPathComponent(slug, isDirectory: true)

    try FileManager.default.createDirectory(
      at: stagingURL,
      withIntermediateDirectories: true
    )

    // ── DOWNLOAD PHASE (CHECK 0 + CHECK 1) ────────────────────────────────

    try runHuggingFaceDownload(into: stagingURL)

    let client = HuggingFaceClient()

    // CHECK 0: completeness — every file HF lists must exist in staging
    // at the expected size. Catches silent Xet failures before they
    // propagate into manifest generation and CDN upload. Always runs.
    try await DownloadCommand.runCompletenessCheck(
      client: client,
      modelId: modelId,
      requestedFiles: files,
      stagingURL: stagingURL
    )
    FileHandle.standardOutput.write(
      Data("CHECK 0 passed: staging directory matches HF tree listing.\n".utf8)
    )

    if !noVerify {
      let discovered = try DownloadCommand.enumerateDownloadedFiles(in: stagingURL)

      let verifyReporter = ProgressReporter(
        label: "Verifying HF LFS: ",
        total: discovered.count,
        quiet: progressOptions.quiet
      )
      var failures: [String] = []
      var lfsAllNotFound = !discovered.isEmpty
      for (relativePath, fileURL) in discovered {
        defer { verifyReporter.advance() }
        let actualSHA256: String
        do {
          actualSHA256 = try IntegrityVerification.sha256(of: fileURL)
        } catch {
          failures.append("\(relativePath): hash failed — \(error.localizedDescription)")
          lfsAllNotFound = false
          continue
        }

        do {
          try await client.verifyLFS(
            modelId: modelId,
            filename: relativePath,
            actualSHA256: actualSHA256,
            stagingURL: fileURL
          )
        } catch let hfError as HFIntegrityError {
          if case .httpError(let status, _) = hfError, status != 404 {
            lfsAllNotFound = false
          }
          if case .checksumMismatch = hfError {
            lfsAllNotFound = false
          }
          if case .missingOID = hfError {
            lfsAllNotFound = false
          }
          try? FileManager.default.removeItem(at: fileURL)
          failures.append("\(relativePath): \(hfError.description)")
        } catch {
          lfsAllNotFound = false
          failures.append("\(relativePath): \(error.localizedDescription)")
        }
      }

      if !failures.isEmpty {
        let body = failures.joined(separator: "\n")
        var message = "error: HuggingFace LFS verification failed:\n\(body)\n"
        if lfsAllNotFound {
          message += LFSVerificationHints.notLFSBackedHint
        }
        FileHandle.standardError.write(Data(message.utf8))
        throw ExitCode.failure
      }
      FileHandle.standardOutput.write(
        Data("CHECK 1 passed: all files verified against HuggingFace LFS.\n".utf8)
      )
    } else {
      FileHandle.standardOutput.write(
        Data("Downloaded \(modelId) to \(stagingURL.path) (verification skipped).\n".utf8)
      )
    }

    // ── DRY-RUN SHORT-CIRCUIT (pre-flight only, no PUTs) ─────────────────
    //
    // `--dry-run` runs manifest generation locally (so the operator still
    // gets the CHECK 2 / CHECK 3 signal) and then prints what would be
    // uploaded without contacting the CDN. Implemented entirely in the CLI
    // so we do not need to add a `dryRun:` parameter to
    // `Acervo.publishModel` (REQUIREMENTS §3.1.3 / framework control F5).

    if dryRun {
      let generator = ManifestGenerator(modelId: modelId)
      let reporterBox = ManifestProgressReporterBox(quiet: progressOptions.quiet)
      let manifestURL = try await generator.generate(
        directory: stagingURL,
        progress: { completed, total in
          reporterBox.handle(completed: completed, total: total)
        }
      )
      let manifestData = try Data(contentsOf: manifestURL)
      let manifest = try JSONDecoder().decode(CDNManifest.self, from: manifestData)
      let totalBytes = manifest.files.reduce(into: Int64(0)) { $0 += $1.sizeBytes }
      FileHandle.standardOutput.write(
        Data(
          "dry-run: would upload \(manifest.files.count) files (\(totalBytes) bytes total) to models/\(slug)/ on \(credentials.bucket).\n"
            .utf8
        )
      )
      return
    }

    // ── UPLOAD PHASE (delegated to Acervo.publishModel) ──────────────────

    let reporter = PublishProgressReporter(
      quiet: progressOptions.quiet,
      style: .ship
    )
    _ = try await PublishRunner.run(
      modelId: modelId,
      directory: stagingURL,
      credentials: credentials,
      keepOrphans: keepOrphans,
      progress: { event in reporter.handle(event) }
    )

    FileHandle.standardOutput.write(
      Data("Ship complete for \(modelId).\n".utf8)
    )
  }

  // MARK: - hf invocation

  private func runHuggingFaceDownload(into stagingURL: URL) throws {
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
      // Force-enable Xet protocol support so newer mlx-community/* and
      // other Xet-backed repos actually download large blobs. Without
      // this, `hf download` silently writes only metadata for Xet files
      // and exits 0, producing an apparently-successful but incomplete
      // staging directory.
      environment["HF_HUB_ENABLE_HF_XET"] = "1"
      if let token, !token.isEmpty {
        environment["HF_TOKEN"] = token
        environment["HUGGING_FACE_HUB_TOKEN"] = token
      }

      let result = try ProcessRunner.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: arguments,
        environment: environment,
        quiet: progressOptions.quiet,
        label: "hf download"
      )

      if result.exitCode != 0 {
        let stderrText =
          result.capturedStderr.isEmpty
          ? "(stderr not captured; subprocess stdio was live — see above)"
          : result.capturedStderr
        let message = "error: hf download exited \(result.exitCode): \(stderrText)\n"
        FileHandle.standardError.write(Data(message.utf8))
        throw AcervoToolError.subprocessFailed(
          command: "hf download",
          exitCode: result.exitCode,
          stderr: stderrText
        )
      }
    #endif
  }

  // MARK: - Helpers

  private static func resolveStagingRoot(override: String?) -> URL {
    if let override, !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    if let envRoot = ProcessInfo.processInfo.environment["STAGING_DIR"], !envRoot.isEmpty {
      return URL(fileURLWithPath: envRoot, isDirectory: true)
    }
    return URL(fileURLWithPath: "/tmp/acervo-staging", isDirectory: true)
  }

  private static func slug(from modelId: String) -> String {
    modelId.replacingOccurrences(of: "/", with: "_")
  }
}
