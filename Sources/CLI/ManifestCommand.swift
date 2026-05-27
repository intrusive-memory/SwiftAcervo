import ArgumentParser
import Foundation
import SwiftAcervo

/// Generates a `manifest.json` for a local staging directory using
/// `ManifestGenerator`. Prints the absolute path of the written manifest
/// to stdout on success so it can be piped into other tools.
struct ManifestCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "manifest",
    abstract: "Generate a CDN manifest.json for a local model directory.",
    discussion: """
      Scans <directory>, computes SHA-256 for every file, and writes
      manifest.json alongside the model files (CHECK 2 + CHECK 3):

        CHECK 2  Refuses to write a manifest if any file is zero bytes.
        CHECK 3  Re-reads manifest.json after writing and verifies its checksum.

      Prints the absolute path to the written manifest.json on stdout.

      EXAMPLES
        acervo manifest mlx-community/Qwen2.5-7B-Instruct-4bit \\
          /tmp/acervo-staging/mlx-community_Qwen2.5-7B-Instruct-4bit
      """
  )

  @Argument(help: "HuggingFace model identifier in 'org/repo' form.")
  var modelId: String

  @Argument(help: "Local directory whose contents should be enumerated into a manifest.")
  var directory: String

  @OptionGroup var progressOptions: ProgressOptions

  func run() async throws {
    let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)

    let generator = ManifestGenerator(modelId: modelId)

    // ManifestGenerator's progress hook calls back once with (0, total)
    // before the first hash, then once per file as the hash completes.
    // Construct the bar lazily on the first callback so the total is known.
    let quiet = progressOptions.quiet
    let reporterBox = ManifestProgressReporterBox(quiet: quiet)
    let manifestURL = try await generator.generate(
      directory: directoryURL,
      progress: { completed, total in
        reporterBox.handle(completed: completed, total: total)
      }
    )

    FileHandle.standardOutput.write(Data((manifestURL.path + "\n").utf8))
  }
}

/// Helper that defers `ProgressReporter` construction until the first
/// (0, total) progress event arrives. Lets the CLI render a sized bar
/// even though `ManifestGenerator.scan` runs inside the actor before
/// the total is known to the caller.
final class ManifestProgressReporterBox: @unchecked Sendable {
  private var reporter: ProgressReporter?
  private let quiet: Bool
  private let label: String
  private let lock = NSLock()

  init(quiet: Bool, label: String = "Hashing manifest: ") {
    self.quiet = quiet
    self.label = label
  }

  func handle(completed: Int, total: Int) {
    lock.lock()
    defer { lock.unlock() }
    if reporter == nil {
      reporter = ProgressReporter(label: label, total: total, quiet: quiet)
      // First call is (0, total); no advance yet.
      if completed == 0 { return }
    }
    reporter?.advance()
  }
}
