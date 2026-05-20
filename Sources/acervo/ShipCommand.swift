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
///
/// **Dry-run mode** (`--dry-run`):
/// Runs through manifest generation only. No HuggingFace download, no R2
/// upload. Manifests are written to `--output-dir` (or a unique tempdir).
/// The absolute path of each written manifest is printed to stdout, one per
/// line. Use this mode in tests and CI pipelines that need to inspect
/// manifest output without touching live credentials or network.
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

      SLUG AND MULTI-COMPONENT MODELS

        Single-component (default):
          acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit
          → modelId == primaryRepo == "mlx-community/Qwen2.5-7B-Instruct-4bit"
          → components == ["mlx-community/Qwen2.5-7B-Instruct-4bit"]

        Single-component with explicit slug:
          acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit --slug qwen-7b-4bit
          → modelId == "qwen-7b-4bit"
          → primaryRepo == "mlx-community/Qwen2.5-7B-Instruct-4bit"
          → components == ["mlx-community/Qwen2.5-7B-Instruct-4bit"]

        Multi-component (spec file):
          acervo ship --spec /path/to/spec.json
          → Produces one manifest per component; all share modelId, primaryRepo, components.

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
        acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit --slug qwen-7b-4bit
        acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit config.json tokenizer.json
        acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit --no-verify --dry-run
        acervo ship --spec /path/to/flux2-spec.json --dry-run --output-dir /tmp/manifests
      """
  )

  // MARK: - Download options

  @Argument(help: "HuggingFace model identifier in 'org/repo' form. Omit when using --spec.")
  var modelId: String?

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

  // MARK: - Slug / multi-component options

  /// Optional slug that overrides `modelId` in the uploaded manifest.
  ///
  /// When supplied, the manifest carries `modelId == slug`, `primaryRepo == <modelId>`,
  /// `components == [<modelId>]`. Preserves today's single-repo flow when omitted.
  @Option(
    name: .customLong("slug"),
    help:
      "Override the manifest's modelId with this slug. Default: use the HF repo string as modelId."
  )
  var slug: String?

  /// Path to a JSON spec file that describes a multi-component model.
  ///
  /// **Spec file format**:
  /// ```json
  /// {
  ///   "modelId": "flux2-klein-4b",
  ///   "primaryRepo": "black-forest-labs/FLUX.2-klein-4B",
  ///   "components": [
  ///     "black-forest-labs/FLUX.2-klein-4B",
  ///     "black-forest-labs/FLUX.2-vae",
  ///     "google/t5-v1_1-xxl"
  ///   ]
  /// }
  /// ```
  ///
  /// When `--spec` is provided, one manifest is generated per component in `components`.
  /// Every manifest carries the same `modelId`, `primaryRepo`, and `components` values.
  @Option(
    name: .customLong("spec"),
    help: "Path to a JSON spec file describing a multi-component model."
  )
  var spec: String?

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

  /// When `--dry-run` is set the full pipeline runs through manifest generation,
  /// the generated manifests are written to `--output-dir` (or a unique tempdir),
  /// and R2 upload is skipped entirely. The absolute path of each manifest is
  /// printed to stdout.
  @Flag(
    name: .customLong("dry-run"),
    help: "Generate manifests only; skip R2 upload. Manifest paths are printed to stdout."
  )
  var dryRun: Bool = false

  /// Destination directory for manifests generated in dry-run mode.
  ///
  /// When omitted in dry-run mode, a unique tempdir is created under
  /// `FileManager.default.temporaryDirectory` and its path is printed on the
  /// first line of stdout before the per-manifest paths.
  @Option(
    name: .customLong("output-dir"),
    help: "Directory for manifests written by --dry-run (default: a unique tempdir)."
  )
  var outputDir: String?

  @Flag(
    name: .customLong("force"),
    help:
      "Pass --exact-timestamps to aws s3 sync. Changes comparison semantics so files with newer local timestamps trigger re-upload. This is NOT a force-upload-everything switch; files whose timestamps match the remote are still skipped."
  )
  var force: Bool = false

  @OptionGroup var progressOptions: ProgressOptions

  // MARK: - validate()

  /// Post-parse validation. ArgumentParser calls this after parsing and before `run()`.
  ///
  /// Ensures `modelId` is present when `--spec` is not provided, so the command
  /// fails at parse time (not run time) in the common single-repo flow.
  func validate() throws {
    if spec == nil && modelId == nil {
      throw ValidationError("Missing argument 'modelId'. Provide a model identifier or --spec <path>.")
    }
  }

  // MARK: - run()

  func run() async throws {
    // Dry-run mode: generate manifests from pre-staged files, skip all network I/O.
    if dryRun {
      try await runDryRun()
      return
    }

    // Normal (live) mode: download from HF then upload to R2.
    try ToolCheck.validate()

    guard source == "hf" else {
      throw ValidationError("Unsupported --source '\(source)'. Only 'hf' is supported.")
    }

    // --spec and live mode: not supported yet (needs per-component HF download loop).
    if spec != nil {
      throw ValidationError("--spec is only supported with --dry-run in this release.")
    }

    guard let resolvedModelId = modelId else {
      throw ValidationError("modelId is required when --spec is not provided.")
    }

    let resolvedBucket = try resolveBucket()
    let resolvedEndpoint = try resolveEndpoint()

    let stagingRoot = Self.resolveStagingRoot(override: output)
    let repoSlug = Self.slug(from: resolvedModelId)
    let stagingURL = stagingRoot.appendingPathComponent(repoSlug, isDirectory: true)

    try FileManager.default.createDirectory(
      at: stagingURL,
      withIntermediateDirectories: true
    )

    // ── DOWNLOAD PHASE (CHECK 1) ──────────────────────────────────────────

    try runHuggingFaceDownload(into: stagingURL, modelId: resolvedModelId)

    let client = HuggingFaceClient()

    // CHECK 0: completeness — every file HF lists must exist in staging
    // at the expected size. Catches silent Xet failures before they
    // propagate into manifest generation and CDN upload. Always runs.
    try await DownloadCommand.runCompletenessCheck(
      client: client,
      modelId: resolvedModelId,
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
            modelId: resolvedModelId,
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
        Data("Downloaded \(resolvedModelId) to \(stagingURL.path) (verification skipped).\n".utf8)
      )
    }

    // ── UPLOAD PHASE (CHECKs 2–6) ────────────────────────────────────────

    let publicBaseURL = Self.resolvePublicBaseURL()

    // Resolve slug / primaryRepo / components for single-component flow.
    let manifestSlug: String
    let manifestPrimaryRepo: String
    let manifestComponents: [String]

    if let explicitSlug = slug {
      // --slug overrides the manifest's modelId; HF repo becomes primaryRepo.
      manifestSlug = explicitSlug
      manifestPrimaryRepo = resolvedModelId
      manifestComponents = [resolvedModelId]
    } else {
      manifestSlug = resolvedModelId
      manifestPrimaryRepo = resolvedModelId
      manifestComponents = [resolvedModelId]
    }

    // CHECK 2+3: generate manifest, refuse zero-byte files, verify on re-read.
    let generator = ManifestGenerator(
      modelId: manifestSlug,
      primaryRepo: manifestPrimaryRepo,
      components: manifestComponents
    )
    let reporterBox = ManifestProgressReporterBox(quiet: progressOptions.quiet)
    let manifestURL = try await generator.generate(
      directory: stagingURL,
      progress: { completed, total in
        reporterBox.handle(completed: completed, total: total)
      }
    )
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
      slug: repoSlug,
      bucket: resolvedBucket,
      endpoint: resolvedEndpoint,
      dryRun: false,
      force: force,
      quiet: progressOptions.quiet
    )

    // Upload manifest separately after sync completes.
    try await uploader.uploadManifest(
      localURL: manifestURL,
      slug: repoSlug,
      bucket: resolvedBucket,
      endpoint: resolvedEndpoint,
      dryRun: false,
      quiet: progressOptions.quiet
    )
    FileHandle.standardOutput.write(
      Data("manifest.json uploaded to CDN.\n".utf8)
    )

    // CHECK 5: verify manifest is fetchable and checksums on CDN.
    _ = try await uploader.verifyManifestOnCDN(publicBaseURL: publicBaseURL, slug: repoSlug)
    FileHandle.standardOutput.write(
      Data("CHECK 5 passed: CDN manifest verified.\n".utf8)
    )

    // CHECK 6: spot-check config.json on CDN.
    if let configEntry = manifest.files.first(where: { $0.path == "config.json" }) {
      try await uploader.spotCheckFileOnCDN(
        publicBaseURL: publicBaseURL,
        slug: repoSlug,
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
      Data("Ship complete for \(resolvedModelId).\n".utf8)
    )
  }

  // MARK: - Dry-run

  /// Dry-run implementation: generate manifest(s) from pre-staged files, write to
  /// `--output-dir` (or a unique tempdir), print each manifest path to stdout.
  ///
  /// Skips HuggingFace download, R2 upload, and all credential validation. The staging
  /// directory must already contain the model files (or a spec file's component files).
  private func runDryRun() async throws {
    let fm = FileManager.default

    // Resolve (or create) the output directory.
    let outputURL: URL
    if let explicitDir = outputDir {
      outputURL = URL(fileURLWithPath: explicitDir, isDirectory: true)
      try fm.createDirectory(at: outputURL, withIntermediateDirectories: true)
    } else {
      let tmpBase = fm.temporaryDirectory
        .appendingPathComponent("acervo-dryrun-\(UUID().uuidString)", isDirectory: true)
      try fm.createDirectory(at: tmpBase, withIntermediateDirectories: true)
      outputURL = tmpBase
      // Print the tempdir path first so callers can locate all output.
      FileHandle.standardOutput.write(Data((outputURL.path + "\n").utf8))
    }

    let stagingRoot = Self.resolveStagingRoot(override: output)

    if let specPath = spec {
      // Multi-component spec flow.
      try await runDryRunSpec(specPath: specPath, stagingRoot: stagingRoot, outputURL: outputURL)
    } else {
      // Single-component (or single-component with --slug) flow.
      guard let resolvedModelId = modelId else {
        throw ValidationError("modelId is required when --spec is not provided.")
      }
      try await runDryRunSingleComponent(
        modelId: resolvedModelId,
        stagingRoot: stagingRoot,
        outputURL: outputURL
      )
    }
  }

  /// Dry-run for a single-component model (with optional `--slug` override).
  private func runDryRunSingleComponent(
    modelId resolvedModelId: String,
    stagingRoot: URL,
    outputURL: URL
  ) async throws {
    let repoSlug = Self.slug(from: resolvedModelId)
    let stagingURL = stagingRoot.appendingPathComponent(repoSlug, isDirectory: true)

    // Resolve manifest identity fields.
    let manifestModelId: String
    let manifestPrimaryRepo: String
    let manifestComponents: [String]

    if let explicitSlug = slug {
      manifestModelId = explicitSlug
      manifestPrimaryRepo = resolvedModelId
      manifestComponents = [resolvedModelId]
    } else {
      manifestModelId = resolvedModelId
      manifestPrimaryRepo = resolvedModelId
      manifestComponents = [resolvedModelId]
    }

    let generator = ManifestGenerator(
      modelId: manifestModelId,
      primaryRepo: manifestPrimaryRepo,
      components: manifestComponents
    )
    let reporterBox = ManifestProgressReporterBox(quiet: progressOptions.quiet)
    // Generate into the staging dir, then copy to outputURL.
    let generatedURL = try await generator.generate(
      directory: stagingURL,
      progress: { completed, total in
        reporterBox.handle(completed: completed, total: total)
      }
    )

    // Copy manifest to output dir under a stable name.
    let destURL = outputURL.appendingPathComponent("\(repoSlug)-manifest.json")
    try? FileManager.default.removeItem(at: destURL)
    try FileManager.default.copyItem(at: generatedURL, to: destURL)

    FileHandle.standardOutput.write(Data((destURL.path + "\n").utf8))
  }

  /// Dry-run for a multi-component model described by a spec file.
  private func runDryRunSpec(
    specPath: String,
    stagingRoot: URL,
    outputURL: URL
  ) async throws {
    let specURL = URL(fileURLWithPath: specPath)
    let specData = try Data(contentsOf: specURL)
    let spec = try JSONDecoder().decode(MultiComponentSpec.self, from: specData)

    for componentRepo in spec.components {
      let repoSlug = Self.slug(from: componentRepo)
      let stagingURL = stagingRoot.appendingPathComponent(repoSlug, isDirectory: true)

      // Every component manifest carries the SAME modelId (the spec-level slug),
      // the SAME primaryRepo, and the SAME components array. The CDN path key
      // (slug field) is per-component (derived from componentRepo).
      let generator = ManifestGenerator(
        modelId: spec.modelId,
        componentRepo: componentRepo,
        primaryRepo: spec.primaryRepo,
        components: spec.components
      )
      let reporterBox = ManifestProgressReporterBox(quiet: progressOptions.quiet)
      let generatedURL = try await generator.generate(
        directory: stagingURL,
        progress: { completed, total in
          reporterBox.handle(completed: completed, total: total)
        }
      )

      // Copy manifest to output dir under a stable per-component name.
      let destURL = outputURL.appendingPathComponent("\(repoSlug)-manifest.json")
      try? FileManager.default.removeItem(at: destURL)
      try FileManager.default.copyItem(at: generatedURL, to: destURL)

      FileHandle.standardOutput.write(Data((destURL.path + "\n").utf8))
    }
  }

  // MARK: - hf invocation

  private func runHuggingFaceDownload(into stagingURL: URL, modelId: String) throws {
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

// MARK: - MultiComponentSpec

/// JSON spec file format for multi-component models.
///
/// Example (`flux2-spec.json`):
/// ```json
/// {
///   "modelId": "flux2-klein-4b",
///   "primaryRepo": "black-forest-labs/FLUX.2-klein-4B",
///   "components": [
///     "black-forest-labs/FLUX.2-klein-4B",
///     "black-forest-labs/FLUX.2-vae",
///     "google/t5-v1_1-xxl"
///   ]
/// }
/// ```
struct MultiComponentSpec: Codable {
  /// The shared slug-level model identifier written into every component manifest.
  let modelId: String
  /// The slug-level canonical "main" repo, written into every component manifest as `primaryRepo`.
  let primaryRepo: String
  /// All HF repos that belong to this slug. One manifest is generated per entry.
  let components: [String]
}
