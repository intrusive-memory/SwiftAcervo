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

