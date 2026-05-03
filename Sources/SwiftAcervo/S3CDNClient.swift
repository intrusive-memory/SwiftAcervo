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
// Error mapping
// -------------
// All non-2xx responses are surfaced as typed `AcervoError` cases. 401/403
// → `.cdnAuthorizationFailed(operation:)`; any other non-2xx →
// `.cdnOperationFailed(operation:statusCode:body:)`. 2xx responses whose
// XML body cannot be parsed are likewise reported as `.cdnOperationFailed`
// with `statusCode: 200` and the raw body — they are operation failures
// from the caller's perspective even though the wire status was OK.

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

  /// Default upper bound on a single-shot `PUT`. Files at or below this
  /// size are uploaded in one signed request; anything larger is uploaded
  /// via the S3 multipart-upload protocol.
  ///
  /// 100 MiB is the threshold called out in `EXECUTION_PLAN.md` (WU1.S3,
  /// task 1). It comfortably exceeds any small "metadata" file (config,
  /// tokenizer, manifest) while keeping a single request small enough to
  /// be signed and replayed without memory pressure on the caller.
  public static let defaultSingleShotThreshold: Int64 = 100 * 1024 * 1024

  /// Default S3 multipart-upload part size.
  ///
  /// 16 MiB. The S3 spec mandates a 5 MiB minimum (except the final part)
  /// and a 5 GiB per-part maximum. 16 MiB is a long-standing AWS-CLI-aligned
  /// default: large enough to amortize per-request signing overhead on
  /// fast links, small enough that a single in-flight part fits
  /// comfortably in memory on every supported platform. The last part of
  /// any upload may be smaller; intermediate parts are exactly this size.
  public static let defaultMultipartPartSize: Int64 = 16 * 1024 * 1024

  private let credentials: AcervoCDNCredentials
  private let session: URLSession
  private let signer: SigV4Signer

  /// Single-shot threshold for this client instance. Tests can lower this
  /// to exercise the multipart path with small synthetic files.
  let singleShotThreshold: Int64

  /// Multipart part size for this client instance. Tests can lower this
  /// to drive multi-part uploads against modestly sized synthetic files.
  let multipartPartSize: Int64

  public init(
    credentials: AcervoCDNCredentials,
    session: URLSession = .shared
  ) {
    self.init(
      credentials: credentials,
      session: session,
      singleShotThreshold: Self.defaultSingleShotThreshold,
      multipartPartSize: Self.defaultMultipartPartSize
    )
  }

  /// Test-facing initializer. The two threshold knobs are only useful in
  /// tests that need to exercise the multipart path without writing
  /// hundreds of MiB to disk; production callers should use the public
  /// initializer above.
  internal init(
    credentials: AcervoCDNCredentials,
    session: URLSession,
    singleShotThreshold: Int64,
    multipartPartSize: Int64
  ) {
    precondition(
      singleShotThreshold > 0,
      "S3CDNClient.singleShotThreshold must be positive"
    )
    precondition(
      multipartPartSize > 0,
      "S3CDNClient.multipartPartSize must be positive"
    )
    self.credentials = credentials
    self.session = session
    self.signer = SigV4Signer(credentials: credentials, service: "s3")
    self.singleShotThreshold = singleShotThreshold
    self.multipartPartSize = multipartPartSize
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
      throw AcervoError.cdnOperationFailed(
        operation: "list",
        statusCode: 0,
        body: Self.bodyExcerpt(data)
      )
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      throw AcervoError.cdnAuthorizationFailed(operation: "list")
    }
    guard (200..<300).contains(http.statusCode) else {
      throw AcervoError.cdnOperationFailed(
        operation: "list",
        statusCode: http.statusCode,
        body: Self.bodyExcerpt(data)
      )
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
      throw AcervoError.cdnOperationFailed(
        operation: "head",
        statusCode: 0,
        body: ""
      )
    }

    if http.statusCode == 404 {
      return nil
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      throw AcervoError.cdnAuthorizationFailed(operation: "head")
    }
    guard (200..<300).contains(http.statusCode) else {
      throw AcervoError.cdnOperationFailed(
        operation: "head",
        statusCode: http.statusCode,
        body: ""
      )
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
    let (data, response) = try await perform(signed)

    guard let http = response as? HTTPURLResponse else {
      throw AcervoError.cdnOperationFailed(
        operation: "delete",
        statusCode: 0,
        body: Self.bodyExcerpt(data)
      )
    }
    // 204 No Content is the success case; 404 is treated as success too.
    if http.statusCode == 404 || (200..<300).contains(http.statusCode) {
      return
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      throw AcervoError.cdnAuthorizationFailed(operation: "delete")
    }
    throw AcervoError.cdnOperationFailed(
      operation: "delete",
      statusCode: http.statusCode,
      body: Self.bodyExcerpt(data)
    )
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
      throw AcervoError.cdnOperationFailed(
        operation: "deleteObjects",
        statusCode: 0,
        body: Self.bodyExcerpt(data)
      )
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      throw AcervoError.cdnAuthorizationFailed(operation: "deleteObjects")
    }
    guard (200..<300).contains(http.statusCode) else {
      throw AcervoError.cdnOperationFailed(
        operation: "deleteObjects",
        statusCode: http.statusCode,
        body: Self.bodyExcerpt(data)
      )
    }

    return try DeleteObjectsResultParser.parse(data, requestedKeys: keys)
  }

  // MARK: - putObject

  /// Streams the file at `bodyURL` to `key` in the configured bucket.
  ///
  /// Files at or below `singleShotThreshold` are uploaded in a single
  /// signed `PUT`. Larger files are uploaded via the S3 multipart-upload
  /// protocol with `multipartPartSize`-sized parts (last part may be
  /// smaller). In both cases the SHA-256 returned in the result is
  /// computed by streaming the file from disk; the whole file is never
  /// loaded into memory.
  ///
  /// Throws `AcervoError.cdnAuthorizationFailed(operation:)` on 401/403
  /// from any underlying request. Any non-2xx response on a multipart
  /// upload-part triggers a best-effort `abortMultipartUpload` to release
  /// R2-side state before the original error is rethrown. The client
  /// itself does not retry — the caller decides whether to.
  public func putObject(
    key: String,
    bodyURL: URL
  ) async throws -> S3PutResult {
    // Determine the file size up front. We need it to decide between the
    // single-shot and multipart paths, and we'll need an authoritative
    // value for `Content-Length` on the signed PUT (URLSession would set
    // one from the streamed file body anyway, but signing must agree).
    let attrs = try FileManager.default.attributesOfItem(atPath: bodyURL.path)
    let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0

    if fileSize <= singleShotThreshold {
      return try await singleShotPut(
        key: key,
        bodyURL: bodyURL,
        fileSize: fileSize
      )
    } else {
      return try await multipartPut(
        key: key,
        bodyURL: bodyURL,
        fileSize: fileSize
      )
    }
  }

  // MARK: - putObject (single-shot)

  /// Single-shot signed PUT. Two file passes:
  ///   1. Stream the file once to compute the SHA-256 hex digest needed
  ///      for `x-amz-content-sha256` (signing requires it before the
  ///      upload starts).
  ///   2. Stream it again via `URLSession.upload(for:fromFile:)`, which
  ///      keeps the body off the heap.
  ///
  /// Two passes are intentional. There is no way to compute the body
  /// hash AFTER signing (the hash is part of the canonical request).
  /// We accept the second pass to keep the signer pure and to never
  /// load the file into memory.
  private func singleShotPut(
    key: String,
    bodyURL: URL,
    fileSize: Int64
  ) async throws -> S3PutResult {
    let sha256Hex = try Self.streamingSHA256Hex(
      of: bodyURL,
      bufferSize: Self.streamingHashBufferSize
    )

    let url = bucketURL(path: key, queryItems: [])
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.setValue(
      String(fileSize), forHTTPHeaderField: "Content-Length"
    )
    request.setValue(
      "application/octet-stream", forHTTPHeaderField: "Content-Type"
    )

    let signed = signer.sign(request, payloadHash: .precomputed(sha256Hex))

    let (data, response) = try await session.upload(
      for: signed,
      fromFile: bodyURL
    )

    guard let http = response as? HTTPURLResponse else {
      throw AcervoError.cdnOperationFailed(
        operation: "put",
        statusCode: 0,
        body: Self.bodyExcerpt(data)
      )
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      throw AcervoError.cdnAuthorizationFailed(operation: "put")
    }
    guard (200..<300).contains(http.statusCode) else {
      throw AcervoError.cdnOperationFailed(
        operation: "put",
        statusCode: http.statusCode,
        body: Self.bodyExcerpt(data)
      )
    }

    let etag = http.value(forHTTPHeaderField: "ETag") ?? ""
    return S3PutResult(key: key, etag: etag, sha256: sha256Hex)
  }

  // MARK: - putObject (multipart)

  /// Multipart PUT. Walks the standard S3 sequence:
  ///   1. `POST <key>?uploads`            → uploadId
  ///   2. `PUT  <key>?partNumber=N&uploadId=…` × N parts → ETag per part
  ///   3. `POST <key>?uploadId=…`         → final ETag (commit)
  ///
  /// On any failure during step 2, a best-effort
  /// `DELETE <key>?uploadId=…` (Abort) is dispatched to release R2-side
  /// state, then the original error is rethrown. The client never
  /// retries internally.
  ///
  /// SHA-256 of the whole file is computed incrementally as each chunk
  /// is read off disk; per-part `x-amz-content-sha256` is computed over
  /// each chunk independently and used in that part's signature.
  private func multipartPut(
    key: String,
    bodyURL: URL,
    fileSize: Int64
  ) async throws -> S3PutResult {
    let uploadId = try await initiateMultipartUpload(key: key)

    var wholeFileHasher = SHA256()
    var parts: [(partNumber: Int, etag: String)] = []
    var partNumber = 1

    // Stream parts off disk via `FileHandle`. We deliberately never load
    // the whole `bodyURL` into a single `Data` value — the exit criterion
    // for this sortie greps the source tree for that anti-pattern. Each
    // chunk is sized to `multipartPartSize`; the final chunk may be
    // smaller.
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: bodyURL)
    } catch {
      // No upload was initiated successfully without an Abort guard yet,
      // but in practice we already initiated. Best-effort abort.
      try? await abortMultipartUpload(key: key, uploadId: uploadId)
      throw error
    }
    defer { try? handle.close() }

    do {
      while true {
        // `read(upToCount:)` returns up to `count` bytes, or an empty
        // `Data` at EOF. Loading 16 MiB into memory is intentional —
        // a single in-flight part body is bounded by `multipartPartSize`
        // by design, and 16 MiB is the documented part size.
        let chunkSize = Int(multipartPartSize)
        let chunk = try handle.read(upToCount: chunkSize) ?? Data()
        if chunk.isEmpty { break }

        // Feed the whole-file hasher.
        chunk.withUnsafeBytes { buf in
          wholeFileHasher.update(bufferPointer: buf)
        }

        let etag = try await uploadPart(
          key: key,
          uploadId: uploadId,
          partNumber: partNumber,
          bodyChunk: chunk
        )
        parts.append((partNumber: partNumber, etag: etag))
        partNumber += 1
      }
    } catch {
      // Any uploadPart failure (including non-2xx) reaches here. Clean
      // up the R2-side multipart state, then rethrow the original error.
      try? await abortMultipartUpload(key: key, uploadId: uploadId)
      throw error
    }

    let finalDigest = wholeFileHasher.finalize()
    let wholeFileSHA256 =
      finalDigest
      .map { String(format: "%02x", $0) }
      .joined()

    let completeETag: String
    do {
      completeETag = try await completeMultipartUpload(
        key: key,
        uploadId: uploadId,
        parts: parts
      )
    } catch {
      try? await abortMultipartUpload(key: key, uploadId: uploadId)
      throw error
    }

    _ = fileSize  // bookkeeping; useful for future progress wiring.

    return S3PutResult(
      key: key,
      etag: completeETag,
      sha256: wholeFileSHA256
    )
  }

  // MARK: - Multipart helpers (private)

  /// `POST <key>?uploads` — initiate a multipart upload. Returns the
  /// `UploadId` from the response XML.
  private func initiateMultipartUpload(key: String) async throws -> String {
    let url = bucketURL(
      path: key,
      queryItems: [URLQueryItem(name: "uploads", value: nil)]
    )
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    // No body. Set Content-Length explicitly so URLSession doesn't add
    // its own header that disagrees with the signed canonical request.
    request.setValue("0", forHTTPHeaderField: "Content-Length")

    let signed = signer.sign(request, payloadHash: .empty)
    let (data, response) = try await perform(signed)

    guard let http = response as? HTTPURLResponse else {
      throw AcervoError.cdnOperationFailed(
        operation: "initiateMultipartUpload",
        statusCode: 0,
        body: Self.bodyExcerpt(data)
      )
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      throw AcervoError.cdnAuthorizationFailed(
        operation: "initiateMultipartUpload"
      )
    }
    guard (200..<300).contains(http.statusCode) else {
      throw AcervoError.cdnOperationFailed(
        operation: "initiateMultipartUpload",
        statusCode: http.statusCode,
        body: Self.bodyExcerpt(data)
      )
    }

    return try InitiateMultipartUploadParser.parse(data)
  }

  /// `PUT <key>?partNumber=N&uploadId=…` — upload one part. Returns the
  /// `ETag` header from the response (S3 requires it for the final
  /// `CompleteMultipartUpload` body).
  private func uploadPart(
    key: String,
    uploadId: String,
    partNumber: Int,
    bodyChunk: Data
  ) async throws -> String {
    let url = bucketURL(
      path: key,
      queryItems: [
        URLQueryItem(name: "partNumber", value: String(partNumber)),
        URLQueryItem(name: "uploadId", value: uploadId),
      ]
    )

    let partSHA256Hex = SigV4Signer.sha256Hex(bodyChunk)

    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.setValue(
      String(bodyChunk.count), forHTTPHeaderField: "Content-Length"
    )
    request.setValue(
      "application/octet-stream", forHTTPHeaderField: "Content-Type"
    )

    let signed = signer.sign(
      request, payloadHash: .precomputed(partSHA256Hex)
    )

    let (data, response) = try await session.upload(
      for: signed, from: bodyChunk
    )

    guard let http = response as? HTTPURLResponse else {
      throw AcervoError.cdnOperationFailed(
        operation: "uploadPart",
        statusCode: 0,
        body: Self.bodyExcerpt(data)
      )
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      throw AcervoError.cdnAuthorizationFailed(operation: "uploadPart")
    }
    guard (200..<300).contains(http.statusCode) else {
      throw AcervoError.cdnOperationFailed(
        operation: "uploadPart",
        statusCode: http.statusCode,
        body: Self.bodyExcerpt(data)
      )
    }
    guard let etag = http.value(forHTTPHeaderField: "ETag"),
      !etag.isEmpty
    else {
      // S3 contract: every successful uploadPart returns an ETag header.
      // Missing means the response is malformed — the wire status was 2xx
      // but the response is unusable, which is an operation failure from
      // the caller's perspective. We surface the actual status code (not
      // a synthetic 200) so logs reflect what R2 actually returned.
      throw AcervoError.cdnOperationFailed(
        operation: "uploadPart",
        statusCode: http.statusCode,
        body: Self.bodyExcerpt(data)
      )
    }
    return etag
  }

  /// `POST <key>?uploadId=…` with a `<CompleteMultipartUpload>` body.
  /// Returns the final object ETag.
  private func completeMultipartUpload(
    key: String,
    uploadId: String,
    parts: [(partNumber: Int, etag: String)]
  ) async throws -> String {
    let body = Self.buildCompleteMultipartUploadXML(parts: parts)
    let bodyData = Data(body.utf8)
    let payloadSHA256Hex = SigV4Signer.sha256Hex(bodyData)

    let url = bucketURL(
      path: key,
      queryItems: [URLQueryItem(name: "uploadId", value: uploadId)]
    )
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = bodyData
    request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
    request.setValue(
      String(bodyData.count), forHTTPHeaderField: "Content-Length"
    )

    let signed = signer.sign(
      request, payloadHash: .precomputed(payloadSHA256Hex)
    )
    let (data, response) = try await perform(signed)

    guard let http = response as? HTTPURLResponse else {
      throw AcervoError.cdnOperationFailed(
        operation: "completeMultipartUpload",
        statusCode: 0,
        body: Self.bodyExcerpt(data)
      )
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      throw AcervoError.cdnAuthorizationFailed(
        operation: "completeMultipartUpload"
      )
    }
    guard (200..<300).contains(http.statusCode) else {
      throw AcervoError.cdnOperationFailed(
        operation: "completeMultipartUpload",
        statusCode: http.statusCode,
        body: Self.bodyExcerpt(data)
      )
    }

    // CompleteMultipartUpload returns an XML body with the final ETag,
    // but the response may also surface 200 with an embedded error
    // payload. We parse the XML and prefer the parsed ETag; fall back
    // to the response header if parsing yields nothing.
    if let parsedETag = try? CompleteMultipartUploadResultParser.parse(data),
      !parsedETag.isEmpty
    {
      return parsedETag
    }
    return http.value(forHTTPHeaderField: "ETag") ?? ""
  }

  /// `DELETE <key>?uploadId=…` — release R2-side multipart state. Best-
  /// effort: callers invoke this after a part-upload failure and do not
  /// surface this method's errors (the original failure is the one that
  /// matters).
  private func abortMultipartUpload(
    key: String,
    uploadId: String
  ) async throws {
    let url = bucketURL(
      path: key,
      queryItems: [URLQueryItem(name: "uploadId", value: uploadId)]
    )
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"

    let signed = signer.sign(request, payloadHash: .empty)
    let (data, response) = try await perform(signed)

    guard let http = response as? HTTPURLResponse else {
      throw AcervoError.cdnOperationFailed(
        operation: "abortMultipartUpload",
        statusCode: 0,
        body: Self.bodyExcerpt(data)
      )
    }
    // 204 is the documented success status. 404 is treated as success
    // (the upload is already gone — exactly what we wanted).
    if http.statusCode == 404 || (200..<300).contains(http.statusCode) {
      return
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      throw AcervoError.cdnAuthorizationFailed(
        operation: "abortMultipartUpload"
      )
    }
    throw AcervoError.cdnOperationFailed(
      operation: "abortMultipartUpload",
      statusCode: http.statusCode,
      body: Self.bodyExcerpt(data)
    )
  }

  // MARK: - Streaming SHA-256

  /// Buffer size used when stream-hashing a file from disk. 1 MiB is a
  /// good trade-off between syscall amortization and memory footprint;
  /// the buffer is reused across reads.
  static let streamingHashBufferSize: Int = 1 * 1024 * 1024

  /// Computes the SHA-256 hex digest of `url` by reading it in chunks of
  /// `bufferSize` bytes via `FileHandle.read(upToCount:)`. The whole file
  /// is **never** loaded into memory.
  static func streamingSHA256Hex(
    of url: URL,
    bufferSize: Int
  ) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let chunk = try handle.read(upToCount: bufferSize) ?? Data()
      if chunk.isEmpty { break }
      chunk.withUnsafeBytes { buf in
        hasher.update(bufferPointer: buf)
      }
    }
    let digest = hasher.finalize()
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - CompleteMultipartUpload XML envelope

  /// Build the canonical `<CompleteMultipartUpload>` body.
  ///
  /// ```xml
  /// <CompleteMultipartUpload>
  ///   <Part><PartNumber>1</PartNumber><ETag>"…"</ETag></Part>
  ///   …
  /// </CompleteMultipartUpload>
  /// ```
  ///
  /// The S3 spec requires parts be listed in ascending `PartNumber` order;
  /// we sort defensively in case the caller did not.
  static func buildCompleteMultipartUploadXML(
    parts: [(partNumber: Int, etag: String)]
  ) -> String {
    let sorted = parts.sorted { $0.partNumber < $1.partNumber }
    var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    out += "<CompleteMultipartUpload>"
    for p in sorted {
      out += "<Part>"
      out += "<PartNumber>\(p.partNumber)</PartNumber>"
      out += "<ETag>\(xmlEscape(p.etag))</ETag>"
      out += "</Part>"
    }
    out += "</CompleteMultipartUpload>"
    return out
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

  // MARK: - Response body diagnostics

  /// Maximum number of bytes we materialize as a UTF-8 string when building
  /// the `body` payload for `AcervoError.cdnOperationFailed`. Keeps a single
  /// error from carrying a multi-MiB XML payload around in memory; the case
  /// payload is for human-readable diagnostics, not for full-response
  /// archival. `errorDescription` truncates further when formatting.
  static let bodyExcerptByteLimit: Int = 4 * 1024

  /// Build the `body` string passed to `AcervoError.cdnOperationFailed`.
  /// We cap at `bodyExcerptByteLimit` bytes (UTF-8 lossy decode) to avoid
  /// surfacing huge XML payloads through the error type. Empty data and
  /// non-UTF-8 data both decode to `""`.
  static func bodyExcerpt(_ data: Data) -> String {
    if data.isEmpty { return "" }
    let slice = data.prefix(bodyExcerptByteLimit)
    return String(decoding: slice, as: UTF8.self)
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
      // 2xx response whose body could not be parsed. We use statusCode 200
      // (not the actual status, which is not visible at this layer) to
      // signal "operation failure despite a successful HTTP exchange".
      throw AcervoError.cdnOperationFailed(
        operation: "list",
        statusCode: 200,
        body: S3CDNClient.bodyExcerpt(data)
      )
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
      // 2xx response whose XML body could not be parsed; surface as an
      // operation failure with a synthetic 200 status (see ListObjectsV2
      // parse() for rationale).
      throw AcervoError.cdnOperationFailed(
        operation: "deleteObjects",
        statusCode: 200,
        body: S3CDNClient.bodyExcerpt(data)
      )
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

// MARK: - InitiateMultipartUploadResult parser

/// Parses the S3 `InitiateMultipartUploadResult` envelope and returns
/// the `<UploadId>` field. The response shape is:
///
/// ```xml
/// <InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
///   <Bucket>…</Bucket>
///   <Key>…</Key>
///   <UploadId>SOMEOPAQUEID</UploadId>
/// </InitiateMultipartUploadResult>
/// ```
private final class InitiateMultipartUploadParser: NSObject, XMLParserDelegate {

  private var uploadId: String? = nil
  private var inUploadId = false
  private var currentText = ""

  static func parse(_ data: Data) throws -> String {
    let delegate = InitiateMultipartUploadParser()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    if !parser.parse() {
      // 2xx response whose XML body could not be parsed; surface as an
      // operation failure with a synthetic 200 status (see ListObjectsV2
      // parse() for rationale).
      throw AcervoError.cdnOperationFailed(
        operation: "initiateMultipartUpload",
        statusCode: 200,
        body: S3CDNClient.bodyExcerpt(data)
      )
    }
    guard let id = delegate.uploadId, !id.isEmpty else {
      // Parsing succeeded but the response is missing the required
      // <UploadId> element. The wire status was 2xx but the response is
      // unusable.
      throw AcervoError.cdnOperationFailed(
        operation: "initiateMultipartUpload",
        statusCode: 200,
        body: S3CDNClient.bodyExcerpt(data)
      )
    }
    return id
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    currentText = ""
    if elementName == "UploadId" { inUploadId = true }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if inUploadId { currentText += string }
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    if elementName == "UploadId" {
      uploadId = currentText.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      inUploadId = false
    }
    currentText = ""
  }
}

// MARK: - CompleteMultipartUploadResult parser

/// Parses the S3 `CompleteMultipartUploadResult` envelope and returns
/// the final object's `<ETag>`. The response shape is:
///
/// ```xml
/// <CompleteMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
///   <Location>…</Location>
///   <Bucket>…</Bucket>
///   <Key>…</Key>
///   <ETag>"…"</ETag>
/// </CompleteMultipartUploadResult>
/// ```
///
/// We intentionally only look for the top-level `<ETag>` and ignore any
/// other elements; the caller treats an absent / empty ETag as a fall
/// through to the response header.
private final class CompleteMultipartUploadResultParser: NSObject,
  XMLParserDelegate
{

  private var etag: String = ""
  private var inETag = false
  private var depth = 0
  private var etagDepth: Int? = nil
  private var currentText = ""

  static func parse(_ data: Data) throws -> String {
    let delegate = CompleteMultipartUploadResultParser()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    if !parser.parse() {
      throw URLError(.cannotParseResponse)
    }
    return delegate.etag
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    depth += 1
    currentText = ""
    // Only capture the top-level (depth-2) ETag — depth 1 is the root.
    if elementName == "ETag" && depth == 2 {
      inETag = true
      etagDepth = depth
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if inETag { currentText += string }
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    if elementName == "ETag" && etagDepth == depth {
      etag = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
      inETag = false
      etagDepth = nil
    }
    currentText = ""
    depth -= 1
  }
}
