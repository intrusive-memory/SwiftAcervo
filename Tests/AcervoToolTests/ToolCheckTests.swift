#if os(macOS)
  import Foundation
  import Testing

  @testable import acervo

  extension ProcessEnvironmentSuite {
    /// Unit tests for `ToolCheck.validate()`.
    ///
    /// These tests mutate the process-wide `PATH` environment variable so they
    /// MUST run serially. The `.serialized` trait is provided by the parent
    /// `ProcessEnvironmentSuite`.
    ///
    /// After the v0.14.x CLI consolidation `ToolCheck.validate()` only needs
    /// `hf` on PATH — the `aws` binary is no longer a runtime dependency.
    @Suite("ToolCheck Tests")
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

      @Test("validate throws missingTool('hf') when hf is absent")
      func hfMissing() {
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
        #expect(name == "hf")
      }

      @Test("validate succeeds silently when hf is present")
      func hfPresent() throws {
        try installStub(named: "hf")
        // Must not throw.
        try ToolCheck.validate()
      }

      @Test("validate does NOT require aws on PATH (post-v0.14.x cleanup)")
      func awsNoLongerRequired() throws {
        // Install ONLY hf. The pre-cleanup behaviour required both `aws`
        // and `hf`; the post-cleanup behaviour requires only `hf`. This
        // test pins the new contract so a regression that re-introduces
        // an aws-on-PATH check shows up here.
        try installStub(named: "hf")
        try ToolCheck.validate()
      }

      // MARK: - Error message content

      @Test("missingTool description for hf mentions brew install huggingface-hub")
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

        #expect(text.contains("brew install huggingface-hub"))
      }

      @Test("isToolOnPath returns true for installed stubs and false otherwise")
      func isToolOnPathSeam() throws {
        #expect(ToolCheck.isToolOnPath(name: "hf") == false)
        try installStub(named: "hf")
        #expect(ToolCheck.isToolOnPath(name: "hf") == true)
        #expect(ToolCheck.isToolOnPath(name: "totally-bogus-binary") == false)
      }
    }
  }
#endif
