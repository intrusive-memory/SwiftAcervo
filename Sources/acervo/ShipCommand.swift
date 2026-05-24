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
///
/// **Slug-registry surface (DC-1)**:
/// - `--slug <slug>` overrides the manifest's `modelId` so the slug
///   diverges from the HF repo string (the HF repo becomes
///   `primaryRepo`).
/// - `--spec <path>` loads a multi-component spec JSON describing
///   `modelId` / `primaryRepo` / `components`. Live mode iterates
///   components: per-component HF download, then one
///   `PublishRunner.run(...)` per component using the SHARED triple so
///   every manifest carries the same slug-registry fields.
/// - `--dry-run` skips ToolCheck, HF download, credential resolution,
///   and PublishRunner. It generates manifest(s) into `--output-dir`
///   (or a temp dir) and prints absolute paths to stdout.
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
        acervo ship org/repo --slug my-slug --dry-run --output-dir /tmp/manifests
        acervo ship --spec /path/to/spec.json --dry-run --output-dir /tmp/manifests
      """
  )

  // MARK: - Download options

  @Argument(
    help: "HuggingFace model identifier in 'org/repo' form. Omit when using --spec."
  )
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

  // MARK: - Slug-registry options (DC-1)

  @Option(
    name: .customLong("slug"),
    help:
      "Override the manifest's modelId with this slug (single-component flow). The HF repo becomes primaryRepo. Mutually exclusive with --spec."
  )
  var slug: String?

  @Option(
    name: .customLong("spec"),
    help:
      "Path to a JSON spec file with modelId/primaryRepo/components. Live mode iterates components; --dry-run generates one manifest per component. Mutually exclusive with the positional modelId and --slug."
  )
  var spec: String?

  @Option(
    name: .customLong("output-dir"),
    help:
      "Destination directory for --dry-run manifest files. Defaults to a unique tempdir under NSTemporaryDirectory()."
  )
  var outputDir: String?

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
      "Generate manifest(s) into --output-dir (or a tempdir) without contacting HF or the CDN. Skips ToolCheck, HF download, credential resolution, and PublishRunner."
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

  // MARK: - validate()

  /// Enforces the modelId-vs-spec mutual-exclusivity rule.
  ///
  /// One of {positional `modelId`, `--spec`} must be supplied. Supplying
  /// both is an error (the spec encodes its own modelId; the positional
  /// would be ambiguous). `--slug` is single-component-only and rejected
  /// alongside `--spec`.
  func validate() throws {
    if spec != nil && modelId != nil {
      throw ValidationError(
        "Cannot combine --spec with a positional modelId. --spec encodes its own modelId."
      )
    }
    if spec != nil && slug != nil {
      throw ValidationError(
        "Cannot combine --spec with --slug. --spec encodes its own modelId."
      )
    }
    if spec == nil && modelId == nil {
      throw ValidationError(
        "Missing argument: provide a positional modelId (HF org/repo) or --spec <path>."
      )
    }
  }

  // MARK: - run()

  func run() async throws {
    // ── DRY-RUN SHORT-CIRCUIT (no credentials, no HF, no CDN) ────────────
    //
    // Per DC-1 exit criteria: --dry-run skips ToolCheck.validate(), skips
    // HF download, skips credential resolution, and skips
    // PublishRunner.run(...). Manifest generation runs against the
    // already-staged directory tree.
    if dryRun {
      try await runDryRun()
      return
    }

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

    if let specPath = spec {
      try await runLiveSpec(
        specPath: specPath,
        stagingRoot: stagingRoot,
        credentials: credentials
      )
      return
    }

    // ── Single-component live path (positional modelId, optional --slug) ─

    guard let resolvedModelId = modelId else {
      // `validate()` should have caught this; defensive fallback.
      throw ValidationError("modelId is required when --spec is not provided.")
    }

    try await runLiveSingleComponent(
      modelId: resolvedModelId,
      stagingRoot: stagingRoot,
      credentials: credentials
    )
  }

  // MARK: - Live: single-component

  /// Runs the full download → CHECK 0 / CHECK 1 → publish pipeline for a
  /// single HuggingFace repo. Honors `--slug` to divorce the slug from the
  /// HF repo string in the manifest.
  private func runLiveSingleComponent(
    modelId resolvedModelId: String,
    stagingRoot: URL,
    credentials: AcervoCDNCredentials
  ) async throws {
    let repoSlug = Self.slug(from: resolvedModelId)
    let stagingURL = stagingRoot.appendingPathComponent(repoSlug, isDirectory: true)

    try FileManager.default.createDirectory(
      at: stagingURL,
      withIntermediateDirectories: true
    )

    // ── DOWNLOAD PHASE (CHECK 0 + CHECK 1) ───────────────────────────────

    try runHuggingFaceDownload(into: stagingURL, modelId: resolvedModelId)

    let client = HuggingFaceClient()

    // CHECK 0: completeness — every file HF lists must exist in staging
    // at the expected size.
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
      try await runLFSVerification(
        client: client,
        modelId: resolvedModelId,
        stagingURL: stagingURL
      )
    } else {
      FileHandle.standardOutput.write(
        Data(
          "Downloaded \(resolvedModelId) to \(stagingURL.path) (verification skipped).\n".utf8
        )
      )
    }

    // ── UPLOAD PHASE (delegated to Acervo.publishModel) ──────────────────

    // Resolve slug-registry triple. When --slug is supplied the manifest's
    // modelId is the user-supplied slug, primaryRepo is the HF repo, and
    // components is a one-element array of the HF repo. Without --slug the
    // defaults (primaryRepo == modelId, components == [modelId]) apply.
    let manifestModelId: String
    let manifestPrimaryRepo: String?
    let manifestComponents: [String]?
    if let explicitSlug = slug {
      manifestModelId = explicitSlug
      manifestPrimaryRepo = resolvedModelId
      manifestComponents = [resolvedModelId]
    } else {
      manifestModelId = resolvedModelId
      manifestPrimaryRepo = nil
      manifestComponents = nil
    }

    let reporter = PublishProgressReporter(
      quiet: progressOptions.quiet,
      style: .ship
    )
    _ = try await PublishRunner.run(
      modelId: manifestModelId,
      directory: stagingURL,
      credentials: credentials,
      keepOrphans: keepOrphans,
      progress: { event in reporter.handle(event) },
      primaryRepo: manifestPrimaryRepo,
      components: manifestComponents,
      slugOverride: nil
    )

    FileHandle.standardOutput.write(
      Data("Ship complete for \(resolvedModelId).\n".utf8)
    )
  }

  // MARK: - Live: --spec multi-component

  /// Loads the spec, iterates `components`, and runs the per-component
  /// HF download → publish pipeline. Every component's manifest carries
  /// the SHARED `(modelId, primaryRepo, components)` triple from the spec
  /// file; only the per-component CDN slug differs (derived from each
  /// component's own HF repo string via `slugOverride`).
  private func runLiveSpec(
    specPath: String,
    stagingRoot: URL,
    credentials: AcervoCDNCredentials
  ) async throws {
    let loadedSpec = try Self.loadSpec(at: specPath)

    for componentRepo in loadedSpec.components {
      let repoSlug = Self.slug(from: componentRepo)
      let stagingURL = stagingRoot.appendingPathComponent(repoSlug, isDirectory: true)

      try FileManager.default.createDirectory(
        at: stagingURL,
        withIntermediateDirectories: true
      )

      // Per-component HF download.
      try runHuggingFaceDownload(into: stagingURL, modelId: componentRepo)

      let client = HuggingFaceClient()
      try await DownloadCommand.runCompletenessCheck(
        client: client,
        modelId: componentRepo,
        requestedFiles: [],
        stagingURL: stagingURL
      )
      FileHandle.standardOutput.write(
        Data("CHECK 0 passed for \(componentRepo): staging matches HF tree.\n".utf8)
      )

      if !noVerify {
        try await runLFSVerification(
          client: client,
          modelId: componentRepo,
          stagingURL: stagingURL
        )
      }

      // Publish using the SHARED triple from the spec. slugOverride is the
      // component's own HF repo so the CDN prefix becomes
      // `models/<component-org_component-repo>/`; manifest.modelId carries
      // the spec-level slug.
      let reporter = PublishProgressReporter(
        quiet: progressOptions.quiet,
        style: .ship
      )
      _ = try await PublishRunner.run(
        modelId: loadedSpec.modelId,
        directory: stagingURL,
        credentials: credentials,
        keepOrphans: keepOrphans,
        progress: { event in reporter.handle(event) },
        primaryRepo: loadedSpec.primaryRepo,
        components: loadedSpec.components,
        slugOverride: componentRepo
      )

      FileHandle.standardOutput.write(
        Data("Ship complete for component \(componentRepo).\n".utf8)
      )
    }

    FileHandle.standardOutput.write(
      Data(
        "Ship complete for spec \(loadedSpec.modelId) (\(loadedSpec.components.count) component(s)).\n"
          .utf8)
    )
  }

  // MARK: - Dry-run

  /// Dry-run entry point. Skips ToolCheck, credential resolution, HF
  /// download, and PublishRunner. Generates manifest(s) into
  /// `--output-dir` (or a unique tempdir under `NSTemporaryDirectory()`)
  /// and prints each manifest's absolute path to stdout. Both single-
  /// component and `--spec` multi-component paths are supported.
  private func runDryRun() async throws {
    let fm = FileManager.default

    // Resolve or create the output directory. When --output-dir is
    // supplied we use it directly; otherwise we mint a tempdir and print
    // its path first so callers can locate every manifest.
    let outputURL: URL
    if let explicitDir = outputDir, !explicitDir.isEmpty {
      outputURL = URL(fileURLWithPath: explicitDir, isDirectory: true)
      try fm.createDirectory(at: outputURL, withIntermediateDirectories: true)
    } else {
      outputURL = fm.temporaryDirectory.appendingPathComponent(
        "acervo-dry-run-\(UUID().uuidString)",
        isDirectory: true
      )
      try fm.createDirectory(at: outputURL, withIntermediateDirectories: true)
      FileHandle.standardOutput.write(Data((outputURL.path + "\n").utf8))
    }

    let stagingRoot = Self.resolveStagingRoot(override: output)

    if let specPath = spec {
      try await runDryRunSpec(specPath: specPath, stagingRoot: stagingRoot, outputURL: outputURL)
    } else {
      guard let resolvedModelId = modelId else {
        // validate() should have caught this; defensive fallback.
        throw ValidationError("modelId is required when --spec is not provided.")
      }
      try await runDryRunSingleComponent(
        modelId: resolvedModelId,
        stagingRoot: stagingRoot,
        outputURL: outputURL
      )
    }
  }

  /// Single-component dry-run. Resolves the slug-registry triple the
  /// same way the live single-component path does, then drives the
  /// generator against the existing staging tree.
  private func runDryRunSingleComponent(
    modelId resolvedModelId: String,
    stagingRoot: URL,
    outputURL: URL
  ) async throws {
    let repoSlug = Self.slug(from: resolvedModelId)
    let stagingURL = stagingRoot.appendingPathComponent(repoSlug, isDirectory: true)

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
    let generatedURL = try await generator.generate(
      directory: stagingURL,
      progress: { completed, total in
        reporterBox.handle(completed: completed, total: total)
      }
    )

    // Copy the generated manifest into the output dir under a stable
    // per-component filename.
    let destURL = outputURL.appendingPathComponent("\(repoSlug)-manifest.json")
    try? FileManager.default.removeItem(at: destURL)
    try FileManager.default.copyItem(at: generatedURL, to: destURL)

    FileHandle.standardOutput.write(Data((destURL.path + "\n").utf8))
  }

  /// Multi-component dry-run. Iterates `spec.components`, generates one
  /// manifest per component using the shared triple, and copies each to
  /// `outputURL` under `<component-slug>-manifest.json`.
  private func runDryRunSpec(
    specPath: String,
    stagingRoot: URL,
    outputURL: URL
  ) async throws {
    let loadedSpec = try Self.loadSpec(at: specPath)

    for componentRepo in loadedSpec.components {
      let repoSlug = Self.slug(from: componentRepo)
      let stagingURL = stagingRoot.appendingPathComponent(repoSlug, isDirectory: true)

      // Every component's manifest carries the same modelId, primaryRepo,
      // and components array. Only the CDN slug differs, derived from the
      // component's own HF repo via slugOverride.
      let generator = ManifestGenerator(
        modelId: loadedSpec.modelId,
        primaryRepo: loadedSpec.primaryRepo,
        components: loadedSpec.components,
        slugOverride: componentRepo
      )
      let reporterBox = ManifestProgressReporterBox(quiet: progressOptions.quiet)
      let generatedURL = try await generator.generate(
        directory: stagingURL,
        progress: { completed, total in
          reporterBox.handle(completed: completed, total: total)
        }
      )

      let destURL = outputURL.appendingPathComponent("\(repoSlug)-manifest.json")
      try? FileManager.default.removeItem(at: destURL)
      try FileManager.default.copyItem(at: generatedURL, to: destURL)

      FileHandle.standardOutput.write(Data((destURL.path + "\n").utf8))
    }
  }

  // MARK: - LFS verification

  /// CHECK 1: re-hash every downloaded file and assert it matches the
  /// HuggingFace LFS API. Extracted from `run()` so both single-component
  /// and `--spec` live paths reuse it.
  private func runLFSVerification(
    client: HuggingFaceClient,
    modelId: String,
    stagingURL: URL
  ) async throws {
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

  /// Loads and decodes a multi-component spec file. Surfaces JSON-decode
  /// errors directly so callers see the underlying problem (missing
  /// `modelId`, malformed `components`, etc.).
  private static func loadSpec(at path: String) throws -> MultiComponentSpec {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(MultiComponentSpec.self, from: data)
  }
}

// MARK: - MultiComponentSpec

/// JSON spec format consumed by `acervo ship --spec`.
///
/// ```json
/// {
///   "modelId": "flux2-klein-4b",
///   "primaryRepo": "black-forest-labs/FLUX.2-klein-4B",
///   "components": [
///     "black-forest-labs/FLUX.2-klein-4B"
///   ]
/// }
/// ```
///
/// Every component listed in `components` is downloaded, hashed, and
/// shipped. Every produced manifest carries the SAME `modelId`,
/// `primaryRepo`, and `components` values — only the CDN `slug` (and
/// therefore the per-component CDN prefix) differs.
struct MultiComponentSpec: Codable, Sendable {
  /// Shared slug-level identifier written into every component manifest's
  /// `modelId` field.
  let modelId: String

  /// Slug-level canonical "main" repo. Written into every component
  /// manifest's `primaryRepo` field.
  let primaryRepo: String

  /// All HF repos that belong to this slug. One manifest is generated
  /// per entry.
  let components: [String]
}
