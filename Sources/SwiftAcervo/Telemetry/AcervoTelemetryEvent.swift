import Foundation

public enum AcervoTelemetryEvent: Sendable {

    // --- Lifecycle ---
    case downloadOperationStart(modelID: String, requestedFiles: [String], offlineMode: Bool)
    case downloadOperationComplete(modelID: String, totalBytes: Int64, durationSeconds: Double)

    // --- Per-component download ---
    case componentDownloadStart(modelID: String, fileName: String, expectedBytes: Int64?, sourceURL: String)
    case componentDownloadComplete(modelID: String, fileName: String, actualBytes: Int64, durationSeconds: Double, throughputMBps: Double)

    // --- Manifest fetch ---
    case manifestFetchStart(modelID: String, manifestURL: String)
    case manifestFetchComplete(modelID: String, manifestVersion: String, fileCount: Int, totalDeclaredBytes: Int64)

    // --- Integrity ---
    case integrityVerifyStart(modelID: String, fileName: String, expectedSHA: String, declaredBytes: Int64)
    case integrityVerifyComplete(modelID: String, fileName: String, actualSHA: String, actualBytes: Int64, passed: Bool, durationSeconds: Double)

    // --- Cache ---
    case cacheHit(modelID: String, fileName: String, onDiskBytes: Int64, ageSeconds: Double)
    case cacheMiss(modelID: String, fileName: String, reason: CacheMissReason)

    // --- CDN HTTP ---
    case cdnRequest(method: String, url: String, statusCode: Int, latencyMS: Double, byteCount: Int64?)

    // --- Boundary memory events (per INSTRUMENTATION_PLAN §3.1) ---
    case modelLoadComplete(modelID: String, totalSizeMB: Double, componentCount: Int)
    // Adapter MUST route this through captureWithMemorySnapshot.

    // --- Error side-channel ---
    case errorThrown(phase: ErrorPhase, errorDescription: String, modelID: String?, fileName: String?)

    public enum CacheMissReason: String, Sendable {
        case notPresent           // file not on disk
        case shaChangedRemote     // CDN reports different SHA than cached
        case sizeChangedRemote    // CDN reports different byte count
        case corrupted            // on-disk SHA does not match recorded SHA
        case forcedRefresh        // caller passed forceRefresh=true
    }

    public enum ErrorPhase: String, Sendable {
        case manifestDownload
        case manifestDecode
        case manifestVersionUnsupported
        case manifestIntegrity
        case fileDownload
        case fileDownloadSize
        case fileDownloadIntegrity
        case directoryCreation
        case offlineMode
        case s3Request
        case other
    }
}
