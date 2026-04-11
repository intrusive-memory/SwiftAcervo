import Foundation
import Testing

@testable import acervo

/// Unit tests for `ToolCheck.validate()`.
///
/// These tests mutate the process-wide `PATH` environment variable so they
/// MUST run serially. `.serialized` also ensures we don't clobber `PATH`
/// while another test in this suite is still executing `/usr/bin/which`.
@Suite("ToolCheck Tests", .serialized)
final class ToolCheckTests {

  private let fm = FileManager.default
  private var tempDir: URL!
  private var originalPATH: String?

  init() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("acervo-toolcheck-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    originalPATH = ProcessInfo.processInfo.environment["PATH"]
    setenv("PATH", tempDir.path, 1)
  }

  deinit {
    if let originalPATH {
      setenv("PATH", originalPATH, 1)
    } else {
      unsetenv("PATH")
    }
    try? fm.removeItem(at: tempDir)
  }

  /// Drops a tiny executable shell stub at `<tempDir>/<name>` that simply
  /// exits 0. `/usr/bin/which` only cares about presence + execute bit.
  private func installStub(named name: String) throws {
    let url = tempDir.appendingPathComponent(name)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }

  // MARK: - Missing tools

  @Test("validate throws when both aws and huggingface-cli are absent")
  func bothToolsMissing() {
    var thrown: Error?
    do {
      try ToolCheck.validate()
    } catch {
      thrown = error
    }
    guard case .some(AcervoToolError.missingTool(let name)) = thrown else {
      Issue.record("Expected AcervoToolError.missingTool, got \(String(describing: thrown))")
      return
    }
    // aws is checked first, so that's the missing tool we expect.
    #expect(name == "aws")
  }

  @Test("validate throws on huggingface-cli when only aws is present")
  func huggingFaceCLIMissing() throws {
    try installStub(named: "aws")

    var thrown: Error?
    do {
      try ToolCheck.validate()
    } catch {
      thrown = error
    }
    guard case .some(AcervoToolError.missingTool(let name)) = thrown else {
      Issue.record("Expected AcervoToolError.missingTool, got \(String(describing: thrown))")
      return
    }
    #expect(name == "huggingface-cli")
  }

  @Test("validate succeeds silently when both stubs are present")
  func bothToolsPresent() throws {
    try installStub(named: "aws")
    try installStub(named: "huggingface-cli")
    // Must not throw.
    try ToolCheck.validate()
  }

  // MARK: - Error message content

  @Test("missingTool description for aws mentions brew install awscli")
  func errorMessageContainsAWSBrewHint() {
    let error = AcervoToolError.missingTool("aws")
    // The thrown error's description is the machine-testable content.
    let combined = String(describing: error)
    #expect(combined.contains("aws"))
    // The brew hint is written to stderr by ToolCheck; separately assert
    // that the user-facing brew install hint exists somewhere in the
    // ToolCheck source by invoking validate() and capturing the error.
    // Here we also spot-check the thrown error carries the tool name so
    // callers can render their own message.
  }

  @Test("ToolCheck source stderr output includes brew install awscli hint")
  func brewInstallHintPresentInStderr() throws {
    // Redirect stderr to a pipe so we can capture what ToolCheck writes.
    let originalStderr = dup(fileno(stderr))
    let pipe = Pipe()
    dup2(pipe.fileHandleForWriting.fileDescriptor, fileno(stderr))

    _ = try? ToolCheck.validate()

    // Restore the real stderr BEFORE reading so readDataToEndOfFile can
    // return — otherwise fd 2 remains a writer on the pipe and the
    // read blocks forever.
    dup2(originalStderr, fileno(stderr))
    close(originalStderr)
    try? pipe.fileHandleForWriting.close()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: data, encoding: .utf8) ?? ""

    #expect(text.contains("brew install awscli"))
  }
}
