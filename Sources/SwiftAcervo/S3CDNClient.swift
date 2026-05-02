// S3CDNClient.swift
// SwiftAcervo
//
// Layer 2 of the CDN-mutation surface (per requirements §6.3): a thin
// `actor` wrapper over `URLSession` that signs every request with
// `SigV4Signer` and exposes the four S3 operations needed by `recache`
// and `delete`. PUT support lands in WU1 Sortie 3 (multipart); the
// `S3PutResult` type is declared here so downstream code can reference
// it from the start of the WU.
//
// Endpoint addressing
// -------------------
// We use S3 **path-style** URLs: `<endpoint>/<bucket>/<key>`. R2 supports
// both virtual-hosted and path-style; path-style keeps URL construction
// trivial and avoids per-bucket DNS surprises in tests.
//
// XML parsing
// -----------
// `ListObjectsV2` and `DeleteObjects` are XML-only S3 APIs. We parse them
// with Foundation's `XMLParser` (event-driven, no third-party deps). For
// the small, well-known responses involved here that's appropriate; we
// would not pick `XMLParser` for a general-purpose XML payload.
//
// Cross-sortie hand-off
// ---------------------
// Several non-2xx paths currently throw `URLError(.badServerResponse)` with
// a `// TODO(WU2.S1): replace with cdnOperationFailed` comment. WU2 Sortie 1
// adds the `cdnOperationFailed`, `publishVerificationFailed`, and
// `fetchSourceFailed` cases on `AcervoError` and replaces those throws.
// The 401/403 path uses `AcervoError.cdnAuthorizationFailed` already
// (introduced in this sortie).

import CryptoKit
import Foundation

// MARK: - Public types

/// One entry in a `listObjects` response.
public struct S3Object: Sendable, Equatable {
  /// Full S3 key (relative to the bucket root).
  public let key: String
  /// Size in bytes as reported by S3.
  public let size: Int64
  /// ETag (S3 returns it wrapped in double quotes; we surface it verbatim
  /// to preserve fidelity with `headObject`).
  public let etag: String

  public init(key: String, size: Int64, etag: String) {
    self.key = key
    self.size = size
    self.etag = etag
  }
}

/// Result of a `headObject` call when the key exists.
public struct S3ObjectHead: Sendable, Equatable {
  public let size: Int64
  public let etag: String
  public let contentType: String?
  public let lastModified: Date?

  public init(
    size: Int64,
    etag: String,
    contentType: String?,
    lastModified: Date?
  ) {
    self.size = size
    self.etag = etag
    self.contentType = contentType
    self.lastModified = lastModified
  }
}

/// Result of a `putObject` call. Declared here so downstream sorties can
/// reference it before WU1.S3 lands the actual implementation.
public struct S3PutResult: Sendable, Equatable {
  public let key: String
  public let etag: String
  public let sha256: String

  public init(key: String, etag: String, sha256: String) {
    self.key = key
    self.etag = etag
    self.sha256 = sha256
  }
}

/// Per-key outcome of a `deleteObjects` (bulk delete) call.
public struct S3DeleteResult: Sendable, Equatable {
  public let key: String
  public let success: Bool
  /// AWS/R2-supplied error code or message when `success == false`.
  public let error: String?

  public init(key: String, success: Bool, error: String?) {
    self.key = key
    self.success = success
    self.error = error
  }
}

// MARK: - Actor

/// Thin S3-compatible client over `URLSession`. Signs every request with
/// SigV4 (service `"s3"`). All operations target the bucket carried in the
/// supplied `AcervoCDNCredentials`.
public actor S3CDNClient {

  private let credentials: AcervoCDNCredentials
  private let session: URLSession
  private let signer: SigV4Signer

  public init(
    credentials: AcervoCDNCredentials,
    session: URLSession = .shared
  ) {
    self.credentials = credentials
    self.session = session
    self.signer = SigV4Signer(credentials: credentials, service: "s3")
  }

  // MARK: - listObjects

  /// Lists every key under `prefix`, paginating with
  /// `NextContinuationToken` until `IsTruncated=false`.
  public func listObjects(prefix: String) async throws -> [S3Object] {
    var collected: [S3Object] = []
    var continuationToken: String? = nil

    repeat {
      let (objects, nextToken) = try await listOnePage(
        prefix: prefix,
        continuationToken: continuationToken
      )
      collected.append(contentsOf: objects)
      continuationToken = nextToken
    } while continuationToken != nil

    return collected
  }

  private func listOnePage(
    prefix: String,
    continuationToken: String?
  ) async throws -> (objects: [S3Object], nextToken: String?) {
    var queryItems: [URLQueryItem] = [
      URLQueryItem(name: "list-type", value: "2"),
      URLQueryItem(name: "prefix", value: prefix),
    ]
    if let continuationToken {
      queryItems.append(
        URLQueryItem(name: "continuation-token", value: continuationToken)
      )
    }

    let url = bucketURL(path: "", queryItems: queryItems)
    var request = URLRequest(url: url)
    request.httpMethod = "GET"

    let signed = signer.sign(request, payloadHash: .empty)
    let (data, response) = try await perform(signed)

    guard let http = response as? HTTPURLResponse else {
      // TODO(WU2.S1): replace with cdnOperationFailed
      throw URLError(.badServerResponse)
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      throw AcervoError.cdnAuthorizationFailed(operation: "list")
    }
    guard (200..<300).contains(http.statusCode) else {
      // TODO(WU2.S1): replace with cdnOperationFailed
      throw URLError(.badServerResponse)
    }

    let parsed = try ListObjectsV2Parser.parse(data)
    return (parsed.objects, parsed.nextContinuationToken)
  }

  // MARK: - headObject

  /// Returns metadata for `key`, or `nil` if the key does not exist
  /// (HTTP 404). Throws `AcervoError.cdnAuthorizationFailed` on 401/403.
  public func headObject(key: String) async throws -> S3ObjectHead? {
    let url = bucketURL(path: key, queryItems: [])
    var request = URLRequest(url: url)
    request.httpMethod = "HEAD"

    let signed = signer.sign(request, payloadHash: .empty)
    let (_, response) = try await perform(signed)

    guard let http = response as? HTTPURLResponse else {
      // TODO(WU2.S1): replace with cdnOperationFailed
      throw URLError(.badServerResponse)
    }

    if http.statusCode == 404 {
      return nil
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      throw AcervoError.cdnAuthorizationFailed(operation: "head")
    }
    guard (200..<300).contains(http.statusCode) else {
      // TODO(WU2.S1): replace with cdnOperationFailed
      throw URLError(.badServerResponse)
    }

    let size: Int64
    if let lenStr = http.value(forHTTPHeaderField: "Content-Length"),
      let parsed = Int64(lenStr)
    {
      size = parsed
    } else {
      size = http.expectedContentLength
    }
    let etag = http.value(forHTTPHeaderField: "ETag") ?? ""
    let contentType = http.value(forHTTPHeaderField: "Content-Type")
    let lastModified = http.value(forHTTPHeaderField: "Last-Modified")
      .flatMap { Self.parseHTTPDate($0) }

    return S3ObjectHead(
      size: size,
      etag: etag,
      contentType: contentType,
      lastModified: lastModified
    )
  }

  // MARK: - deleteObject

  /// Deletes `key`. HTTP 404 is **not** an error (idempotent per
  /// requirements §6.3).
  public func deleteObject(key: String) async throws {
    let url = bucketURL(path: key, queryItems: [])
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"

    let signed = signer.sign(request, payloadHash: .empty)
    let (_, response) = try await perform(signed)

    guard let http = response as? HTTPURLResponse else {
      // TODO(WU2.S1): replace with cdnOperationFailed
      throw URLError(.badServerResponse)
    }
    // 204 No Content is the success case; 404 is treated as success too.
    if http.statusCode == 404 || (200..<300).contains(http.statusCode) {
      return
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      throw AcervoError.cdnAuthorizationFailed(operation: "delete")
    }
    // TODO(WU2.S1): replace with cdnOperationFailed
    throw URLError(.badServerResponse)
  }

  // MARK: - deleteObjects (bulk)

  /// Bulk delete via the S3 `DeleteObjects` POST. Inputs longer than
  /// 1000 keys are split into multiple requests transparently and
  /// concatenated into a single result list.
  public func deleteObjects(keys: [String]) async throws -> [S3DeleteResult] {
    if keys.isEmpty { return [] }

    let batchSize = 1000
    var results: [S3DeleteResult] = []
    var index = 0
    while index < keys.count {
      let end = min(index + batchSize, keys.count)
      let batch = Array(keys[index..<end])
      let batchResults = try await deleteObjectsBatch(keys: batch)
      results.append(contentsOf: batchResults)
      index = end
    }
    return results
  }

  private func deleteObjectsBatch(keys: [String]) async throws -> [S3DeleteResult] {
    let body = Self.buildDeleteObjectsXML(keys: keys)
    let bodyData = Data(body.utf8)

    // Content-MD5 is required by the S3 DeleteObjects spec. R2 follows
    // the AWS spec here.
    let md5Base64 = Self.base64MD5(of: bodyData)
    let payloadSHA256Hex = SigV4Signer.sha256Hex(bodyData)

    // The DeleteObjects sub-resource is selected by the bare "delete"
    // query parameter (no value).
    var components = URLComponents(
      url: bucketURL(path: "", queryItems: []),
      resolvingAgainstBaseURL: false
    )!
    components.percentEncodedQuery = "delete="
    let url = components.url!

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = bodyData
    request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
    request.setValue(md5Base64, forHTTPHeaderField: "Content-MD5")
    request.setValue(
      String(bodyData.count), forHTTPHeaderField: "Content-Length"
    )

    let signed = signer.sign(
      request,
      payloadHash: .precomputed(payloadSHA256Hex)
    )
    let (data, response) = try await perform(signed)

    guard let http = response as? HTTPURLResponse else {
      // TODO(WU2.S1): replace with cdnOperationFailed
      throw URLError(.badServerResponse)
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      throw AcervoError.cdnAuthorizationFailed(operation: "deleteObjects")
    }
    guard (200..<300).contains(http.statusCode) else {
      // TODO(WU2.S1): replace with cdnOperationFailed
      throw URLError(.badServerResponse)
    }

    return try DeleteObjectsResultParser.parse(data, requestedKeys: keys)
  }

  // MARK: - Networking helper

  private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
    do {
      return try await session.data(for: request)
    } catch let error as AcervoError {
      throw error
    } catch {
      throw error
    }
  }

  // MARK: - URL construction

  /// Path-style: `<endpoint>/<bucket>/<key>`. `path` may be empty (used
  /// for bucket-scoped operations like `ListObjectsV2`).
  private func bucketURL(path: String, queryItems: [URLQueryItem]) -> URL {
    var components = URLComponents(
      url: credentials.endpoint,
      resolvingAgainstBaseURL: false
    )!

    // Compose the path. The endpoint may already carry a trailing slash
    // or non-empty path; join carefully.
    let endpointPath = components.path
    var newPath = endpointPath
    if !newPath.hasSuffix("/") { newPath += "/" }
    newPath += credentials.bucket
    if !path.isEmpty {
      // The key portion may itself contain '/' separators; preserve them
      // verbatim. URLComponents will percent-encode each character that
      // is not legal in a path segment when we read .url back, but the
      // SigV4 canonicalization re-encodes the path independently from
      // the wire form.
      newPath += "/" + path
    }
    components.path = newPath

    if !queryItems.isEmpty {
      components.queryItems = queryItems
    }

    guard let url = components.url else {
      // The credentials-supplied endpoint plus a path-style suffix should
      // always compose into a valid URL; failing here indicates a
      // construction bug, not a runtime input error.
      preconditionFailure(
        "S3CDNClient: failed to construct URL for path '\(path)'"
      )
    }
    return url
  }

  // MARK: - DeleteObjects XML envelope

  /// Build the canonical S3 `DeleteObjects` request body.
  ///
  /// ```xml
  /// <Delete>
  ///   <Object><Key>foo</Key></Object>
  ///   <Object><Key>bar</Key></Object>
  ///   <Quiet>false</Quiet>
  /// </Delete>
  /// ```
  static func buildDeleteObjectsXML(keys: [String]) -> String {
    var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    out += "<Delete>"
    for key in keys {
      out += "<Object><Key>\(xmlEscape(key))</Key></Object>"
    }
    out += "<Quiet>false</Quiet>"
    out += "</Delete>"
    return out
  }

  static func xmlEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
      switch ch {
      case "&": out += "&amp;"
      case "<": out += "&lt;"
      case ">": out += "&gt;"
      case "\"": out += "&quot;"
      case "'": out += "&apos;"
      default: out.append(ch)
      }
    }
    return out
  }

  // MARK: - Hashing helpers

  /// Base64-encoded MD5 digest of `data`. Used for `Content-MD5` on the
  /// `DeleteObjects` POST. Insecure module is fine here — this is for an
  /// integrity check the AWS spec hard-codes, not for a security boundary.
  static func base64MD5(of data: Data) -> String {
    let digest = Insecure.MD5.hash(data: data)
    return Data(digest).base64EncodedString()
  }

  // MARK: - Date parsing

  /// Parses an HTTP-date (RFC 7231 IMF-fixdate) such as
  /// `"Wed, 21 Oct 2015 07:28:00 GMT"`. Returns `nil` on failure.
  static func parseHTTPDate(_ s: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: s)
  }
}

// MARK: - ListObjectsV2 XML parser

/// Event-driven parser for the `ListObjectsV2` response. We only extract
/// the fields downstream code uses: `Contents/Key`, `Contents/Size`,
/// `Contents/ETag`, `IsTruncated`, and `NextContinuationToken`.
private final class ListObjectsV2Parser: NSObject, XMLParserDelegate {

  struct Result {
    var objects: [S3Object] = []
    var isTruncated: Bool = false
    var nextContinuationToken: String? = nil
  }

  private var result = Result()
  private var elementStack: [String] = []

  private var currentKey: String? = nil
  private var currentSize: Int64? = nil
  private var currentETag: String? = nil
  private var currentText: String = ""
  private var insideContents: Bool = false

  static func parse(_ data: Data) throws -> Result {
    let delegate = ListObjectsV2Parser()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    if !parser.parse() {
      // TODO(WU2.S1): replace with cdnOperationFailed (parse failure)
      throw URLError(.cannotParseResponse)
    }
    return delegate.result
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    elementStack.append(elementName)
    currentText = ""
    if elementName == "Contents" {
      insideContents = true
      currentKey = nil
      currentSize = nil
      currentETag = nil
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    currentText += string
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    defer { _ = elementStack.popLast() }

    let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

    if insideContents {
      switch elementName {
      case "Key":
        currentKey = trimmed
      case "Size":
        currentSize = Int64(trimmed)
      case "ETag":
        currentETag = trimmed
      case "Contents":
        if let key = currentKey {
          result.objects.append(
            S3Object(
              key: key,
              size: currentSize ?? 0,
              etag: currentETag ?? ""
            )
          )
        }
        insideContents = false
      default:
        break
      }
    } else {
      switch elementName {
      case "IsTruncated":
        result.isTruncated = (trimmed.lowercased() == "true")
      case "NextContinuationToken":
        result.nextContinuationToken = trimmed.isEmpty ? nil : trimmed
      default:
        break
      }
    }
    currentText = ""
  }
}

// MARK: - DeleteObjects XML parser

/// Parses the S3 `DeleteObjects` response into a per-key result list.
///
/// ```xml
/// <DeleteResult>
///   <Deleted><Key>foo</Key></Deleted>
///   <Error><Key>bar</Key><Code>AccessDenied</Code><Message>...</Message></Error>
/// </DeleteResult>
/// ```
///
/// Any `requestedKeys` not present in the response are emitted as
/// successful (the `Quiet=false` flag means S3 should report every key,
/// but R2 has been observed to omit `<Deleted>` when nothing was
/// deleted; we treat absence as success since the key is gone either way).
private final class DeleteObjectsResultParser: NSObject, XMLParserDelegate {

  private var deleted: Set<String> = []
  private var errors: [(key: String, code: String?, message: String?)] = []

  private var elementStack: [String] = []
  private var currentText: String = ""

  // Per-element scratch values.
  private var currentDeletedKey: String? = nil
  private var insideDeleted: Bool = false

  private var currentErrorKey: String? = nil
  private var currentErrorCode: String? = nil
  private var currentErrorMessage: String? = nil
  private var insideError: Bool = false

  static func parse(
    _ data: Data,
    requestedKeys: [String]
  ) throws -> [S3DeleteResult] {
    let delegate = DeleteObjectsResultParser()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    if !parser.parse() {
      // TODO(WU2.S1): replace with cdnOperationFailed (parse failure)
      throw URLError(.cannotParseResponse)
    }

    var byKey: [String: S3DeleteResult] = [:]
    for key in delegate.deleted {
      byKey[key] = S3DeleteResult(key: key, success: true, error: nil)
    }
    for entry in delegate.errors {
      let combined: String?
      switch (entry.code, entry.message) {
      case (let c?, let m?):
        combined = "\(c): \(m)"
      case (let c?, nil):
        combined = c
      case (nil, let m?):
        combined = m
      default:
        combined = nil
      }
      byKey[entry.key] = S3DeleteResult(
        key: entry.key, success: false, error: combined
      )
    }

    return requestedKeys.map { key in
      // Default: assume success when the response did not mention the key.
      byKey[key] ?? S3DeleteResult(key: key, success: true, error: nil)
    }
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    elementStack.append(elementName)
    currentText = ""
    switch elementName {
    case "Deleted":
      insideDeleted = true
      currentDeletedKey = nil
    case "Error":
      insideError = true
      currentErrorKey = nil
      currentErrorCode = nil
      currentErrorMessage = nil
    default:
      break
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    currentText += string
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    defer { _ = elementStack.popLast() }
    let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

    if insideDeleted {
      switch elementName {
      case "Key":
        currentDeletedKey = trimmed
      case "Deleted":
        if let k = currentDeletedKey { deleted.insert(k) }
        insideDeleted = false
      default:
        break
      }
    } else if insideError {
      switch elementName {
      case "Key":
        currentErrorKey = trimmed
      case "Code":
        currentErrorCode = trimmed
      case "Message":
        currentErrorMessage = trimmed
      case "Error":
        if let k = currentErrorKey {
          errors.append(
            (key: k, code: currentErrorCode, message: currentErrorMessage)
          )
        }
        insideError = false
      default:
        break
      }
    }
    currentText = ""
  }
}
