import Foundation
import Testing

@testable import SwiftAcervo

@Suite("AcervoError Tests")
struct AcervoErrorTests {

  @Test("Each error case has a non-nil errorDescription")
  func allCasesHaveDescription() {
    let errors: [AcervoError] = [
      .directoryCreationFailed("/some/path"),
      .modelNotFound("org/repo"),
      .downloadFailed(fileName: "config.json", statusCode: 404),
      .networkError(URLError(.notConnectedToInternet)),
      .modelAlreadyExists("org/repo"),
      .migrationFailed(source: "/old/path", reason: "permission denied"),
      .invalidModelId("bad-id"),
      .componentNotRegistered("test-component"),
      .componentNotDownloaded("test-component"),
      .integrityCheckFailed(file: "model.safetensors", expected: "abc123", actual: "xyz789"),
      .componentFileNotFound(component: "test-component", file: "weights.bin"),
      .manifestDownloadFailed(statusCode: 404),
      .manifestDecodingFailed(URLError(.cannotParseResponse)),
      .manifestIntegrityFailed(expected: "abc", actual: "def"),
      .manifestVersionUnsupported(99),
      .manifestModelIdMismatch(expected: "org/repo", actual: "other/model"),
      .downloadSizeMismatch(fileName: "model.safetensors", expected: 1000, actual: 500),
      .fileNotInManifest(fileName: "missing.json", modelId: "org/repo"),
      .cdnAuthorizationFailed(operation: "list"),
      .cdnOperationFailed(operation: "put", statusCode: 500, body: "InternalError"),
      .publishVerificationFailed(stage: "sample-file"),
      .fetchSourceFailed(modelId: "org/repo", underlying: URLError(.timedOut)),
      .manifestZeroByteFile(path: "weights.bin"),
      .manifestPostWriteCorrupted(path: "/tmp/staging/manifest.json"),
      .manifestRelativePathOutsideBase(file: "/tmp/elsewhere", base: "/tmp/staging"),
      .publishOrphanPruneFailed(
        failedKeys: ["models/org_repo/old.bin"],
        publishedManifest: CDNManifest(
          manifestVersion: 1,
          modelId: "org/repo",
          slug: "org_repo",
          updatedAt: "2026-01-01T00:00:00Z",
          files: [],
          manifestChecksum: String(repeating: "0", count: 64)
        )
      ),
    ]

    for error in errors {
      #expect(error.errorDescription != nil)
      #expect(!error.errorDescription!.isEmpty)
    }
  }

  @Test("modelNotFound includes model ID in description")
  func modelNotFoundIncludesModelId() {
    let modelId = "mlx-community/Qwen2.5-7B-Instruct-4bit"
    let error = AcervoError.modelNotFound(modelId)
    let description = error.errorDescription!

    #expect(description.contains(modelId))
  }

  @Test("downloadFailed includes fileName and statusCode")
  func downloadFailedIncludesDetails() {
    let fileName = "model.safetensors"
    let statusCode = 403
    let error = AcervoError.downloadFailed(fileName: fileName, statusCode: statusCode)
    let description = error.errorDescription!

    #expect(description.contains(fileName))
    #expect(description.contains(String(statusCode)))
  }

  // MARK: - Component Registry Error Cases

  @Test("componentNotRegistered includes component ID in description")
  func componentNotRegisteredIncludesId() {
    let componentId = "t5-xxl-encoder-int4"
    let error = AcervoError.componentNotRegistered(componentId)
    let description = error.errorDescription!

    #expect(description.contains(componentId))
  }

  @Test("componentNotDownloaded includes component ID in description")
  func componentNotDownloadedIncludesId() {
    let componentId = "pixart-dit-int4"
    let error = AcervoError.componentNotDownloaded(componentId)
    let description = error.errorDescription!

    #expect(description.contains(componentId))
  }

  @Test("integrityCheckFailed includes file, expected, and actual in description")
  func integrityCheckFailedIncludesAllValues() {
    let file = "model.safetensors"
    let expected = "abc123def456"
    let actual = "xyz789ghi012"
    let error = AcervoError.integrityCheckFailed(file: file, expected: expected, actual: actual)
    let description = error.errorDescription!

    #expect(description.contains(file))
    #expect(description.contains(expected))
    #expect(description.contains(actual))
  }

  @Test("componentFileNotFound includes component and file in description")
  func componentFileNotFoundIncludesBothValues() {
    let component = "sdxl-vae-decoder-fp16"
    let file = "diffusion_pytorch_model.safetensors"
    let error = AcervoError.componentFileNotFound(component: component, file: file)
    let description = error.errorDescription!

    #expect(description.contains(component))
    #expect(description.contains(file))
  }

  // MARK: - CDN Mutation Error Cases

  @Test("cdnAuthorizationFailed has non-empty localizedDescription including operation")
  func cdnAuthorizationFailedDescription() {
    let operation = "deleteObjects"
    let error = AcervoError.cdnAuthorizationFailed(operation: operation)
    let description = error.localizedDescription

    #expect(!description.isEmpty)
    #expect(description.contains(operation))
  }

  @Test("cdnOperationFailed includes operation and status code in description")
  func cdnOperationFailedIncludesOperationAndStatus() {
    let operation = "put"
    let statusCode = 503
    let body = "ServiceUnavailable: please retry"
    let error = AcervoError.cdnOperationFailed(
      operation: operation,
      statusCode: statusCode,
      body: body
    )
    let description = error.localizedDescription

    #expect(!description.isEmpty)
    #expect(description.contains(operation))
    #expect(description.contains(String(statusCode)))
  }

  @Test("cdnOperationFailed truncates very long bodies in description")
  func cdnOperationFailedTruncatesBody() {
    // Build a body well past the 512-char excerpt limit.
    let body = String(repeating: "a", count: 8 * 1024)
    let error = AcervoError.cdnOperationFailed(
      operation: "list",
      statusCode: 500,
      body: body
    )
    let description = error.localizedDescription

    #expect(!description.isEmpty)
    // The description must not echo the full body verbatim — it should
    // be truncated with a hint that the full payload is on the case.
    #expect(description.count < body.count)
    #expect(description.contains("truncated"))
  }

  @Test("cdnOperationFailed handles empty body gracefully")
  func cdnOperationFailedEmptyBody() {
    let error = AcervoError.cdnOperationFailed(
      operation: "head",
      statusCode: 404,
      body: ""
    )
    let description = error.localizedDescription

    #expect(!description.isEmpty)
    #expect(description.contains("head"))
    #expect(description.contains("404"))
  }

  @Test("publishVerificationFailed includes stage in description")
  func publishVerificationFailedIncludesStage() {
    let stage = "manifest-fetch"
    let error = AcervoError.publishVerificationFailed(stage: stage)
    let description = error.localizedDescription

    #expect(!description.isEmpty)
    #expect(description.contains(stage))
  }

  @Test("fetchSourceFailed includes modelId in description")
  func fetchSourceFailedIncludesModelId() {
    let modelId = "mlx-community/Qwen2.5-7B-Instruct-4bit"
    let underlying = URLError(.cannotConnectToHost)
    let error = AcervoError.fetchSourceFailed(
      modelId: modelId,
      underlying: underlying
    )
    let description = error.localizedDescription

    #expect(!description.isEmpty)
    #expect(description.contains(modelId))
  }
}
