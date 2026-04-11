import ArgumentParser
import Foundation
import SwiftAcervo

/// Generates a `manifest.json` for a local staging directory using
/// `ManifestGenerator`. Prints the absolute path of the written manifest
/// to stdout on success so it can be piped into other tools.
struct ManifestCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "manifest",
    abstract: "Generate a CDN manifest.json for a local model directory."
  )

  @Argument(help: "HuggingFace model identifier in 'org/repo' form.")
  var modelId: String

  @Argument(help: "Local directory whose contents should be enumerated into a manifest.")
  var directory: String

  func run() async throws {
    let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)

    let generator = ManifestGenerator(modelId: modelId)
    let manifestURL = try await generator.generate(directory: directoryURL)

    FileHandle.standardOutput.write(Data((manifestURL.path + "\n").utf8))
  }
}
