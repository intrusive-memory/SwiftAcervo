import Foundation
import SwiftAcervo

/// Resolves an `AcervoCDNCredentials` value from process environment
/// variables. The library deliberately never reads from
/// `ProcessInfo.environment` — that resolution is the CLI's job — so this
/// helper exists in the CLI target only and is shared by every command
/// that needs to authenticate against R2.
///
/// Environment variables consulted:
///
///   R2_ACCESS_KEY_ID       — required
///   R2_SECRET_ACCESS_KEY   — required
///   R2_ENDPOINT            — required, S3-compatible endpoint URL
///   R2_PUBLIC_URL          — required, public CDN base URL
///   R2_BUCKET              — optional, defaults to "intrusive-memory-models"
///   R2_REGION              — optional, defaults to "auto" (R2 convention)
///
/// `--bucket` / `--endpoint` overrides may be passed in as `bucketOverride`
/// / `endpointOverride` to take precedence over the env. Other fields have
/// no override flag yet.
enum CredentialResolver {

  /// Build credentials from environment + optional overrides. Throws
  /// `AcervoToolError.missingEnvironmentVariable` if any required value
  /// is absent (an empty value counts as absent).
  static func resolve(
    bucketOverride: String? = nil,
    endpointOverride: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> AcervoCDNCredentials {
    let accessKey = try requireEnv("R2_ACCESS_KEY_ID", in: environment)
    let secretKey = try requireEnv("R2_SECRET_ACCESS_KEY", in: environment)

    let bucket: String
    if let bucketOverride, !bucketOverride.isEmpty {
      bucket = bucketOverride
    } else if let env = environment["R2_BUCKET"], !env.isEmpty {
      bucket = env
    } else {
      bucket = "intrusive-memory-models"
    }

    let endpointString: String
    if let endpointOverride, !endpointOverride.isEmpty {
      endpointString = endpointOverride
    } else {
      endpointString = try requireEnv("R2_ENDPOINT", in: environment)
    }
    guard let endpoint = URL(string: endpointString) else {
      throw AcervoToolError.missingEnvironmentVariable(
        "R2_ENDPOINT (invalid URL: \(endpointString))"
      )
    }

    let publicURLString = try requireEnv("R2_PUBLIC_URL", in: environment)
    guard let publicBaseURL = URL(string: publicURLString) else {
      throw AcervoToolError.missingEnvironmentVariable(
        "R2_PUBLIC_URL (invalid URL: \(publicURLString))"
      )
    }

    let region = environment["R2_REGION"].flatMap { $0.isEmpty ? nil : $0 } ?? "auto"

    return AcervoCDNCredentials(
      accessKeyId: accessKey,
      secretAccessKey: secretKey,
      region: region,
      bucket: bucket,
      endpoint: endpoint,
      publicBaseURL: publicBaseURL
    )
  }

  private static func requireEnv(
    _ name: String,
    in environment: [String: String]
  ) throws -> String {
    guard let value = environment[name], !value.isEmpty else {
      throw AcervoToolError.missingEnvironmentVariable(name)
    }
    return value
  }
}
