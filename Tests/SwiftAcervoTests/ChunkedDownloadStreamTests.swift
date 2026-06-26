import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

/// Test-only `URLProtocol` that delivers a response body in **multiple**
/// fixed-size `Data` chunks via successive `urlProtocol(_:didLoad:)` calls,
/// mimicking how a real `URLSession` hands an OS-sized chunk at a time to a
/// `URLSessionDataDelegate`.
///
/// `MockURLProtocol` (the existing stub) delivers the entire body in a single
/// `didLoad`, so it cannot exercise the chunk-at-a-time consumption path added
/// for issue #69. This protocol splits the body so the new
/// `chunkedResponseStream` transport sees several `didReceive data:` callbacks.
///
/// State is process-global and guarded by an `NSLock`; tests that use it nest
/// under the `.serialized` suite below.
final class ChunkingMockURLProtocol: URLProtocol {

  /// The body to deliver, the chunk size to split it into, and the status code.
  struct Plan: Sendable {
    var body: Data
    var chunkSize: Int
    var statusCode: Int
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var _plan: Plan?

  static var plan: Plan? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _plan
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      _plan = newValue
    }
  }

  static func reset() {
    plan = nil
  }

  /// Ephemeral session wired to this protocol.
  static func session() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ChunkingMockURLProtocol.self]
    return URLSession(configuration: config)
  }

  // MARK: - URLProtocol

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let plan = ChunkingMockURLProtocol.plan else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }

    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: plan.statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/octet-stream"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

    // Hand the body to the loading system one chunk at a time. Each `didLoad`
    // surfaces as a separate `didReceive data:` to the data-task delegate.
    var offset = 0
    let count = plan.body.count
    let step = max(1, plan.chunkSize)
    while offset < count {
      let end = min(offset + step, count)
      client?.urlProtocol(self, didLoad: plan.body.subdata(in: offset..<end))
      offset = end
    }

    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// Tests for the chunk-at-a-time download transport added for issue #69.
///
/// `.serialized` because the tests mutate `ChunkingMockURLProtocol`'s
/// process-global plan. They touch neither `MockURLProtocol` nor the App Group
/// env var, so this suite is independent of `SharedStaticStateSuite`.
@Suite("Chunked Download Stream Tests", .serialized)
struct ChunkedDownloadStreamTests {

  /// Thread-safe sink for the `@Sendable` progress callback (which may fire off
  /// the test's thread).
  private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [AcervoDownloadProgress] = []

    func append(_ report: AcervoDownloadProgress) {
      lock.lock()
      defer { lock.unlock() }
      reports.append(report)
    }

    func snapshot() -> [AcervoDownloadProgress] {
      lock.lock()
      defer { lock.unlock() }
      return reports
    }
  }

  private static func makeSourceURL() -> URL {
    URL(string: "https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/test_repo/payload.bin")!
  }

  /// Deterministic body so the SHA-256 is stable across runs.
  private static func makeBody(byteCount: Int) -> Data {
    Data(bytes: (0..<byteCount).map { UInt8($0 % 256) }, count: byteCount)
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ChunkedDownloadStreamTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private static func cleanupTempDir(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
  }

  // MARK: - Transport consumes Data chunks, not single bytes

  @Test("chunkedResponseStream yields multi-byte Data chunks that reassemble byte-equal")
  func transportYieldsChunksNotBytes() async throws {
    ChunkingMockURLProtocol.reset()
    defer { ChunkingMockURLProtocol.reset() }

    // 256 KB body delivered in 32 KB chunks → 8 network chunks.
    let body = Self.makeBody(byteCount: 256 * 1024)
    let chunkSize = 32 * 1024
    ChunkingMockURLProtocol.plan = .init(body: body, chunkSize: chunkSize, statusCode: 200)

    let request = URLRequest(url: Self.makeSourceURL())
    let (response, stream) = try await AcervoDownloader.chunkedResponseStream(
      for: request,
      session: ChunkingMockURLProtocol.session()
    )

    #expect((response as? HTTPURLResponse)?.statusCode == 200)

    // Collect the emitted chunks and a running hash, exactly as
    // `streamDownloadFile` would.
    var assembled = Data()
    var hasher = SHA256()
    var emittedChunkCount = 0
    var sawSingleByteChunk = false
    for try await chunk in stream {
      emittedChunkCount += 1
      if chunk.count <= 1 { sawSingleByteChunk = true }
      assembled.append(chunk)
      hasher.update(data: chunk)
    }

    // (a) Byte-equal reassembly.
    #expect(assembled == body)
    // (b) SHA-256 of the streamed bytes matches the source.
    let streamedHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    #expect(streamedHash == Self.sha256Hex(body))

    // Consumption is chunk-at-a-time, NOT per byte: a per-byte loop would emit
    // one element per byte (262,144). We emitted a handful of multi-KB chunks.
    #expect(!sawSingleByteChunk)
    #expect(emittedChunkCount >= 1)
    #expect(emittedChunkCount < body.count / 1000)
  }

  // MARK: - End-to-end download over chunked delivery

  @Test("downloadFile over multi-chunk delivery writes byte-equal output with matching SHA")
  func endToEndChunkedDownloadIsByteEqual() async throws {
    ChunkingMockURLProtocol.reset()
    defer { ChunkingMockURLProtocol.reset() }

    let tempDir = try Self.makeTempDir()
    defer { Self.cleanupTempDir(tempDir) }

    // 5 MB body so the 4 MB `streamChunkSize` flush boundary is crossed,
    // delivered in 64 KB network chunks.
    let body = Self.makeBody(byteCount: 5 * 1024 * 1024)
    ChunkingMockURLProtocol.plan = .init(body: body, chunkSize: 64 * 1024, statusCode: 200)

    let manifestFile = CDNManifestFile(
      path: "payload.bin",
      sha256: Self.sha256Hex(body),
      sizeBytes: Int64(body.count)
    )
    let destination = tempDir.appendingPathComponent("payload.bin")
    let partURL = destination.appendingPathExtension("part")

    let collector = ProgressCollector()

    try await AcervoDownloader.downloadFile(
      from: Self.makeSourceURL(),
      to: destination,
      manifestFile: manifestFile,
      fileName: "payload.bin",
      fileIndex: 0,
      totalFiles: 1,
      progress: { collector.append($0) },
      session: ChunkingMockURLProtocol.session()
    )

    // Final file is byte-equal to the source (and the SHA check inside
    // downloadFile already passed, or it would have thrown).
    #expect(FileManager.default.fileExists(atPath: destination.path))
    let written = try Data(contentsOf: destination)
    #expect(written == body)
    #expect(Self.sha256Hex(written) == manifestFile.sha256)
    // Part file was atomic-renamed away.
    #expect(!FileManager.default.fileExists(atPath: partURL.path))

    // Progress still fires at ~chunk (4 MB) granularity: a 5 MB body produces
    // an initial 0-byte report, at least one intermediate flush, and a final
    // completion report, all monotonically increasing.
    let progressReports = collector.snapshot()
    #expect(progressReports.count >= 2)
    #expect(progressReports.first?.bytesDownloaded == 0)
    #expect(progressReports.last?.bytesDownloaded == Int64(body.count))
    for i in 1..<progressReports.count {
      #expect(progressReports[i].bytesDownloaded >= progressReports[i - 1].bytesDownloaded)
    }
  }
}
