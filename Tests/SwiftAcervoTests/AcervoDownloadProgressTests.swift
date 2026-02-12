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
}
