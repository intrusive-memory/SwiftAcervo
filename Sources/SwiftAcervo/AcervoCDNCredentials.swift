// AcervoCDNCredentials.swift
// SwiftAcervo
//
// Credential bundle used by the CDN-mutation surface (Layer 1+) to sign
// S3-compatible requests. Per requirements §6.1, the library never reads
// these from `ProcessInfo.environment`; consumers (typically the `acervo`
// CLI) resolve env vars themselves and hand a fully populated value to
// the library. This keeps the library impossible to misuse via ambient
// credentials and makes signer tests trivial.

import Foundation

/// Credentials and addressing information for an S3-compatible CDN
/// (Cloudflare R2 in this project).
///
/// The library never inspects `ProcessInfo.environment`. Callers must
/// pass an instance explicitly to any API that performs CDN mutations.
///
/// Defaults match the values in `REQUIREMENTS-delete-and-recache.md` §6.1:
/// `region` defaults to `"auto"` (Cloudflare R2's region literal) and
/// `bucket` defaults to `"intrusive-memory-models"`.
public struct AcervoCDNCredentials: Sendable {

  /// The S3 access key identifier.
  public let accessKeyId: String

  /// The S3 secret access key. Must never be logged or rendered.
  public let secretAccessKey: String

  /// AWS-style region literal. R2 expects `"auto"`.
  public let region: String

  /// Bucket name (R2 calls it "bucket" too).
  public let bucket: String

  /// S3-compatible API endpoint. Used for SigV4-signed mutation requests.
  public let endpoint: URL

  /// Public HTTPS base URL used to verify reads after a publish (CHECK 5/6
  /// in the publish pipeline). Distinct from `endpoint` because CDN reads
  /// hit the public bucket URL while writes hit the S3 API endpoint.
  public let publicBaseURL: URL

  /// Memberwise initializer.
  ///
  /// - Parameters:
  ///   - accessKeyId: S3 access key id.
  ///   - secretAccessKey: S3 secret access key.
  ///   - region: Region literal (default `"auto"` for R2).
  ///   - bucket: Bucket name (default `"intrusive-memory-models"`).
  ///   - endpoint: S3-compatible API endpoint (signed mutations).
  ///   - publicBaseURL: Public CDN base URL (verification reads).
  public init(
    accessKeyId: String,
    secretAccessKey: String,
    region: String = "auto",
    bucket: String = "intrusive-memory-models",
    endpoint: URL,
    publicBaseURL: URL
  ) {
    self.accessKeyId = accessKeyId
    self.secretAccessKey = secretAccessKey
    self.region = region
    self.bucket = bucket
    self.endpoint = endpoint
    self.publicBaseURL = publicBaseURL
  }
}
