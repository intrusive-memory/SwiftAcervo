#if os(macOS)
  // RecacheCommandTests
  //
  // Coverage for the `acervo recache` subcommand. Focuses on argument
  // parsing and the env-var resolution that happens before any HF or CDN
  // traffic. The actual fetch + publish pipeline is covered by
  // SwiftAcervoTests/RecacheTests.swift.

  import ArgumentParser
  import Foundation
  import Testing

  @testable import acervo

  extension ProcessEnvironmentSuite {

    @Suite("RecacheCommand Tests")
    final class RecacheCommandTests {

      @Test("Required positional modelId; optional files list")
      func parsesPositionals() throws {
        let parsed = try AcervoCLI.parseAsRoot([
          "recache", "org/repo", "config.json", "tokenizer.json",
        ])
        guard let cmd = parsed as? RecacheCommand else {
          Issue.record("expected RecacheCommand")
          return
        }
        #expect(cmd.modelId == "org/repo")
        #expect(cmd.files == ["config.json", "tokenizer.json"])
        #expect(cmd.keepOrphans == false)
        #expect(cmd.yes == false)
      }

      @Test("--keep-orphans and --yes parse")
      func parsesFlags() throws {
        let parsed = try AcervoCLI.parseAsRoot([
          "recache", "org/repo", "--keep-orphans", "--yes",
        ])
        guard let cmd = parsed as? RecacheCommand else {
          Issue.record("expected RecacheCommand")
          return
        }
        #expect(cmd.keepOrphans == true)
        #expect(cmd.yes == true)
      }

      @Test("Missing modelId fails to parse")
      func missingModelIdFails() {
        do {
          _ = try AcervoCLI.parseAsRoot(["recache"])
          Issue.record("parse should have thrown")
        } catch {
          // ArgumentParser surfaces missing positional as a parse error.
          // We accept any error here — the specific type varies by version.
        }
      }
    }
  }
#endif
