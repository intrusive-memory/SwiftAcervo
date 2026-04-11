import ArgumentParser
import Foundation

@main
struct AcervoCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "acervo",
    abstract: "Download, verify, and mirror AI models to the intrusive-memory CDN.",
    version: "0.6.0"
  )

  func run() async throws {
    // Stub entry point. Subcommands will be registered in Sortie 2.
  }
}
