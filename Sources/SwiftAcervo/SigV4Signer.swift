// SigV4Signer.swift
// SwiftAcervo
//
// Pure-Swift AWS Signature Version 4 implementation. No networking, no
// filesystem — request signing only. Used by the CDN-mutation surface
// (Layer 2 `S3CDNClient` and above) to sign requests against
// S3-compatible APIs (Cloudflare R2 in this project).
//
// The implementation follows the AWS-published SigV4 specification:
// canonical request → string-to-sign → HMAC-derived signing key →
// signature → Authorization header.
//
// References:
//   - https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
//   - aws4_testsuite (canonical conformance vectors, vendored into
//     `Tests/SwiftAcervoTests/SigV4SignerTests.swift`)
//
// Notes on URI encoding:
//   - For services other than S3, every path segment is URI-encoded
//     twice (once by the user, once by the signer). This matches the
//     canonical aws4_testsuite expectations (which use the synthetic
//     service name "service").
//   - For S3 specifically, the path is encoded only once (S3 stores
//     keys verbatim and the SigV4 spec carves it out). This is a
//     well-known signer-side special case.
//
// All hashing uses CryptoKit's `SHA256` and `HMAC<SHA256>`. No third-party
// crypto dependencies are introduced (per requirements §5).

import CryptoKit
import Foundation

/// How to compute the `x-amz-content-sha256` header (and the hashed-payload
/// portion of the canonical request).
public enum PayloadHash: Sendable {
  /// The request has an empty body. The signer will use the well-known
  /// SHA-256 of zero bytes (`e3b0c44...`).
  case empty
  /// The caller has already hashed the body (typically while streaming a
  /// large file from disk). The string must be the lowercase hex digest.
  case precomputed(String)
  /// Use the literal token `UNSIGNED-PAYLOAD`. Only valid against services
  /// that support unsigned bodies (S3 for `https://` over public CDN).
  case unsignedPayload
}

/// AWS Signature Version 4 signer.
///
/// Construct with credentials and a service identifier (default `"s3"`),
/// then call `sign(_:payloadHash:date:)` to obtain a copy of the request
/// with `Authorization`, `x-amz-date`, and `x-amz-content-sha256`
/// headers attached. The signer never mutates the input request.
public struct SigV4Signer: Sendable {

  /// SHA-256 hex digest of the empty byte string. Used by `.empty`.
  static let emptyPayloadHash =
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  private let credentials: AcervoCDNCredentials
  private let service: String

  /// - Parameters:
  ///   - credentials: AWS-shaped credentials (access key, secret, region).
  ///   - service: AWS service identifier. `"s3"` triggers the S3-specific
  ///     canonical-URI rule (single URI encoding rather than double).
  public init(credentials: AcervoCDNCredentials, service: String = "s3") {
    self.credentials = credentials
    self.service = service
  }

  /// Returns a copy of `request` with SigV4 headers attached.
  ///
  /// - Parameters:
  ///   - request: The request to sign. The URL must contain a host.
  ///   - payloadHash: How to populate `x-amz-content-sha256` and the
  ///     hashed-payload portion of the canonical request.
  ///   - date: The signing instant (defaults to "now"). Exposed for tests
  ///     so canonical AWS vectors can be reproduced bit-for-bit.
  public func sign(
    _ request: URLRequest,
    payloadHash: PayloadHash,
    date: Date = Date()
  ) -> URLRequest {
    var signed = request

    // Resolved payload hash hex string.
    let payloadHashHex: String
    switch payloadHash {
    case .empty:
      payloadHashHex = Self.emptyPayloadHash
    case .precomputed(let hex):
      payloadHashHex = hex.lowercased()
    case .unsignedPayload:
      payloadHashHex = "UNSIGNED-PAYLOAD"
    }

    // Step 0 — Required timestamps.
    let amzDate = Self.amzDate(from: date)  // YYYYMMDDTHHMMSSZ
    let dateStamp = String(amzDate.prefix(8))  // YYYYMMDD

    // Step 1 — Build the canonical request.
    //
    // Algorithm:
    //   HTTPMethod \n CanonicalURI \n CanonicalQueryString \n
    //   CanonicalHeaders \n \n SignedHeaders \n HashedPayload
    //
    // We always set the `x-amz-date` request header because every
    // SigV4 request must carry it. We always set
    // `x-amz-content-sha256` too (S3 requires it; downstream R2
    // expects it). However, whether `x-amz-content-sha256` ends up
    // in the signed-headers list is service-dependent: S3 includes it
    // (the service-specific contract), other services do not (and the
    // canonical aws4_testsuite vectors confirm that). We respect that
    // distinction so the signer reproduces the canonical vectors
    // exactly while still producing valid S3 / R2 signatures.
    signed.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
    signed.setValue(payloadHashHex, forHTTPHeaderField: "x-amz-content-sha256")

    // Headers we sign: every existing header on the request, plus host
    // (derived from the URL because URLRequest doesn't expose Host
    // directly), plus x-amz-date (just set above). For S3 we also sign
    // `x-amz-content-sha256`; for other services we leave it on the
    // wire but exclude it from the signed-headers list (matches the
    // canonical aws4_testsuite vectors, which use service="service").
    var headersToSign: [(String, String)] = []
    if let existing = signed.allHTTPHeaderFields {
      for (k, v) in existing {
        let lower = k.lowercased()
        if lower == "x-amz-content-sha256" && service != "s3" {
          continue
        }
        headersToSign.append((k, v))
      }
    }
    if let host = Self.canonicalHost(for: request.url) {
      // Only inject Host if the caller didn't already supply one.
      if !headersToSign.contains(where: { $0.0.lowercased() == "host" }) {
        headersToSign.append(("Host", host))
      }
    }

    let canonicalHeaders = Self.canonicalHeaders(from: headersToSign)
    let signedHeaders = Self.signedHeadersList(from: headersToSign)

    let httpMethod = (signed.httpMethod ?? "GET").uppercased()
    let canonicalURI = Self.canonicalURI(
      for: request.url,
      service: service
    )
    let canonicalQuery = Self.canonicalQueryString(for: request.url)

    let canonicalRequest =
      "\(httpMethod)\n"
      + "\(canonicalURI)\n"
      + "\(canonicalQuery)\n"
      + "\(canonicalHeaders)\n"
      + "\n"
      + "\(signedHeaders)\n"
      + "\(payloadHashHex)"

    // Step 2 — String to sign.
    let credentialScope =
      "\(dateStamp)/\(credentials.region)/\(service)/aws4_request"
    let canonicalRequestHash = Self.sha256Hex(
      Data(canonicalRequest.utf8)
    )
    let stringToSign =
      "AWS4-HMAC-SHA256\n"
      + "\(amzDate)\n"
      + "\(credentialScope)\n"
      + "\(canonicalRequestHash)"

    // Step 3 — Derive signing key.
    let kSecret = "AWS4\(credentials.secretAccessKey)"
    let kDate = Self.hmac(
      key: Data(kSecret.utf8),
      data: Data(dateStamp.utf8)
    )
    let kRegion = Self.hmac(
      key: kDate,
      data: Data(credentials.region.utf8)
    )
    let kService = Self.hmac(
      key: kRegion,
      data: Data(service.utf8)
    )
    let kSigning = Self.hmac(
      key: kService,
      data: Data("aws4_request".utf8)
    )

    // Step 4 — Final signature.
    let signature = Self.hmacHex(
      key: kSigning,
      data: Data(stringToSign.utf8)
    )

    let authorization =
      "AWS4-HMAC-SHA256 "
      + "Credential=\(credentials.accessKeyId)/\(credentialScope), "
      + "SignedHeaders=\(signedHeaders), "
      + "Signature=\(signature)"
    signed.setValue(authorization, forHTTPHeaderField: "Authorization")

    return signed
  }

  // MARK: - Canonicalization helpers

  /// `YYYYMMDDTHHMMSSZ` in UTC.
  static func amzDate(from date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter.string(from: date)
  }

  /// Canonical host, lowercased; preserves a non-default port.
  static func canonicalHost(for url: URL?) -> String? {
    guard let url, let host = url.host else { return nil }
    let lower = host.lowercased()
    guard let port = url.port else { return lower }
    // Default ports are implied; only attach port if explicit and non-default.
    let scheme = (url.scheme ?? "").lowercased()
    if (scheme == "https" && port == 443)
      || (scheme == "http" && port == 80)
    {
      return lower
    }
    return "\(lower):\(port)"
  }

  /// Canonical URI per the SigV4 spec.
  ///
  /// - Empty path → `"/"`.
  /// - For S3 (`service == "s3"`): segments are URI-encoded once.
  /// - For everything else: segments are URI-encoded twice.
  ///
  /// The slash separators between segments are NEVER encoded.
  static func canonicalURI(for url: URL?, service: String) -> String {
    guard let url else { return "/" }
    // We need the raw (un-decoded) path to handle inputs like "/foo%2Fbar"
    // correctly — `url.path` percent-decodes for us, which is wrong here.
    let rawPath = url.absoluteURL.path(percentEncoded: true)
    let path = rawPath.isEmpty ? "/" : rawPath

    // Split on '/' but preserve the leading slash and any trailing slash.
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    // path "/" → ["", ""]; path "/a/b" → ["", "a", "b"]
    let encoded = parts.map { segment -> String in
      let s = String(segment)
      if s.isEmpty { return s }
      // The raw path is already percent-encoded once (it came out of
      // URL.path(percentEncoded:)). We first DECODE so the canonical
      // input is the user's literal segment, then re-encode 1× (S3) or
      // 2× (everything else).
      let decoded = s.removingPercentEncoding ?? s
      let once = uriEncode(decoded, encodeSlash: true)
      if service == "s3" {
        return once
      } else {
        return uriEncode(once, encodeSlash: true)
      }
    }
    let joined = encoded.joined(separator: "/")
    return joined.isEmpty ? "/" : joined
  }

  /// Canonical query string: keys URI-encoded once, values URI-encoded once,
  /// `key=value` pairs joined by `&`, sorted by key (then by value), value
  /// empty if absent.
  static func canonicalQueryString(for url: URL?) -> String {
    guard let url,
      let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else {
      return ""
    }
    // Use percentEncodedQueryItems so we read the raw, undecoded form
    // and apply our own canonical encoding.
    guard let items = comps.percentEncodedQueryItems, !items.isEmpty else {
      // SigV4 distinguishes "no query" (empty string) from "empty value".
      return ""
    }
    let canonical = items.map { item -> (String, String) in
      let rawKey = item.name.removingPercentEncoding ?? item.name
      let rawVal = item.value?.removingPercentEncoding ?? (item.value ?? "")
      let k = uriEncode(rawKey, encodeSlash: true)
      let v = uriEncode(rawVal, encodeSlash: true)
      return (k, v)
    }
    let sorted = canonical.sorted { lhs, rhs in
      if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
      return lhs.1 < rhs.1
    }
    return sorted.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
  }

  /// Canonical headers: lowercase name, trimmed value, sequential
  /// whitespace inside the value collapsed to a single space, sorted by
  /// name. Duplicates with the same name are joined by a comma in the
  /// order they were supplied (per the spec).
  static func canonicalHeaders(
    from raw: [(String, String)]
  ) -> String {
    var grouped: [String: [String]] = [:]
    var order: [String] = []
    for (name, value) in raw {
      let lower = name.lowercased()
      if grouped[lower] == nil {
        grouped[lower] = []
        order.append(lower)
      }
      grouped[lower]?.append(canonicalizeHeaderValue(value))
    }
    let names = order.sorted()
    return names.map { name in
      let joined = (grouped[name] ?? []).joined(separator: ",")
      return "\(name):\(joined)"
    }.joined(separator: "\n")
  }

  /// Sorted, semicolon-separated list of canonical header names.
  static func signedHeadersList(from raw: [(String, String)]) -> String {
    var seen = Set<String>()
    var names: [String] = []
    for (name, _) in raw {
      let lower = name.lowercased()
      if seen.insert(lower).inserted {
        names.append(lower)
      }
    }
    return names.sorted().joined(separator: ";")
  }

  /// Trim outer whitespace and collapse internal sequential whitespace
  /// to a single space, per the SigV4 canonical-header rules.
  static func canonicalizeHeaderValue(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    var out: [Character] = []
    var prevWasSpace = false
    for ch in trimmed {
      if ch == " " || ch == "\t" {
        if !prevWasSpace {
          out.append(" ")
          prevWasSpace = true
        }
      } else {
        out.append(ch)
        prevWasSpace = false
      }
    }
    return String(out)
  }

  // MARK: - URI encoding

  /// SigV4 URI encoding (RFC 3986, with explicit unreserved set).
  ///
  /// Unreserved: A-Z a-z 0-9 `-` `_` `.` `~`. Everything else encoded
  /// as `%HH` with uppercase hex. `/` is encoded only when
  /// `encodeSlash` is true (it is for path segments and query
  /// components alike — note: our caller for the path splits on '/'
  /// first, so the slashes between segments are emitted unencoded).
  static func uriEncode(_ input: String, encodeSlash: Bool) -> String {
    var out = ""
    out.reserveCapacity(input.utf8.count)
    for byte in input.utf8 {
      if Self.isUnreserved(byte) {
        out.append(Character(UnicodeScalar(byte)))
      } else if byte == 0x2F /* '/' */ && !encodeSlash {
        out.append("/")
      } else {
        out.append(String(format: "%%%02X", byte))
      }
    }
    return out
  }

  static func isUnreserved(_ byte: UInt8) -> Bool {
    // A-Z
    if byte >= 0x41 && byte <= 0x5A { return true }
    // a-z
    if byte >= 0x61 && byte <= 0x7A { return true }
    // 0-9
    if byte >= 0x30 && byte <= 0x39 { return true }
    // - _ . ~
    if byte == 0x2D || byte == 0x5F || byte == 0x2E || byte == 0x7E {
      return true
    }
    return false
  }

  // MARK: - Crypto helpers

  static func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  static func hmac(key: Data, data: Data) -> Data {
    let mac = HMAC<SHA256>.authenticationCode(
      for: data,
      using: SymmetricKey(data: key)
    )
    return Data(mac)
  }

  static func hmacHex(key: Data, data: Data) -> String {
    let mac = hmac(key: key, data: data)
    return mac.map { String(format: "%02x", $0) }.joined()
  }
}
