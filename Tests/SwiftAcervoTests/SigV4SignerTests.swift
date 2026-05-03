// SigV4SignerTests.swift
// SwiftAcervoTests
//
// Conformance tests for the SigV4 signer against the canonical AWS
// `aws4_testsuite` vectors (vendored verbatim per requirements §6.2 +
// Decision Log #12). Each named test reproduces the documented
// HTTP request as a URLRequest, signs it with the canonical example
// credentials at the canonical example date, and asserts the
// `Authorization` header equals the value AWS publishes.
//
// Canonical credentials and date (constant across all aws4_testsuite vectors):
//   accessKeyId      = "AKIDEXAMPLE"
//   secretAccessKey  = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
//   region           = "us-east-1"
//   service          = "service"
//   signing date     = 2015-08-30T12:36:00Z
//
// References:
//   - https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
//   - aws4_testsuite (originally distributed by AWS, widely mirrored)

import Foundation
import Testing

@testable import SwiftAcervo

@Suite("SigV4Signer Tests")
struct SigV4SignerTests {

  // MARK: - Canonical fixtures

  /// Returns the canonical aws4_testsuite credentials. Endpoint and
  /// publicBaseURL are placeholders — the signer doesn't read them.
  static func vectorCredentials() -> AcervoCDNCredentials {
    AcervoCDNCredentials(
      accessKeyId: "AKIDEXAMPLE",
      secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
      region: "us-east-1",
      bucket: "unused-by-signer",
      endpoint: URL(string: "https://example.amazonaws.com")!,
      publicBaseURL: URL(string: "https://example.amazonaws.com")!
    )
  }

  /// 2015-08-30T12:36:00Z — the canonical aws4_testsuite signing instant.
  static func vectorDate() -> Date {
    var comps = DateComponents()
    comps.timeZone = TimeZone(identifier: "UTC")
    comps.year = 2015
    comps.month = 8
    comps.day = 30
    comps.hour = 12
    comps.minute = 36
    comps.second = 0
    return Calendar(identifier: .gregorian).date(from: comps)!
  }

  static func makeSigner() -> SigV4Signer {
    SigV4Signer(credentials: vectorCredentials(), service: "service")
  }

  // MARK: - Signing key derivation (AWS reference example)
  //
  // Per AWS docs, the signing-key chain for the canonical example
  // produces these four well-known intermediate digests. They are
  // published in the AWS docs and serve as a load-bearing "is HMAC
  // wired up correctly" check that does not depend on the canonical
  // request.

  @Test("Signing-key derivation reproduces AWS-published intermediate digests")
  func signingKeyDerivationReferenceExample() {
    let secret = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
    let kSecret = Data("AWS4\(secret)".utf8)

    // From the AWS reference example (date=20120215, region=us-east-1,
    // service=iam). These four hex strings are documented by AWS as the
    // expected outputs of each HMAC step.
    let kDate = SigV4Signer.hmac(key: kSecret, data: Data("20120215".utf8))
    #expect(
      kDate.map { String(format: "%02x", $0) }.joined()
        == "969fbb94feb542b71ede6f87fe4d5fa29c789342b0f407474670f0c2489e0a0d"
    )

    let kRegion = SigV4Signer.hmac(key: kDate, data: Data("us-east-1".utf8))
    #expect(
      kRegion.map { String(format: "%02x", $0) }.joined()
        == "69daa0209cd9c5ff5c8ced464a696fd4252e981430b10e3d3fd8e2f197d7a70c"
    )

    let kService = SigV4Signer.hmac(key: kRegion, data: Data("iam".utf8))
    #expect(
      kService.map { String(format: "%02x", $0) }.joined()
        == "f72cfd46f26bc4643f06a11eabb6c0ba18780c19a8da0c31ace671265e3c87fa"
    )

    let kSigning = SigV4Signer.hmac(
      key: kService,
      data: Data("aws4_request".utf8)
    )
    #expect(
      kSigning.map { String(format: "%02x", $0) }.joined()
        == "f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d"
    )
  }

  // MARK: - Canonical aws4_testsuite vectors

  /// `get-vanilla` — minimum GET. Bare path "/", no query, just the
  /// required Host + x-amz-date headers, empty payload.
  @Test("get-vanilla produces the canonical Authorization header")
  func getVanilla() {
    var req = URLRequest(url: URL(string: "https://example.amazonaws.com/")!)
    req.httpMethod = "GET"

    let signed = Self.makeSigner().sign(
      req, payloadHash: .empty, date: Self.vectorDate()
    )
    let auth = signed.value(forHTTPHeaderField: "Authorization") ?? ""

    #expect(
      auth
        == "AWS4-HMAC-SHA256 "
        + "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
        + "SignedHeaders=host;x-amz-date, "
        + "Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
    )
    #expect(signed.value(forHTTPHeaderField: "x-amz-date") == "20150830T123600Z")
    #expect(
      signed.value(forHTTPHeaderField: "x-amz-content-sha256")
        == SigV4Signer.emptyPayloadHash
    )
  }

  /// `get-vanilla-query` — single-param query string `Param1=value1`.
  @Test("get-vanilla-query produces the canonical Authorization header")
  func getVanillaQuery() {
    var req = URLRequest(
      url: URL(string: "https://example.amazonaws.com/?Param1=value1")!
    )
    req.httpMethod = "GET"

    let signed = Self.makeSigner().sign(
      req, payloadHash: .empty, date: Self.vectorDate()
    )
    let auth = signed.value(forHTTPHeaderField: "Authorization") ?? ""

    #expect(
      auth
        == "AWS4-HMAC-SHA256 "
        + "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
        + "SignedHeaders=host;x-amz-date, "
        + "Signature=a67d582fa61cc504c4bae71f336f98b97f1ea3c7a6bfe1b6e45aec72011b9aeb"
    )
  }

  /// `get-vanilla-query-order-key-case` — two query parameters, presented
  /// out of canonical order. The signer must sort them to produce the
  /// canonical query string.
  @Test("get-vanilla-query-order-key-case sorts params canonically")
  func getVanillaQueryOrderKeyCase() {
    var req = URLRequest(
      url: URL(string: "https://example.amazonaws.com/?Param2=value2&Param1=value1")!
    )
    req.httpMethod = "GET"

    let signed = Self.makeSigner().sign(
      req, payloadHash: .empty, date: Self.vectorDate()
    )
    let auth = signed.value(forHTTPHeaderField: "Authorization") ?? ""

    #expect(
      auth
        == "AWS4-HMAC-SHA256 "
        + "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
        + "SignedHeaders=host;x-amz-date, "
        + "Signature=b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500"
    )
  }

  /// `get-header-key-duplicate` — two identical-name headers with two
  /// values must canonicalize to a single comma-joined header line in
  /// the signed canonical request.
  ///
  /// Per the canonical aws4_testsuite, the request is:
  ///   GET / HTTP/1.1
  ///   Host:example.amazonaws.com
  ///   My-Header1:value2
  ///   My-Header1:value2
  ///   My-Header1:value1
  ///   X-Amz-Date:20150830T123600Z
  ///
  /// URLRequest cannot represent multi-value headers natively (a second
  /// `setValue` overwrites). We simulate the canonical input by
  /// providing the comma-joined value AWS would canonicalize to:
  /// `value2,value2,value1`. The expected signature is the published one.
  @Test("get-header-key-duplicate canonicalizes multi-valued headers")
  func getHeaderKeyDuplicate() {
    var req = URLRequest(url: URL(string: "https://example.amazonaws.com/")!)
    req.httpMethod = "GET"
    req.setValue("value2,value2,value1", forHTTPHeaderField: "My-Header1")

    let signed = Self.makeSigner().sign(
      req, payloadHash: .empty, date: Self.vectorDate()
    )
    let auth = signed.value(forHTTPHeaderField: "Authorization") ?? ""

    #expect(
      auth
        == "AWS4-HMAC-SHA256 "
        + "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
        + "SignedHeaders=host;my-header1;x-amz-date, "
        + "Signature=c9d5ea9f3f72853aea855b47ea873832890dbdd183b4468f858259531a5138ea"
    )
  }

  /// `post-vanilla` — bare POST, no body, no extra headers.
  @Test("post-vanilla produces the canonical Authorization header")
  func postVanilla() {
    var req = URLRequest(url: URL(string: "https://example.amazonaws.com/")!)
    req.httpMethod = "POST"

    let signed = Self.makeSigner().sign(
      req, payloadHash: .empty, date: Self.vectorDate()
    )
    let auth = signed.value(forHTTPHeaderField: "Authorization") ?? ""

    #expect(
      auth
        == "AWS4-HMAC-SHA256 "
        + "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
        + "SignedHeaders=host;x-amz-date, "
        + "Signature=5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b"
    )
  }

  /// `post-x-www-form-urlencoded` — form body. Body bytes are
  /// `Param1=value1` (no terminating newline). The hashed-payload
  /// portion of the canonical request is the SHA-256 of those bytes:
  /// `9095672bbd1f56dfc5b65f3e153adc8731a4a654192329106275f4c7b24d0b6e`.
  @Test("post-x-www-form-urlencoded produces the canonical Authorization header")
  func postXWWWFormURLEncoded() {
    var req = URLRequest(url: URL(string: "https://example.amazonaws.com/")!)
    req.httpMethod = "POST"
    req.setValue(
      "application/x-www-form-urlencoded",
      forHTTPHeaderField: "Content-Type"
    )
    let bodyHex =
      "9095672bbd1f56dfc5b65f3e153adc8731a4a654192329106275f4c7b24d0b6e"

    let signed = Self.makeSigner().sign(
      req,
      payloadHash: .precomputed(bodyHex),
      date: Self.vectorDate()
    )
    let auth = signed.value(forHTTPHeaderField: "Authorization") ?? ""

    #expect(
      auth
        == "AWS4-HMAC-SHA256 "
        + "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
        + "SignedHeaders=content-type;host;x-amz-date, "
        + "Signature=ff11897932ad3f4e8b18135d722051e5ac45fc38421b1da7b9d196a0fe09473a"
    )
    #expect(signed.value(forHTTPHeaderField: "x-amz-content-sha256") == bodyHex)
  }

  // MARK: - R2-shaped synthetic PUT

  /// Per task 4 of the sortie: signing a synthetic R2 `PUT` with
  /// `payloadHash: .precomputed(...)` must propagate the supplied hex
  /// to the `x-amz-content-sha256` header verbatim.
  @Test("Synthetic R2 PUT propagates precomputed payload hash to header")
  func r2PutPropagatesPrecomputedPayloadHash() {
    let creds = AcervoCDNCredentials(
      accessKeyId: "test-access-key",
      secretAccessKey: "test-secret-key",
      region: "auto",
      bucket: "intrusive-memory-models",
      endpoint: URL(
        string: "https://abc123.r2.cloudflarestorage.com"
      )!,
      publicBaseURL: URL(
        string: "https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev"
      )!
    )
    let signer = SigV4Signer(credentials: creds, service: "s3")

    let putURL = URL(
      string:
        "https://abc123.r2.cloudflarestorage.com/intrusive-memory-models/models/org_repo/manifest.json"
    )!
    var req = URLRequest(url: putURL)
    req.httpMethod = "PUT"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

    // Synthetic 64-hex SHA-256 (e.g. computed by the caller while
    // streaming the file from disk).
    let payloadHex =
      "4f8c1d2b3e9a0f6c5d4e3b2a1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d"

    let signed = signer.sign(req, payloadHash: .precomputed(payloadHex))

    #expect(
      signed.value(forHTTPHeaderField: "x-amz-content-sha256") == payloadHex
    )
    #expect(signed.value(forHTTPHeaderField: "Authorization") != nil)
    #expect(signed.value(forHTTPHeaderField: "x-amz-date") != nil)
    #expect(signed.httpMethod == "PUT")
    // Original request must be unchanged.
    #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(req.value(forHTTPHeaderField: "x-amz-date") == nil)
    #expect(req.value(forHTTPHeaderField: "x-amz-content-sha256") == nil)
  }

  // MARK: - URI encoding internals

  @Test("uriEncode treats unreserved chars as identity, percent-encodes the rest")
  func uriEncodeUnreserved() {
    #expect(SigV4Signer.uriEncode("AZaz09-_.~", encodeSlash: true) == "AZaz09-_.~")
    #expect(SigV4Signer.uriEncode(" ", encodeSlash: true) == "%20")
    #expect(SigV4Signer.uriEncode("/", encodeSlash: true) == "%2F")
    #expect(SigV4Signer.uriEncode("/", encodeSlash: false) == "/")
    #expect(SigV4Signer.uriEncode("a b", encodeSlash: true) == "a%20b")
  }
}
