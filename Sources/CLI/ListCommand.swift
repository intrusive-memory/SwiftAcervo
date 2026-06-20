import ArgumentParser
import Foundation
import SwiftAcervo

/// Lists the model directories present under the CDN's `models/` prefix.
///
/// This is a deliberately dumb inventory: it prints the slug of every
/// directory found in the bucket, one per line. It makes NO claim about
/// whether each model is complete, valid, or has a manifest — those checks
/// belong to later commands (`verify`, `manifest`). Use this to discover
/// what is on the CDN before reaching for a heavier operation.
struct ListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List the model directories present on the CDN.",
    discussion: """
      Prints one model slug per line for every directory under models/ in the
      R2 bucket. Output is sorted case-insensitively.

      This command does not validate models. A listed slug only means a
      directory exists under models/<slug>/; it does not guarantee a complete
      or usable model. Use `acervo verify` for integrity checks.

      REQUIRED ENVIRONMENT
        R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ENDPOINT, R2_PUBLIC_URL
        R2_BUCKET (optional; defaults to intrusive-memory-models)

      EXAMPLES
        acervo list
        acervo list --bucket my-other-bucket
      """
  )

  @Option(
    name: [.short, .customLong("bucket")],
    help: "R2 bucket override (otherwise uses $R2_BUCKET)."
  )
  var bucket: String?

  @Option(
    name: .customLong("endpoint"),
    help: "R2 endpoint override (otherwise uses $R2_ENDPOINT)."
  )
  var endpoint: String?

  func run() async throws {
    let credentials = try CredentialResolver.resolve(
      bucketOverride: bucket,
      endpointOverride: endpoint
    )

    let slugs = try await Acervo.listCDNModels(credentials: credentials)

    var out = ""
    for slug in slugs {
      out += slug + "\n"
    }
    FileHandle.standardOutput.write(Data(out.utf8))
  }
}
