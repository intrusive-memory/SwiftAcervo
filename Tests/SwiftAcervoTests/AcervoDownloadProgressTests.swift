import Foundation
import Testing
@testable import SwiftAcervo

@Suite("AcervoDownloadProgress Tests")
struct AcervoDownloadProgressTests {

    @Test("overallProgress for first file (fileIndex=0)")
    func overallProgressFirstFile() {
        let progress = AcervoDownloadProgress(
            fileName: "config.json",
            bytesDownloaded: 500,
            totalBytes: 1000,
            fileIndex: 0,
            totalFiles: 3
        )
        // (0 + 0.5) / 3 = 0.1667
        let expected = (0.0 + 0.5) / 3.0
        #expect(abs(progress.overallProgress - expected) < 0.0001)
    }

    @Test("overallProgress for middle file (fileIndex=1 of 3)")
    func overallProgressMiddleFile() {
        let progress = AcervoDownloadProgress(
            fileName: "tokenizer.json",
            bytesDownloaded: 750,
            totalBytes: 1000,
            fileIndex: 1,
            totalFiles: 3
        )
        // (1 + 0.75) / 3 = 0.5833
        let expected = (1.0 + 0.75) / 3.0
        #expect(abs(progress.overallProgress - expected) < 0.0001)
    }

    @Test("overallProgress for last file (fileIndex=2 of 3)")
    func overallProgressLastFile() {
        let progress = AcervoDownloadProgress(
            fileName: "model.safetensors",
            bytesDownloaded: 1000,
            totalBytes: 1000,
            fileIndex: 2,
            totalFiles: 3
        )
        // (2 + 1.0) / 3 = 1.0
        #expect(abs(progress.overallProgress - 1.0) < 0.0001)
    }

    @Test("overallProgress with unknown totalBytes")
    func overallProgressUnknownTotal() {
        let progress = AcervoDownloadProgress(
            fileName: "config.json",
            bytesDownloaded: 500,
            totalBytes: nil,
            fileIndex: 1,
            totalFiles: 3
        )
        // totalBytes is nil, so fileProgress = 0.0
        // (1 + 0.0) / 3 = 0.3333
        let expected = 1.0 / 3.0
        #expect(abs(progress.overallProgress - expected) < 0.0001)
    }

    @Test("overallProgress clamping (never > 1.0)")
    func overallProgressClamping() {
        // Edge case: bytesDownloaded exceeds totalBytes
        let progress = AcervoDownloadProgress(
            fileName: "config.json",
            bytesDownloaded: 2000,
            totalBytes: 1000,
            fileIndex: 2,
            totalFiles: 3
        )
        // (2 + 2.0) / 3 = 1.333 -> clamped to 1.0
        #expect(progress.overallProgress <= 1.0)
        #expect(progress.overallProgress == 1.0)
    }

    @Test("overallProgress with zero totalFiles returns 0")
    func overallProgressZeroTotalFiles() {
        let progress = AcervoDownloadProgress(
            fileName: "config.json",
            bytesDownloaded: 500,
            totalBytes: 1000,
            fileIndex: 0,
            totalFiles: 0
        )
        #expect(progress.overallProgress == 0.0)
    }

    @Test("overallProgress is never negative")
    func overallProgressNeverNegative() {
        let progress = AcervoDownloadProgress(
            fileName: "config.json",
            bytesDownloaded: 0,
            totalBytes: 1000,
            fileIndex: 0,
            totalFiles: 5
        )
        #expect(progress.overallProgress >= 0.0)
        #expect(progress.overallProgress == 0.0)
    }

    // MARK: - Edge Case Tests

    @Test("progress with zero totalBytes treats file progress as zero")
    func progressZeroTotalBytes() {
        let progress = AcervoDownloadProgress(
            fileName: "config.json",
            bytesDownloaded: 500,
            totalBytes: 0,
            fileIndex: 1,
            totalFiles: 3
        )
        // totalBytes is 0, so fileProgress = 0.0
        // (1 + 0.0) / 3 = 0.3333
        let expected = 1.0 / 3.0
        #expect(abs(progress.overallProgress - expected) < 0.0001)
    }

    @Test("progress at exactly 100% for single file")
    func progressExactly100PercentSingleFile() {
        let progress = AcervoDownloadProgress(
            fileName: "model.safetensors",
            bytesDownloaded: 5000,
            totalBytes: 5000,
            fileIndex: 0,
            totalFiles: 1
        )
        // (0 + 1.0) / 1 = 1.0
        #expect(progress.overallProgress == 1.0)
    }

    @Test("progress rounding stays within bounds")
    func progressRounding() {
        // Create a scenario where floating point arithmetic could cause drift
        let progress = AcervoDownloadProgress(
            fileName: "file.bin",
            bytesDownloaded: 333,
            totalBytes: 1000,
            fileIndex: 0,
            totalFiles: 3
        )
        // (0 + 0.333) / 3 = 0.111
        let result = progress.overallProgress
        #expect(result >= 0.0)
        #expect(result <= 1.0)
        #expect(abs(result - 0.111) < 0.001)
    }

    @Test("progress with totalFiles of 1 and partial download")
    func progressSingleFilePartial() {
        let progress = AcervoDownloadProgress(
            fileName: "large.safetensors",
            bytesDownloaded: 250,
            totalBytes: 1000,
            fileIndex: 0,
            totalFiles: 1
        )
        // (0 + 0.25) / 1 = 0.25
        #expect(abs(progress.overallProgress - 0.25) < 0.0001)
    }

    @Test("progress with nil totalBytes and zero fileIndex")
    func progressNilTotalBytesFirstFile() {
        let progress = AcervoDownloadProgress(
            fileName: "config.json",
            bytesDownloaded: 1000,
            totalBytes: nil,
            fileIndex: 0,
            totalFiles: 5
        )
        // totalBytes is nil, fileProgress = 0.0
        // (0 + 0.0) / 5 = 0.0
        #expect(progress.overallProgress == 0.0)
    }

    @Test("progress clamping with large bytesDownloaded and single file")
    func progressClampingSingleFile() {
        let progress = AcervoDownloadProgress(
            fileName: "file.bin",
            bytesDownloaded: 10000,
            totalBytes: 1000,
            fileIndex: 0,
            totalFiles: 1
        )
        // (0 + 10.0) / 1 = 10.0 -> clamped to 1.0
        #expect(progress.overallProgress == 1.0)
    }

    @Test("progress with very large byte values")
    func progressLargeByteValues() {
        let progress = AcervoDownloadProgress(
            fileName: "model.safetensors",
            bytesDownloaded: 2_362_232_012,
            totalBytes: 4_724_464_025,
            fileIndex: 0,
            totalFiles: 1
        )
        // (0 + ~0.5) / 1 = ~0.5
        let result = progress.overallProgress
        #expect(result > 0.49)
        #expect(result < 0.51)
    }
}
