# ModelDownloadManager — Usage Examples

`ModelDownloadManager` is a high-level orchestrator for downloading multiple AI models with aggregated progress reporting and disk space validation. This guide provides real-world usage patterns for consuming libraries (SwiftBruja, SwiftTuberia, etc.) that need to manage model lifecycle during app initialization or feature activation.

## When to Use ModelDownloadManager

Use `ModelDownloadManager` when you need to:

- **Download multiple models** in a single operation (LLM + TTS, or multiple specialized models)
- **Report aggregated progress** to users without managing per-model state
- **Validate disk space** before attempting downloads
- **Handle network failures** gracefully with proper error context
- **Support cancellation** without losing partial downloads

For single-model downloads, you can use the lower-level `Acervo.ensureAvailable()` API directly.

---

## Example 1: Single Model Download

The simplest pattern: download one LLM model with basic error handling.

```swift
import SwiftAcervo

func downloadLanguageModel() async throws {
    let modelId = "mlx-community/Qwen2.5-7B-Instruct-4bit"
    
    // Download with progress reporting
    try await ModelDownloadManager.shared.ensureModelsAvailable([modelId]) { progress in
        let percentComplete = Int(progress.fraction * 100)
        let mbDownloaded = progress.bytesDownloaded / (1024 * 1024)
        
        print("\(progress.model)")
        print("  File: \(progress.currentFileName)")
        print("  Progress: \(percentComplete)%")
        print("  Downloaded: \(mbDownloaded) MB")
    }
    
    print("Language model ready!")
}

// Usage in app initialization:
do {
    try await downloadLanguageModel()
} catch let error as AcervoError {
    // Convert to app-specific error type
    switch error {
    case .networkError(let description):
        print("Network error: \(description)")
    case .manifestDownloadFailed:
        print("Could not fetch model information from CDN")
    case .sizeMismatchError:
        print("Downloaded file is corrupted, please retry")
    default:
        print("Download failed: \(error.localizedDescription)")
    }
}
```

**Key Points**:
- Pass a single-element array to `ensureModelsAvailable()`
- Progress callbacks fire for each chunk downloaded
- `AcervoError` is caught and converted to your domain-specific errors
- If the model is already available locally, the download is skipped automatically

---

## Example 2: Multiple Models with Custom Progress UI

Download a multi-model setup (LLM + TTS) and integrate progress into a SwiftUI `ProgressView`.

```swift
import SwiftAcervo
import SwiftUI

class ModelDownloadCoordinator: NSObject, ObservableObject {
    @Published var downloadProgress: Double = 0.0
    @Published var currentFile: String = ""
    @Published var statusMessage: String = "Preparing models..."
    @Published var isDownloading: Bool = false
    
    let modelIds = [
        "mlx-community/Qwen2.5-7B-Instruct-4bit",      // LLM
        "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", // TTS
    ]
    
    func startModelDownload() async {
        DispatchQueue.main.async {
            self.isDownloading = true
            self.statusMessage = "Starting download..."
        }
        
        do {
            // Progress callback updates the @Published properties on the main thread
            try await ModelDownloadManager.shared.ensureModelsAvailable(modelIds) { progress in
                DispatchQueue.main.async {
                    self.downloadProgress = progress.fraction
                    
                    let file = progress.currentFileName
                    let mb = progress.bytesDownloaded / (1024 * 1024)
                    let total = progress.bytesTotal / (1024 * 1024)
                    
                    self.currentFile = file
                    self.statusMessage = "[\(progress.model)] \(file)"
                    
                    // Log transitions between models
                    if progress.fraction >= 0.5 && self.modelIds.count > 1 {
                        print("Downloading second model...")
                    }
                }
            }
            
            DispatchQueue.main.async {
                self.statusMessage = "All models ready!"
                self.downloadProgress = 1.0
                self.isDownloading = false
            }
        } catch {
            DispatchQueue.main.async {
                self.statusMessage = "Download failed: \(error.localizedDescription)"
                self.isDownloading = false
            }
        }
    }
}

// SwiftUI View integration:
struct ModelDownloadView: View {
    @StateObject var coordinator = ModelDownloadCoordinator()
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Downloading Models")
                .font(.headline)
            
            ProgressView(value: coordinator.downloadProgress)
                .tint(.blue)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(coordinator.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if !coordinator.currentFile.isEmpty {
                    Text("File: \(coordinator.currentFile)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Button(action: {
                Task {
                    await coordinator.startModelDownload()
                }
            }) {
                Text("Download")
                    .frame(maxWidth: .infinity)
            }
            .disabled(coordinator.isDownloading)
        }
        .padding()
    }
}
```

**Key Points**:
- `ModelDownloadCoordinator` encapsulates download state for SwiftUI
- Progress callbacks dispatch updates to `DispatchQueue.main` to safely update `@Published` properties
- Each model shows its file being downloaded in real time
- Users see a single progress bar covering both models

---

## Example 3: Error Handling Patterns

Demonstrate catching specific `AcervoError` cases and converting to library-specific errors.

```swift
import SwiftAcervo

// Define your own error type
enum ModelDownloadError: LocalizedError {
    case networkUnavailable(String)
    case insufficientSpace(bytesNeeded: Int64)
    case modelNotFound(modelId: String)
    case corruptedDownload(modelId: String)
    case unsupportedManifest(String)
    
    var errorDescription: String? {
        switch self {
        case .networkUnavailable(let msg):
            return "Network unavailable: \(msg)"
        case .insufficientSpace(let bytes):
            let gb = Double(bytes) / (1024 * 1024 * 1024)
            return "Not enough disk space. Need \(String(format: "%.1f", gb)) GB"
        case .modelNotFound(let id):
            return "Model not found: \(id)"
        case .corruptedDownload(let id):
            return "Model \(id) failed verification. Try again."
        case .unsupportedManifest(let msg):
            return "Unsupported model format: \(msg)"
        }
    }
}

class ModelManager {
    func downloadWithErrorHandling(modelIds: [String]) async throws {
        do {
            try await ModelDownloadManager.shared.ensureModelsAvailable(modelIds) { progress in
                // Update UI
            }
        } catch let error as AcervoError {
            // Convert AcervoError to ModelDownloadError
            let customError = mapAcervoErrorToCustom(error, modelIds: modelIds)
            throw customError
        }
    }
    
    private func mapAcervoErrorToCustom(_ error: AcervoError, modelIds: [String]) -> ModelDownloadError {
        switch error {
        case .networkError(let description):
            return .networkUnavailable(description)
            
        case .manifestDownloadFailed, .manifestDecodingFailed:
            return .modelNotFound(modelId: modelIds.first ?? "unknown")
            
        case .sizeMismatchError:
            return .corruptedDownload(modelId: modelIds.first ?? "unknown")
            
        case .manifestIntegrityFailed, .manifestVersionUnsupported:
            return .unsupportedManifest(error.localizedDescription)
            
        case .directoryCreationFailed:
            // Likely a permissions issue
            return .insufficientSpace(bytesNeeded: 0)
            
        default:
            // Fallback for unmapped errors
            return .corruptedDownload(modelId: modelIds.first ?? "unknown")
        }
    }
}

// Usage with retry logic:
func downloadWithRetry(modelIds: [String], maxRetries: Int = 2) async throws {
    var lastError: ModelDownloadError?
    
    for attempt in 1...maxRetries {
        do {
            try await ModelManager().downloadWithErrorHandling(modelIds: modelIds)
            return // Success
        } catch let error as ModelDownloadError {
            lastError = error
            
            switch error {
            case .networkUnavailable:
                print("Attempt \(attempt) failed: network error. Retrying in 5 seconds...")
                try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                continue
                
            case .corruptedDownload(let modelId):
                print("Attempt \(attempt): \(modelId) corrupted. Retrying...")
                continue
                
            case .insufficientSpace, .modelNotFound, .unsupportedManifest:
                // Don't retry on permanent errors
                throw error
            }
        }
    }
    
    if let lastError = lastError {
        throw lastError
    }
}
```

**Key Points**:
- Create a domain-specific error type that maps from `AcervoError`
- Different error cases warrant different retry strategies
- Network errors and corrupted downloads can be retried
- Permanent errors (missing model, unsupported format) should fail immediately
- Wrap `AcervoError` to provide context to your app's error handling

---

## Example 4: Disk Space Validation Workflow

Call `validateCanDownload()` before attempting to download, then make intelligent decisions.

```swift
import SwiftAcervo

class DiskSpaceChecker {
    func getAvailableDiskSpace() -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let available = attrs[.systemFreeSize] as? NSNumber else {
            return 0
        }
        return available.int64Value
    }
    
    func canDownloadModels(_ modelIds: [String]) async throws -> Bool {
        // Get total bytes needed from CDN manifests
        let requiredBytes = try await ModelDownloadManager.shared.validateCanDownload(modelIds)
        let availableBytes = getAvailableDiskSpace()
        
        // Leave 1 GB safety margin
        let safetyMargin: Int64 = 1024 * 1024 * 1024
        
        return (availableBytes - safetyMargin) >= requiredBytes
    }
    
    func presentDownloadDecision(
        modelIds: [String],
        requiredBytes: Int64,
        availableBytes: Int64
    ) async throws -> Bool {
        let requiredGB = Double(requiredBytes) / (1024 * 1024 * 1024)
        let availableGB = Double(availableBytes) / (1024 * 1024 * 1024)
        let safetyMargin = 1.0
        
        if availableGB - safetyMargin < requiredGB {
            // Not enough space
            let shortfall = requiredGB - (availableGB - safetyMargin)
            print("Not enough space!")
            print("Need: \(String(format: "%.2f", requiredGB)) GB")
            print("Available: \(String(format: "%.2f", availableGB - safetyMargin)) GB")
            print("Short by: \(String(format: "%.2f", shortfall)) GB")
            
            // Offer options:
            // 1. Delete application cache
            if try deleteAppCache() {
                print("Cleared app cache. Retrying...")
                return try await canDownloadModels(modelIds)
            }
            
            // 2. Delete temp files
            deleteTemporaryFiles()
            print("Cleared temp files. Retrying...")
            return try await canDownloadModels(modelIds)
        }
        
        // Enough space, ask user for confirmation
        print("Download requires \(String(format: "%.2f", requiredGB)) GB")
        print("You have \(String(format: "%.2f", availableGB)) GB available")
        print("Proceed? (y/n)")
        
        // In a real app, present a UIAlertController or SwiftUI alert
        return true
    }
    
    private func deleteAppCache() throws -> Bool {
        let cachePath = NSSearchPathForDirectoriesInDomains(
            .cachesDirectory,
            .userDomainMask,
            true
        ).first ?? ""
        
        if FileManager.default.fileExists(atPath: cachePath) {
            try FileManager.default.removeItem(atPath: cachePath)
            return true
        }
        return false
    }
    
    private func deleteTemporaryFiles() {
        let tmpPath = NSTemporaryDirectory()
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: tmpPath)
            for file in files {
                let fullPath = (tmpPath as NSString).appendingPathComponent(file)
                try FileManager.default.removeItem(atPath: fullPath)
            }
        } catch {
            print("Could not delete temp files: \(error)")
        }
    }
}

// Workflow in your app:
func initializeModelsWithSpaceCheck() async throws {
    let checker = DiskSpaceChecker()
    let modelIds = [
        "mlx-community/Qwen2.5-7B-Instruct-4bit",
        "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16",
    ]
    
    do {
        // Step 1: Validate total space needed
        let requiredBytes = try await ModelDownloadManager.shared.validateCanDownload(modelIds)
        let availableBytes = checker.getAvailableDiskSpace()
        
        // Step 2: Check if we can proceed
        let canProceed = try await checker.presentDownloadDecision(
            modelIds: modelIds,
            requiredBytes: requiredBytes,
            availableBytes: availableBytes
        )
        
        guard canProceed else {
            print("User cancelled download")
            return
        }
        
        // Step 3: Download with progress
        try await ModelDownloadManager.shared.ensureModelsAvailable(modelIds) { progress in
            print("[\(progress.model)] \(Int(progress.fraction * 100))% — \(progress.currentFileName)")
        }
        
        print("All models downloaded successfully")
        
    } catch let error as AcervoError {
        print("Failed to initialize models: \(error.localizedDescription)")
        throw error
    }
}
```

**Key Points**:
- Call `validateCanDownload()` to get the total size upfront
- Compare against available disk space (with a safety margin)
- Offer users choices: delete cache, clear temp files, or cancel
- Only proceed with download after confirmation
- Use the same model IDs for validation and actual download

---

## Example 5: Cancellation and Resume Behavior

Demonstrate how cancellation works and why partial files enable resume-like behavior.

```swift
import SwiftAcervo

class ResumableDownloadManager {
    private var currentDownloadTask: Task<Void, Never>?
    
    // Start a download that can be cancelled
    func startDownload(
        modelIds: [String],
        onProgress: @escaping (ModelDownloadProgress) -> Void,
        onCompletion: @escaping (Result<Void, Error>) -> Void
    ) {
        // Cancel any existing download
        currentDownloadTask?.cancel()
        
        // Start new download task
        currentDownloadTask = Task {
            do {
                try await ModelDownloadManager.shared.ensureModelsAvailable(
                    modelIds,
                    progress: onProgress
                )
                onCompletion(.success(()))
            } catch {
                // Check if error is due to cancellation
                if Task.isCancelled {
                    print("Download was cancelled")
                    print("Partial files remain on disk and can be resumed")
                } else {
                    onCompletion(.failure(error))
                }
            }
        }
    }
    
    // Cancel the current download
    func cancelDownload() {
        print("Cancelling download...")
        currentDownloadTask?.cancel()
        currentDownloadTask = nil
    }
    
    // Resume a download (same call as initial download)
    func resumeDownload(
        modelIds: [String],
        onProgress: @escaping (ModelDownloadProgress) -> Void,
        onCompletion: @escaping (Result<Void, Error>) -> Void
    ) {
        print("Resuming download...")
        // Partial files are left on disk, so re-calling ensureModelsAvailable
        // will only download missing chunks
        startDownload(modelIds: modelIds, onProgress: onProgress, onCompletion: onCompletion)
    }
}

// Usage pattern:
class AppDownloadCoordinator {
    let manager = ResumableDownloadManager()
    let modelIds = [
        "mlx-community/Qwen2.5-7B-Instruct-4bit",
        "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16",
    ]
    
    func userInitiatedDownload() {
        manager.startDownload(
            modelIds: modelIds,
            onProgress: { progress in
                let percent = Int(progress.fraction * 100)
                print("[\(progress.model)] \(percent)% — \(progress.currentFileName)")
            },
            onCompletion: { result in
                switch result {
                case .success:
                    print("Download complete!")
                case .failure(let error):
                    print("Download failed: \(error.localizedDescription)")
                    print("You can resume by calling resumeDownload()")
                }
            }
        )
    }
    
    func userCancelledDownload() {
        manager.cancelDownload()
        print("Download paused. Call resumeDownload() to continue.")
    }
    
    func userClickedResume() {
        // Resume continues from where it was cancelled
        manager.resumeDownload(
            modelIds: modelIds,
            onProgress: { progress in
                let percent = Int(progress.fraction * 100)
                print("[\(progress.model)] \(percent)% (resumed) — \(progress.currentFileName)")
            },
            onCompletion: { result in
                switch result {
                case .success:
                    print("Download complete!")
                case .failure(let error):
                    print("Download failed: \(error.localizedDescription)")
                }
            }
        )
    }
    
    func appWillTerminate() {
        // Cancelling here leaves partial files on disk
        // The next app launch can resume
        manager.cancelDownload()
    }
}

// Demonstration of resume behavior:
func demonstrateCancellationAndResume() async throws {
    let coordinator = AppDownloadCoordinator()
    
    // Start download
    coordinator.userInitiatedDownload()
    
    // Wait 5 seconds then cancel
    try await Task.sleep(nanoseconds: 5_000_000_000)
    print("\n--- User cancelled after 5 seconds ---")
    coordinator.userCancelledDownload()
    
    // Wait 2 seconds then resume
    try await Task.sleep(nanoseconds: 2_000_000_000)
    print("\n--- User clicked Resume ---")
    coordinator.userClickedResume()
    
    // Output shows:
    // [mlx-community/Qwen2.5-7B-Instruct-4bit] 5% — model.safetensors
    // [mlx-community/Qwen2.5-7B-Instruct-4bit] 8% — config.json
    // --- User cancelled after 5 seconds ---
    // Cancelling download...
    // Download was cancelled
    // Partial files remain on disk and can be resumed
    //
    // --- User clicked Resume ---
    // Resuming download...
    // [mlx-community/Qwen2.5-7B-Instruct-4bit] 10% (resumed) — model.safetensors
    // [mlx-community/Qwen2.5-7B-Instruct-4bit] 100% (resumed) — config.json
    // Download complete!
}
```

**Key Points**:
- Cancellation is a normal Swift concurrency operation via `Task.cancel()`
- Partial downloads are NOT cleaned up — they remain on disk by default
- Resume is simply re-calling `ensureModelsAvailable()` with the same model IDs
- The underlying `Acervo.ensureAvailable()` detects existing files and only downloads missing chunks
- This enables pause/resume workflows without extra bookkeeping
- App termination naturally pauses the download; next launch can resume

---

## Summary

These five patterns cover the most common scenarios for consuming libraries:

1. **Single model** — Simplest case for one LLM or TTS model
2. **Multiple models with custom UI** — Multi-model downloads with SwiftUI integration
3. **Error handling** — Domain-specific error mapping and retry logic
4. **Disk space validation** — Pre-flight checks with user options
5. **Cancellation and resume** — Pause/resume workflows for long downloads

All examples use the public API of `ModelDownloadManager`:
- `validateCanDownload(_:)` — Check disk space before downloading
- `ensureModelsAvailable(_:progress:)` — Download models with progress callback

Choose the pattern that fits your app's architecture and user experience goals.
