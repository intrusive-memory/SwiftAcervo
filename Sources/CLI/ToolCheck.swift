import Foundation

/// Errors surfaced by the `acervo` CLI tool.
///
/// Cases are CLI-facing surfaces — none of them leak into the library
/// (`Sources/SwiftAcervo/`). The library has its own `AcervoError`.
enum AcervoToolError: Error, CustomStringConvertible {
  /// A required external CLI tool was not found on `PATH`.
  case missingTool(String)

  /// A file in the staging directory is zero bytes. Surfaced by the
  /// manifest generator before any upload begins (CHECK 2).
  case zeroByteFile(String)

  /// After writing `manifest.json`, the re-read manifest's
  /// `manifestChecksum` did not match the recomputed checksum
  /// (CHECK 3).
  case manifestChecksumMismatch(path: String)

  /// A file listed in the manifest was mutated between manifest
  /// generation and the pre-upload integrity sweep (CHECK 4).
  case stagingMutation(filename: String, expected: String, actual: String)

  /// A file served by the CDN did not match the SHA-256 recorded
  /// in the manifest (CHECK 6).
  case cdnChecksumMismatch(filename: String, expected: String, actual: String)

  /// An external subprocess (e.g. `hf download`) exited with a non-zero
  /// status. `stderr` carries the captured error output.
  case subprocessFailed(command: String, exitCode: Int32, stderr: String)

  /// A CDN HTTP fetch did not return HTTP 200.
  case cdnHTTPStatus(url: String, statusCode: Int)

  /// The CDN manifest decoded successfully but failed
  /// `CDNManifest.verifyChecksum()` (CHECK 5).
  case cdnManifestChecksumInvalid(url: String)

  /// A required environment variable was not set when invoking the CLI.
  case missingEnvironmentVariable(String)

  /// A destructive subcommand was invoked without `--yes` and stdin is
  /// not attached to a TTY (typically: piped input, CI). The operator
  /// must explicitly opt in via `--yes` so we never destroy data on a
  /// non-interactive host.
  case confirmationRequired

  /// A file enumerated under a staging base directory could not be
  /// expressed as a relative path under that base. This indicates a
  /// path-representation mismatch between the base URL and the
  /// enumerator's child URL (for example, `/tmp` vs `/private/tmp`)
  /// that survived symlink resolution. Surfaced as a hard error rather
  /// than silently falling back to `lastPathComponent`, which would
  /// produce a manifest with ambiguous duplicate paths for nested
  /// layouts (HF repos with `text_encoder/`, `tokenizer/`, `vae/`
  /// subdirectories).
  case relativePathOutsideBase(file: String, base: String)

  var description: String {
    switch self {
    case .missingTool(let name):
      return "Required tool not found on PATH: \(name)"
    case .zeroByteFile(let path):
      return "Refusing to write manifest: zero-byte file in staging: \(path)"
    case .manifestChecksumMismatch(let path):
      return "Post-write manifest checksum mismatch at \(path) (CHECK 3 failed)"
    case .stagingMutation(let filename, let expected, let actual):
      return
        "Staging mutation detected for \(filename) (CHECK 4 failed): expected \(expected), got \(actual)"
    case .cdnChecksumMismatch(let filename, let expected, let actual):
      return
        "CDN checksum mismatch for \(filename) (CHECK 6 failed): expected \(expected), got \(actual)"
    case .subprocessFailed(let command, let exitCode, let stderr):
      return "subprocess failed (\(command)) with exit code \(exitCode): \(stderr)"
    case .cdnHTTPStatus(let url, let statusCode):
      return "CDN fetch failed for \(url): HTTP \(statusCode)"
    case .cdnManifestChecksumInvalid(let url):
      return "CDN manifest at \(url) failed verifyChecksum() (CHECK 5 failed)"
    case .missingEnvironmentVariable(let name):
      return "Required environment variable not set: \(name)"
    case .confirmationRequired:
      return
        "This is a destructive operation and stdin is not a TTY. Re-run with --yes to confirm non-interactively."
    case .relativePathOutsideBase(let file, let base):
      return
        "Cannot compute relative path: \(file) is not contained in \(base). Refusing to fall back to basename, which would produce ambiguous manifest entries."
    }
  }
}

/// Validates that external CLI tools required by `acervo` are available on
/// `PATH`. After the v0.14.x cleanup the only external tool the CLI shells
/// out to is the HuggingFace CLI (`hf`); R2 traffic is driven through the
/// native publish pipeline in `SwiftAcervo`.
enum ToolCheck {
  /// Verify that `hf` is available on `PATH`.
  ///
  /// On any missing tool, prints the matching Homebrew hint to stderr
  /// and throws `AcervoToolError.missingTool`. Succeeds silently when
  /// the tool is present.
  static func validate() throws {
    if !isToolAvailable(name: "hf") {
      let message =
        "error: required tool 'hf' not found on PATH. Install it with: brew install huggingface-hub\n"
      FileHandle.standardError.write(Data(message.utf8))
      throw AcervoToolError.missingTool("hf")
    }
  }

  /// Public-to-the-CLI version of `isToolAvailable`. Subcommands that
  /// only depend on a specific tool can call this directly instead of
  /// going through `validate()`.
  static func isToolOnPath(name: String) -> Bool {
    isToolAvailable(name: name)
  }

  // MARK: - Private

  /// Invokes `/usr/bin/which <name>` and returns whether it exited 0.
  ///
  /// Uses a synchronous `Process.run()` + `waitUntilExit()` pattern so no
  /// concurrency hopping is required under Swift 6 strict concurrency.
  private static func isToolAvailable(name: String) -> Bool {
    #if os(macOS)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
      process.arguments = [name]

      // Silence stdout/stderr from `which`; we only care about exit status.
      let devNull = FileHandle(forWritingAtPath: "/dev/null")
      if let devNull {
        process.standardOutput = devNull
        process.standardError = devNull
      }

      do {
        try process.run()
      } catch {
        return false
      }
      process.waitUntilExit()
      return process.terminationStatus == 0
    #else
      return false
    #endif
  }
}
