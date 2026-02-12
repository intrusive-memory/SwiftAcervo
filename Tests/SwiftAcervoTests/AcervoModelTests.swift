import Foundation
import Testing
@testable import SwiftAcervo

@Suite("AcervoModel Tests")
struct AcervoModelTests {

    // MARK: - Test Helpers

    private func makeModel(id: String, sizeBytes: Int64 = 0) -> AcervoModel {
        AcervoModel(
            id: id,
            path: URL(fileURLWithPath: "/tmp/test"),
            sizeBytes: sizeBytes,
            downloadDate: Date()
        )
    }

    // MARK: - Slug Tests

    @Test("slug converts '/' to '_'")
    func slugConversion() {
        let model = makeModel(id: "mlx-community/Qwen2.5-7B-Instruct-4bit")
        #expect(model.slug == "mlx-community_Qwen2.5-7B-Instruct-4bit")
    }

    // MARK: - Formatted Size Tests

    @Test("formattedSize for zero bytes")
    func formattedSizeZero() {
        let model = makeModel(id: "org/repo", sizeBytes: 0)
        #expect(model.formattedSize == "0 bytes")
    }

    @Test("formattedSize for bytes (< 1 KB)")
    func formattedSizeBytes() {
        let model = makeModel(id: "org/repo", sizeBytes: 512)
        #expect(model.formattedSize == "512 bytes")
    }

    @Test("formattedSize for kilobytes")
    func formattedSizeKB() {
        let model = makeModel(id: "org/repo", sizeBytes: 125_952) // ~123 KB
        let size = model.formattedSize
        #expect(size.contains("KB"))
        #expect(!size.isEmpty)
    }

    @Test("formattedSize for megabytes")
    func formattedSizeMB() {
        let model = makeModel(id: "org/repo", sizeBytes: 125_829_120) // ~120 MB
        let size = model.formattedSize
        #expect(size.contains("MB"))
        #expect(size == "120.0 MB")
    }

    @Test("formattedSize for gigabytes")
    func formattedSizeGB() {
        let model = makeModel(id: "org/repo", sizeBytes: 4_724_464_025) // ~4.4 GB
        let size = model.formattedSize
        #expect(size.contains("GB"))
        #expect(!size.isEmpty)
    }

    // MARK: - Base Name Tests

    @Test("baseName strips quantization suffixes")
    func baseNameStripsQuantization() {
        let model4bit = makeModel(id: "mlx-community/Qwen2.5-7B-Instruct-4bit")
        #expect(model4bit.baseName == "Qwen2.5")

        let model8bit = makeModel(id: "org/Model-8bit")
        #expect(model8bit.baseName == "Model")

        let modelBf16 = makeModel(id: "org/Model-bf16")
        #expect(modelBf16.baseName == "Model")

        let modelFp16 = makeModel(id: "org/Model-fp16")
        #expect(modelFp16.baseName == "Model")
    }

    @Test("baseName strips size suffixes")
    func baseNameStripsSize() {
        let model7B = makeModel(id: "mlx-community/Qwen2.5-7B-Instruct-4bit")
        #expect(model7B.baseName == "Qwen2.5")

        let model1_7B = makeModel(id: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16")
        #expect(model1_7B.baseName == "Qwen3-TTS-12Hz")

        let model0_6B = makeModel(id: "org/Model-0.6B-Base-bf16")
        #expect(model0_6B.baseName == "Model")
    }

    @Test("baseName strips variant suffixes")
    func baseNameStripsVariant() {
        let modelInstruct = makeModel(id: "org/Model-7B-Instruct-4bit")
        #expect(modelInstruct.baseName == "Model")

        let modelBase = makeModel(id: "org/Model-1.7B-Base-bf16")
        #expect(modelBase.baseName == "Model")

        let modelVoiceDesign = makeModel(id: "org/Model-7B-VoiceDesign-4bit")
        #expect(modelVoiceDesign.baseName == "Model")
    }

    @Test("baseName for model with lowercase variant")
    func baseNameLowercaseVariant() {
        let model = makeModel(id: "mlx-community/Phi-3-mini-4k-instruct-4bit")
        #expect(model.baseName == "Phi-3-mini-4k")
    }

    // MARK: - Family Name Tests

    @Test("familyName combines org with baseName")
    func familyNameExtraction() {
        let model = makeModel(id: "mlx-community/Qwen2.5-7B-Instruct-4bit")
        #expect(model.familyName == "mlx-community/Qwen2.5")
    }

    @Test("familyName for TTS model")
    func familyNameTTS() {
        let model = makeModel(id: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16")
        #expect(model.familyName == "mlx-community/Qwen3-TTS-12Hz")
    }

    @Test("familyName for Phi model")
    func familyNamePhi() {
        let model = makeModel(id: "mlx-community/Phi-3-mini-4k-instruct-4bit")
        #expect(model.familyName == "mlx-community/Phi-3-mini-4k")
    }

    // MARK: - formattedSize Edge Cases

    @Test("formattedSize for exactly 1 KB boundary")
    func formattedSizeExact1KB() {
        let model = makeModel(id: "org/repo", sizeBytes: 1024)
        let size = model.formattedSize
        #expect(size == "1.0 KB")
    }

    @Test("formattedSize for exactly 1 MB boundary")
    func formattedSizeExact1MB() {
        let model = makeModel(id: "org/repo", sizeBytes: 1_048_576) // 1024 * 1024
        let size = model.formattedSize
        #expect(size == "1.0 MB")
    }

    @Test("formattedSize for exactly 1 GB boundary")
    func formattedSizeExact1GB() {
        let model = makeModel(id: "org/repo", sizeBytes: 1_073_741_824) // 1024^3
        let size = model.formattedSize
        #expect(size == "1.0 GB")
    }

    @Test("formattedSize for terabyte-scale value")
    func formattedSizeTB() {
        let model = makeModel(id: "org/repo", sizeBytes: 1_099_511_627_776) // 1024^4 = 1 TB
        let size = model.formattedSize
        // Should display as 1024.0 GB since the implementation only goes up to GB
        #expect(size == "1024.0 GB")
    }

    @Test("formattedSize for 1 byte")
    func formattedSizeOneByte() {
        let model = makeModel(id: "org/repo", sizeBytes: 1)
        #expect(model.formattedSize == "1 bytes")
    }

    @Test("formattedSize for just under 1 KB")
    func formattedSizeJustUnder1KB() {
        let model = makeModel(id: "org/repo", sizeBytes: 1023)
        #expect(model.formattedSize == "1023 bytes")
    }

    // MARK: - baseName Edge Cases

    @Test("baseName for model without any suffixes")
    func baseNameNoSuffixes() {
        let model = makeModel(id: "mlx-community/snac_24khz")
        #expect(model.baseName == "snac_24khz")
    }

    @Test("baseName for model with only quantization suffix")
    func baseNameOnlyQuantization() {
        let model = makeModel(id: "org/SimpleModel-4bit")
        #expect(model.baseName == "SimpleModel")
    }

    @Test("baseName for model with only size suffix")
    func baseNameOnlySize() {
        let model = makeModel(id: "org/Llama-7B")
        #expect(model.baseName == "Llama")
    }

    @Test("baseName for model with only variant suffix")
    func baseNameOnlyVariant() {
        let model = makeModel(id: "org/Model-Instruct")
        #expect(model.baseName == "Model")
    }

    @Test("baseName for model without slash uses full ID")
    func baseNameNoSlash() {
        let model = AcervoModel(
            id: "just-a-model-name-4bit",
            path: URL(fileURLWithPath: "/tmp/test"),
            sizeBytes: 0,
            downloadDate: Date()
        )
        #expect(model.baseName == "just-a-model-name")
    }

    // MARK: - familyName Edge Cases

    @Test("familyName for model without suffixes")
    func familyNameNoSuffixes() {
        let model = makeModel(id: "mlx-community/snac_24khz")
        #expect(model.familyName == "mlx-community/snac_24khz")
    }

    @Test("familyName for different quantizations produces same family")
    func familyNameSameForQuantizations() {
        let model4bit = makeModel(id: "mlx-community/Model-7B-Instruct-4bit")
        let model8bit = makeModel(id: "mlx-community/Model-7B-Instruct-8bit")
        #expect(model4bit.familyName == model8bit.familyName)
    }

    @Test("familyName for different sizes produces same family")
    func familyNameSameForSizes() {
        let model7B = makeModel(id: "mlx-community/Qwen2.5-7B-Instruct-4bit")
        let model70B = makeModel(id: "mlx-community/Qwen2.5-70B-Instruct-4bit")
        #expect(model7B.familyName == model70B.familyName)
        #expect(model7B.familyName == "mlx-community/Qwen2.5")
    }

    @Test("familyName for model without slash returns baseName only")
    func familyNameNoSlash() {
        let model = AcervoModel(
            id: "standalone-model-4bit",
            path: URL(fileURLWithPath: "/tmp/test"),
            sizeBytes: 0,
            downloadDate: Date()
        )
        #expect(model.familyName == "standalone-model")
    }
}
