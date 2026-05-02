import ArgumentParser
import Foundation
import SwiftAcervo

/// Downloads a model from HuggingFace and immediately mirrors it to the
/// intrusive-memory CDN in a single atomic pipeline.
///
/// `ship` is the primary day-to-day entry point: it combines the full
/// `download` pipeline (CHECK 1) with the full `upload` pipeline
/// (CHECKs 2–6). The staging directory is the bridge between the two
/// phases and defaults to `$STAGING_DIR/<slug>` or
/// `/tmp/acervo-staging/<slug>`.
///
/// **Download phase (CHECK 1)**:
/// - Shells out to `hf download` into the staging directory.
/// - Verifies each downloaded file's SHA-256 against the HuggingFace LFS
///   API (skipped if `--no-verify` is set).
///
/// **Upload phase (CHECKs 2–6)**:
/// 1. `ManifestGenerator.generate` — refuses zero-byte files (CHECK 2),
///    writes manifest, re-reads and verifies checksum (CHECK 3).
/// 2. `CDNUploader.verifyBeforeUpload` — re-hashes files against the
///    manifest before spawning any `aws` process (CHECK 4).
/// 3. `CDNUploader.sync` — mirrors the staging dir to R2.
/// 4. `CDNUploader.uploadManifest` — copies `manifest.json` to R2.
/// 5. `CDNUploader.verifyManifestOnCDN` — fetches the CDN manifest and
///    validates its checksum (CHECK 5).
/// 6. `CDNUploader.spotCheckFileOnCDN("config.json", ...)` — verifies
///    at least one file's bytestream matches after replication (CHECK 6).
struct ShipCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ship",
    abstract: "Download a model from HuggingFace and mirror it to the CDN.",
    discussion: """
      Runs the full 6-step integrity pipeline in one command:

        CHECK 1  Download files from HuggingFace and verify each file's SHA-256
                 against the HuggingFace LFS API. (Skip with --no-verify.)
        CHECK 2  Refuse to generate a manifest if any file is zero bytes.
        CHECK 3  Re-read manifest.json after writing and verify its checksum.
        CHECK 4  Re-hash every staged file against the manifest before uploading.
        CHECK 5  Fetch manifest.json from the CDN and validate its checksum.
        CHECK 6  Download config.json from the CDN and verify its SHA-256.

      REQUIRED ENVIRONMENT VARIABLES
        HF_TOKEN               HuggingFace token (or pass --token)
        R2_ACCESS_KEY_ID       Cloudflare R2 access key
        R2_SECRET_ACCESS_KEY   Cloudflare R2 secret key

      OPTIONAL ENVIRONMENT VARIABLES
        R2_BUCKET              Bucket name (default: intrusive-memory-models)
        R2_ENDPOINT            S3-compatible endpoint URL
        R2_PUBLIC_URL          Public CDN base URL used for CHECK 5/6
        STAGING_DIR            Staging root (default: /tmp/acervo-staging)

      EXAMPLES
        acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit
        acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit config.json tokenizer.json
        acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit --no-verify --dry-run
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
    help: "Pass --dryrun to aws; no files are transferred."
  )
  var dryRun: Bool = false

  @Flag(
    name: .customLong("force"),
    help:
      "Pass --exact-timestamps to aws s3 sync. Changes comparison semantics so files with newer local timestamps trigger re-upload. This is NOT a force-upload-everything switch; files whose timestamps match the remote are still skipped."
  )
  var force: Bool = false

  @OptionGroup var progressOptions: ProgressOptions

  // MARK: - run()

  func run() async throws {
    try ToolCheck.validate()

    guard source == "hf" else {
      throw ValidationError("Unsupported --source '\(source)'. Only 'hf' is supported.")
    }

    let resolvedBucket = try resolveBucket()
    let resolvedEndpoint = try resolveEndpoint()

    let stagingRoot = Self.resolveStagingRoot(override: output)
    let slug = Self.slug(from: modelId)
    let stagingURL = stagingRoot.appendingPathComponent(slug, isDirectory: true)

    try FileManager.default.createDirectory(
      at: stagingURL,
      withIntermediateDirectories: true
    )

    // ── DOWNLOAD PHASE (CHECK 1) ──────────────────────────────────────────

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

    // ── UPLOAD PHASE (CHECKs 2–6) ────────────────────────────────────────

    let publicBaseURL = Self.resolvePublicBaseURL()

    // CHECK 2+3: generate manifest, refuse zero-byte files, verify on re-read.
    let generator = ManifestGenerator(modelId: modelId)
    let manifestURL = try await generator.generate(
      directory: stagingURL, quiet: progressOptions.quiet)
    FileHandle.standardOutput.write(
      Data("manifest written to \(manifestURL.path)\n".utf8)
    )

    let manifestData = try Data(contentsOf: manifestURL)
    let manifest = try JSONDecoder().decode(CDNManifest.self, from: manifestData)

    // CHECK 4: re-hash every file against the manifest before spawning aws.
    let uploader = CDNUploader()
    let check4Reporter = ProgressReporter(
      label: "CHECK 4 re-hash: ",
      total: manifest.files.count,
      quiet: progressOptions.quiet
    )
    try await uploader.verifyBeforeUpload(
      directory: stagingURL, manifest: manifest, reporter: check4Reporter
    )
    FileHandle.standardOutput.write(
      Data("CHECK 4 passed: all staged files match the manifest.\n".utf8)
    )

    // Sync files to CDN.
    try await uploader.sync(
      localDirectory: stagingURL,
      slug: slug,
      bucket: resolvedBucket,
      endpoint: resolvedEndpoint,
      dryRun: dryRun,
      force: force,
      quiet: progressOptions.quiet
    )

    // Upload manifest separately after sync completes.
    try await uploader.uploadManifest(
      localURL: manifestURL,
      slug: slug,
      bucket: resolvedBucket,
      endpoint: resolvedEndpoint,
      dryRun: dryRun,
      quiet: progressOptions.quiet
    )
    FileHandle.standardOutput.write(
      Data("manifest.json uploaded to CDN.\n".utf8)
    )

    // CHECK 5: verify manifest is fetchable and checksums on CDN.
    _ = try await uploader.verifyManifestOnCDN(publicBaseURL: publicBaseURL, slug: slug)
    FileHandle.standardOutput.write(
      Data("CHECK 5 passed: CDN manifest verified.\n".utf8)
    )

    // CHECK 6: spot-check config.json on CDN.
    if let configEntry = manifest.files.first(where: { $0.path == "config.json" }) {
      try await uploader.spotCheckFileOnCDN(
        publicBaseURL: publicBaseURL,
        slug: slug,
        filename: "config.json",
        expectedSHA256: configEntry.sha256
      )
      FileHandle.standardOutput.write(
        Data("CHECK 6 passed: config.json spot-check succeeded.\n".utf8)
      )
    } else {
      FileHandle.standardOutput.write(
        Data("CHECK 6 skipped: config.json not present in manifest.\n".utf8)
      )
    }

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
        throw AcervoToolError.awsProcessFailed(
          command: "hf download",
          exitCode: result.exitCode,
          stderr: stderrText
        )
      }
    #endif
  }

  // MARK: - Helpers

  private func resolveBucket() throws -> String {
    if let bucket { return bucket }
    if let env = ProcessInfo.processInfo.environment["R2_BUCKET"], !env.isEmpty {
      return env
    }
    throw AcervoToolError.missingEnvironmentVariable("R2_BUCKET")
  }

  private func resolveEndpoint() throws -> String {
    if let endpoint { return endpoint }
    if let env = ProcessInfo.processInfo.environment["R2_ENDPOINT"], !env.isEmpty {
      return env
    }
    throw AcervoToolError.missingEnvironmentVariable("R2_ENDPOINT")
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

  private static func slug(from modelId: String) -> String {
    modelId.replacingOccurrences(of: "/", with: "_")
  }

  private static func resolvePublicBaseURL() -> URL {
    if let raw = ProcessInfo.processInfo.environment["R2_PUBLIC_URL"],
      let url = URL(string: raw)
    {
      return url
    }
    return URL(string: "https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev")!
  }
}
