import Foundation

/// Shared subprocess launcher for acervo.
///
/// Historically every command built a `Process`, wired stdout/stderr
/// through `Pipe()` instances, drained them into `Data`, and discarded
/// stdout on success — which meant the `hf` and `aws` subprocesses were
/// running silently with their own progress bars never reaching the
/// user's terminal.
///
/// `ProcessRunner.run` changes the default so that, unless the caller
/// passes `quiet: true`, stdout and stderr are inherited from the parent
/// process. That lets `hf download`'s file-level progress and
/// `aws s3 sync`'s transfer progress flow through to the user live. In
/// quiet mode we preserve the old drain-and-capture behaviour so stderr
/// is still available for error messages and pipe buffers cannot fill.
enum ProcessRunner {

  /// Result of a finished subprocess.
  struct Result: Sendable {
    let exitCode: Int32
    /// stderr captured in quiet mode; empty string in the live-stdio mode.
    let capturedStderr: String
  }

  /// Runs a subprocess synchronously.
  ///
  /// - Parameters:
  ///   - executableURL: Absolute path to the executable (typically
  ///     `/usr/bin/env` so the argv starts with the program name).
  ///   - arguments: Argv to pass. When using `/usr/bin/env`, element 0
  ///     is the program name.
  ///   - environment: Process environment. `nil` means inherit.
  ///   - quiet: When `true`, drain stdout/stderr through pipes and
  ///     capture stderr for error reporting. When `false`, inherit the
  ///     parent's stdout/stderr so subprocess progress bars pass through.
  /// - Throws: `AcervoToolError.awsProcessFailed` when `Process.run`
  ///   itself fails to launch the binary.
  static func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String]? = nil,
    quiet: Bool,
    label: String
  ) throws -> Result {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    if let environment {
      process.environment = environment
    }

    var stderrPipe: Pipe? = nil
    var stdoutPipe: Pipe? = nil

    if quiet {
      let outPipe = Pipe()
      let errPipe = Pipe()
      stdoutPipe = outPipe
      stderrPipe = errPipe
      process.standardOutput = outPipe
      process.standardError = errPipe
    } else {
      // Let the subprocess talk directly to the user's terminal. This is
      // what makes `hf download` and `aws s3 sync` render their native
      // progress bars. In non-TTY contexts (CI logs, pipes) the child
      // will still emit its regular line-oriented output, which is what
      // we want there too.
      process.standardOutput = FileHandle.standardOutput
      process.standardError = FileHandle.standardError
    }

    do {
      try process.run()
    } catch {
      throw AcervoToolError.awsProcessFailed(
        command: label,
        exitCode: -1,
        stderr: "failed to launch \(label): \(error.localizedDescription)"
      )
    }

    var capturedStderr = ""
    if quiet, let stdoutPipe, let stderrPipe {
      // Drain pipes before waitUntilExit() so the child cannot deadlock
      // on a full pipe buffer during a long transfer.
      _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
      let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
      capturedStderr = String(data: stderrData, encoding: .utf8) ?? "<non-utf8 stderr>"
    }

    process.waitUntilExit()
    return Result(exitCode: process.terminationStatus, capturedStderr: capturedStderr)
  }
}
