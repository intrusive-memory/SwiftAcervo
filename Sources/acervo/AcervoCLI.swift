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
// `DownloadCommand`, `ManifestCommand`, and `VerifyCommand` have moved to
// their own files now that Sortie 5 has implemented them. `UploadCommand`
// and `ShipCommand` remain stubs until Sortie 6 fleshes them out.

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
