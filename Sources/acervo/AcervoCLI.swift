import ArgumentParser
import Foundation

@main
struct AcervoCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "acervo",
    abstract: "Download, verify, and mirror AI models to the intrusive-memory CDN.",
    version: acervoVersion,
    subcommands: [
      DownloadCommand.self,
      UploadCommand.self,
      ShipCommand.self,
      ManifestCommand.self,
      VerifyCommand.self,
    ]
  )
}

// MARK: - Subcommand Stubs
//
// These stubs exist so `acervo --help` surfaces every subcommand while later
// sorties flesh out the real implementations. Each will be rewritten in a
// future sortie; keep them minimal.

struct DownloadCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "download",
    abstract: "Download a model from HuggingFace into the staging directory."
  )

  func run() async throws {
    // Implemented in Sortie 5.
  }
}

struct UploadCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "upload",
    abstract: "Upload a staged model directory to the intrusive-memory CDN."
  )

  func run() async throws {
    // Implemented in Sortie 6.
  }
}

struct ShipCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ship",
    abstract: "Download a model from HuggingFace and mirror it to the CDN."
  )

  func run() async throws {
    // Implemented in Sortie 6.
  }
}

struct ManifestCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "manifest",
    abstract: "Generate a CDN manifest.json for a local model directory."
  )

  func run() async throws {
    // Implemented in Sortie 5.
  }
}

struct VerifyCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "verify",
    abstract: "Verify a local or CDN-hosted model against its manifest."
  )

  func run() async throws {
    // Implemented in Sortie 5.
  }
}
