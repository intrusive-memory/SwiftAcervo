import ArgumentParser
import Foundation
import SwiftAcervo

/// Downloads a model (or a subset of its files) from HuggingFace into the
/// staging directory and runs CHECK 1 (`HuggingFaceClient.verifyLFS`) on
/// every downloaded file.
///
/// The command shells out to `hf download` for the actual
/// transfer and then walks the staging directory hashing each file with
/// `IntegrityVerification.sha256(of:)`. When the locally-computed hash
/// does not match the `oid` HuggingFace advertises for that file, the
/// staging file is deleted and the command exits non-zero with a per-file
/// error message.
struct DownloadCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "download",
    abstract: "Download a model from HuggingFace into the staging directory.",
    discussion: """
      Shells out to `hf download` and then verifies every downloaded file's
      SHA-256 against the HuggingFace LFS API (CHECK 1). Files whose hash
      does not match are deleted and the command exits non-zero.

      The staging directory is: $STAGING_DIR/<slug>  or  /tmp/acervo-staging/<slug>
      where <slug> is the model ID with '/' replaced by '_'.

      REQUIRED TOOLS
        hf   HuggingFace CLI (brew install huggingface-hub)

      REQUIRED ENVIRONMENT VARIABLES
        HF_TOKEN   Required for private or gated models (or pass --token)

      EXAMPLES
        acervo download mlx-community/Qwen2.5-7B-Instruct-4bit
        acervo download mlx-community/Qwen2.5-7B-Instruct-4bit config.json tokenizer.json
        acervo download mlx-community/Qwen2.5-7B-Instruct-4bit --output /tmp/my-staging --no-verify
      """
  )

  @Argument(help: "HuggingFace model identifier in 'org/repo' form.")
  var modelId: String

  @Argument(help: "Optional subset of files to download. Defaults to the whole repo.")
  var files: [String] = []

  @Option(
    name: [.short, .customLong("source")], help: "Source registry (only 'hf' is supported today).")
  var source: String = "hf"

  @Option(
    name: [.short, .customLong("output")],
    help: "Override staging directory root (default: $STAGING_DIR or /tmp/acervo-staging).")
  var output: String?

  @Option(
    name: [.short, .customLong("token")],
    help: "HuggingFace token. Falls back to $HF_TOKEN when unset.")
  var token: String?

  @Flag(
    name: .customLong("no-verify"), help: "Skip HuggingFace LFS SHA-256 verification (CHECK 1).")
  var noVerify: Bool = false

  @OptionGroup var progressOptions: ProgressOptions

  func run() async throws {
    try ToolCheck.validate()

    guard source == "hf" else {
      throw ValidationError("Unsupported --source '\(source)'. Only 'hf' is supported.")
    }

    let stagingRoot = Self.resolveStagingRoot(override: output)
    let slug = Self.slug(from: modelId)
    let stagingURL = stagingRoot.appendingPathComponent(slug, isDirectory: true)

    try FileManager.default.createDirectory(
      at: stagingURL,
      withIntermediateDirectories: true
    )

    try runHuggingFaceDownload(into: stagingURL)

    let client = HuggingFaceClient()

    // CHECK 0: confirm every file in HF's tree exists in staging at
    // the expected size. This catches Xet-backed downloads where `hf`
    // wrote only metadata sidecars, before we get to LFS verification
    // (which would mask the symptom as "all files 404 from LFS API").
    // Runs even with --no-verify because incompleteness is a different
    // failure mode from checksum mismatch.
    try await runCompletenessCheck(client: client, stagingURL: stagingURL)

    guard !noVerify else {
      FileHandle.standardOutput.write(
        Data("Downloaded \(modelId) to \(stagingURL.path) (LFS verification skipped).\n".utf8)
      )
      return
    }

    let discovered = try Self.enumerateDownloadedFiles(in: stagingURL)

    let reporter = ProgressReporter(
      label: "Verifying HF LFS: ",
      total: discovered.count,
      quiet: progressOptions.quiet
    )
    var failures: [String] = []
    var lfsAllNotFound = !discovered.isEmpty
    for (relativePath, fileURL) in discovered {
      defer { reporter.advance() }
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
      Data("Downloaded and verified \(modelId) at \(stagingURL.path)\n".utf8)
    )
  }

  // MARK: - Completeness check (CHECK 0)

  /// Compares every file in HF's tree listing against the staged copy
  /// and aborts the pipeline on any size mismatch or missing file.
  /// Shared by `download` and `ship`.
  static func runCompletenessCheck(
    client: HuggingFaceClient,
    modelId: String,
    requestedFiles: [String],
    stagingURL: URL
  ) async throws {
    let failures: [HFCompletenessFailure]
    do {
      failures = try await client.verifyDownloadCompleteness(
        modelId: modelId,
        stagingURL: stagingURL,
        requestedFiles: requestedFiles
      )
    } catch let treeError as HFTreeError {
      let message =
        "error: failed to fetch HuggingFace file tree for \(modelId): \(treeError.description)\n"
      FileHandle.standardError.write(Data(message.utf8))
      throw ExitCode.failure
    }

    guard failures.isEmpty else {
      let anyXet = failures.contains(where: { $0.isXet })
      let body = failures.map { $0.description }.joined(separator: "\n")
      var message =
        "error: download is incomplete (\(failures.count) file\(failures.count == 1 ? "" : "s") missing or wrong size):\n\(body)\n"
      if anyXet {
        message += """

          hint: at least one offending file is Xet-backed. acervo sets
                HF_HUB_ENABLE_HF_XET=1 internally, so this typically means
                an outdated huggingface_hub or hf_xet install — try:
                    pip install --upgrade huggingface-hub hf_xet

          """
      }
      FileHandle.standardError.write(Data(message.utf8))
      throw ExitCode.failure
    }
  }

  /// Instance-method overload that forwards to the static helper using
  /// the command's bound `modelId` and `files` properties.
  private func runCompletenessCheck(
    client: HuggingFaceClient,
    stagingURL: URL
  ) async throws {
    try await Self.runCompletenessCheck(
      client: client,
      modelId: modelId,
      requestedFiles: files,
      stagingURL: stagingURL
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

  /// Walks `stagingURL` recursively and returns every regular file with
  /// its relative path. Skips `.huggingface/` metadata and hidden cruft
  /// so we only verify files that match the manifest layout.
  static func enumerateDownloadedFiles(in stagingURL: URL) throws -> [(String, URL)] {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: stagingURL.path, isDirectory: &isDir), isDir.boolValue else {
      return []
    }

    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
    guard
      let enumerator = fm.enumerator(
        at: stagingURL,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else {
      return []
    }

    let excludedNames: Set<String> = ["manifest.json", ".DS_Store"]
    let excludedPrefixes: [String] = [".huggingface/"]

    var results: [(String, URL)] = []

    for case let fileURL as URL in enumerator {
      // Use the same path-components-based relative-path computation as
      // ManifestGenerator so nested HuggingFace layouts (e.g.
      // text_encoder/, tokenizer/, vae/) yield correct relative paths
      // for HF LFS verification (CHECK 1).
      let relative = try ManifestGenerator.relativePath(of: fileURL, under: stagingURL)

      if excludedNames.contains(fileURL.lastPathComponent) { continue }
      if excludedPrefixes.contains(where: { relative.hasPrefix($0) }) { continue }

      let values = try fileURL.resourceValues(forKeys: Set(keys))
      guard values.isRegularFile == true else { continue }
      if values.isSymbolicLink == true { continue }

      results.append((relative, fileURL))
    }
    results.sort { $0.0 < $1.0 }
    return results
  }
}
