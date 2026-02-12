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
}
