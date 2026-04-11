import Foundation

/// Errors surfaced by the `acervo` CLI tool.
///
/// Additional cases are added by later sorties; this enum is intentionally
/// open-ended and only needs to carry enough cases to satisfy the current
/// sortie's compile surface.
enum AcervoToolError: Error, CustomStringConvertible {
  /// A required external CLI tool was not found on `PATH`.
  case missingTool(String)

  /// A file in the staging directory is zero bytes. The manifest
  /// generator refuses to write a manifest that references a
  /// zero-byte file (CHECK 2 from the acervo tool requirements).
  case zeroByteFile(String)

  /// After writing `manifest.json`, the re-read manifest's
  /// `manifestChecksum` did not match the recomputed checksum
  /// (CHECK 3 from the acervo tool requirements).
  case manifestChecksumMismatch(path: String)

  var description: String {
    switch self {
    case .missingTool(let name):
      return "Required tool not found on PATH: \(name)"
    case .zeroByteFile(let path):
      return "Refusing to write manifest: zero-byte file in staging: \(path)"
    case .manifestChecksumMismatch(let path):
      return "Post-write manifest checksum mismatch at \(path) (CHECK 3 failed)"
    }
  }
}

/// Validates that external CLI tools required by `acervo` are available on
/// `PATH`. Call `ToolCheck.validate()` early in any command that shells out
/// to `aws` or `huggingface-cli`.
enum ToolCheck {
  /// Verify that both `aws` and `huggingface-cli` are available on `PATH`.
  ///
  /// On any missing tool, prints the matching Homebrew hint to stderr
  /// and throws `AcervoToolError.missingTool`. Succeeds silently when
  /// both tools are present.
  static func validate() throws {
    if !isToolAvailable(name: "aws") {
      let message =
        "error: required tool 'aws' not found on PATH. Install it with: brew install awscli\n"
      FileHandle.standardError.write(Data(message.utf8))
      throw AcervoToolError.missingTool("aws")
    }

    if !isToolAvailable(name: "huggingface-cli") {
      let message =
        "error: required tool 'huggingface-cli' not found on PATH. Install it with: brew install huggingface-hub\n"
      FileHandle.standardError.write(Data(message.utf8))
      throw AcervoToolError.missingTool("huggingface-cli")
    }
  }

  // MARK: - Private

  /// Invokes `/usr/bin/which <name>` and returns whether it exited 0.
  ///
  /// Uses a synchronous `Process.run()` + `waitUntilExit()` pattern so no
  /// concurrency hopping is required under Swift 6 strict concurrency.
  private static func isToolAvailable(name: String) -> Bool {
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
  }
}
