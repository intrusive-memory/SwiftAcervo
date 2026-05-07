// BundleComponentSmokeTests.swift
// SwiftAcervoTests — OPERATION SHARED PANTRY, Sortie 7
//
// End-to-end smoke test for the bundle-component shape against the real
// production CDN. Tests compile unconditionally but skip at runtime unless
// the INTEGRATION_TESTS environment variable is set.
//
// Gating convention (mirrors IntegrationTests.swift and ModelDownloadManagerTests.swift):
//   guard ProcessInfo.processInfo.environment["INTEGRATION_TESTS"] != nil else { return }
//
// To run this smoke test:
//   INTEGRATION_TESTS=1 ACERVO_APP_GROUP_ID=group.dev.com.example.acervo \
//       xcodebuild test -scheme SwiftAcervo-Package \
//       -destination 'platform=macOS,arch=arm64'
//
// Requirements exercised (against real CDN):
//   R1 — ensureComponentReady downloads exactly declared files; other bundle files absent.
//   R2 — Files land at the correct subfolder-preserving paths.
//   R4 — deleteComponent removes only one component's files; sibling files survive.
//
// File selection rationale:
//   Both files are small JSON configs (< 5 KB each) so the test completes quickly.
//   - text_encoder/config.json   — explicit subfolder-scoped config; confirms subfolder layout.
//   - tokenizer_config.json      — root-level tokenizer config; standard HF model file.
//   Together they represent two distinct logical components sharing one CDN manifest.

import Foundation
import Testing

@testable import SwiftAcervo

// MARK: - BundleComponentSmokeTests

extension SharedStaticStateSuite.AppGroupEnvironmentSuite {

  /// Smoke tests for the bundle-component pattern against the real production CDN.
  ///
  /// Nested under `AppGroupEnvironmentSuite` (`.serialized`) so the
  /// `ACERVO_APP_GROUP_ID` writes do not race with other suites that read or
  /// write the same env var.
  @Suite("Bundle Component Smoke Tests (Real CDN)")
  struct BundleComponentSmokeTests {

    /// The CDN model ID that holds all bundle components in a single manifest.
    private let smokeRepoId = "black-forest-labs/FLUX.2-klein-4B"

    /// Two small files declared in separate bundle components.
    /// Both are JSON configs — typically < 5 KB each.
    private let textEncoderFile = "text_encoder/config.json"
    private let tokenizerFile = "tokenizer_config.json"

    // MARK: - Main smoke test

    /// End-to-end bundle smoke test:
    ///
    /// 1. Registers two `ComponentDescriptor`s against the same `repoId`,
    ///    each declaring a different single-file subset.
    /// 2. Calls `ensureComponentReady` for both — downloads real files from CDN.
    /// 3. Asserts files land at the correct subfolder-preserving paths.
    /// 4. Asserts no sibling-bundle files (transformer, vae) are on disk.
    /// 5. Calls `deleteComponent` for one component; asserts only its file is gone.
    /// 6. Asserts the sibling component's file survives.
    @Test("Smoke: bundle components download, verify, and delete against real CDN")
    func testBundleComponentSmokeAgainstRealCDN() async throws {
      guard ProcessInfo.processInfo.environment["INTEGRATION_TESTS"] != nil else { return }

      try await withIsolatedSharedModelsDirectoryAsync { sharedDir in
        let slug = Acervo.slugify(smokeRepoId)
        let slugDir = sharedDir.appendingPathComponent(slug)
        defer {
          // Always clean up the slug directory after the test (success or failure).
          try? FileManager.default.removeItem(at: slugDir)
        }

        // MARK: Registration

        // Register two pre-hydrated bundle components against the same repoId.
        // Using the explicit files: initializer (required for bundle components —
        // see Sortie 1 audit: R1 is HONORED for the pre-hydrated path only).
        let textEncoderDesc = ComponentDescriptor(
          id: "smoke-text-encoder",
          type: .encoder,
          displayName: "Smoke Text Encoder Config",
          repoId: smokeRepoId,
          files: [ComponentFile(relativePath: textEncoderFile)],
          estimatedSizeBytes: 5_000,
          minimumMemoryBytes: 0
        )

        let tokenizerDesc = ComponentDescriptor(
          id: "smoke-tokenizer",
          type: .tokenizer,
          displayName: "Smoke Tokenizer Config",
          repoId: smokeRepoId,
          files: [ComponentFile(relativePath: tokenizerFile)],
          estimatedSizeBytes: 5_000,
          minimumMemoryBytes: 0
        )

        Acervo.register(textEncoderDesc)
        Acervo.register(tokenizerDesc)

        // MARK: ensureComponentReady — real CDN download

        // Download the text encoder component (one small JSON file).
        try await Acervo.ensureComponentReady("smoke-text-encoder")

        // Download the tokenizer component (one small JSON file).
        try await Acervo.ensureComponentReady("smoke-tokenizer")

        // MARK: R1 / R2 assertions — files at correct paths, no extras

        let fm = FileManager.default

        // Path helpers
        let textEncoderURL = slugDir.appendingPathComponent(textEncoderFile)
        let tokenizerURL = slugDir.appendingPathComponent(tokenizerFile)

        // Both declared files must exist on disk.
        #expect(
          fm.fileExists(atPath: textEncoderURL.path),
          "Smoke R1/R2: text_encoder/config.json must be downloaded and exist at slug/<subfolder>/config.json"
        )
        #expect(
          fm.fileExists(atPath: tokenizerURL.path),
          "Smoke R1/R2: tokenizer_config.json must be downloaded and exist at slug/tokenizer_config.json"
        )

        // Subfolder structure preserved for the text_encoder file (R2).
        let textEncoderParent = textEncoderURL.deletingLastPathComponent().lastPathComponent
        #expect(
          textEncoderParent == "text_encoder",
          "Smoke R2: text_encoder/config.json must land in a 'text_encoder' subdirectory, not be flattened; got parent: \(textEncoderParent)"
        )

        // File content is valid JSON.
        let textEncoderData = try Data(contentsOf: textEncoderURL)
        let textEncoderJson = try JSONSerialization.jsonObject(with: textEncoderData)
        #expect(
          textEncoderJson is [String: Any],
          "Smoke: text_encoder/config.json must be a valid JSON dictionary"
        )

        let tokenizerData = try Data(contentsOf: tokenizerURL)
        let tokenizerJson = try JSONSerialization.jsonObject(with: tokenizerData)
        #expect(
          tokenizerJson is [String: Any],
          "Smoke: tokenizer_config.json must be a valid JSON dictionary"
        )

        // Files from other bundle components (transformer, vae) must NOT be on disk (R1).
        // These would only appear if ensureComponentReady downloaded the entire manifest.
        let transformerModelURL = slugDir.appendingPathComponent("transformer/model.safetensors")
        let vaeModelURL = slugDir.appendingPathComponent("vae/diffusion_pytorch_model.safetensors")
        #expect(
          !fm.fileExists(atPath: transformerModelURL.path),
          "Smoke R1: transformer/model.safetensors must NOT be present — only declared files should be downloaded"
        )
        #expect(
          !fm.fileExists(atPath: vaeModelURL.path),
          "Smoke R1: vae/diffusion_pytorch_model.safetensors must NOT be present — only declared files should be downloaded"
        )

        // isComponentReady must reflect the downloaded state.
        #expect(
          Acervo.isComponentReady("smoke-text-encoder"),
          "Smoke R3: smoke-text-encoder must be ready after ensureComponentReady"
        )
        #expect(
          Acervo.isComponentReady("smoke-tokenizer"),
          "Smoke R3: smoke-tokenizer must be ready after ensureComponentReady"
        )

        // MARK: R4 assertion — deleteComponent removes only one component's files

        // Delete the text encoder component.
        try Acervo.deleteComponent("smoke-text-encoder")

        // The text encoder file must be gone.
        #expect(
          !fm.fileExists(atPath: textEncoderURL.path),
          "Smoke R4: text_encoder/config.json must be removed by deleteComponent('smoke-text-encoder')"
        )

        // The tokenizer file must survive — sibling-safe delete (R4).
        #expect(
          fm.fileExists(atPath: tokenizerURL.path),
          "Smoke R4: tokenizer_config.json must survive deleteComponent('smoke-text-encoder') — sibling files must not be removed"
        )

        // smoke-text-encoder is no longer ready; smoke-tokenizer is still ready.
        #expect(
          !Acervo.isComponentReady("smoke-text-encoder"),
          "Smoke R4: smoke-text-encoder must not be ready after deleteComponent"
        )
        #expect(
          Acervo.isComponentReady("smoke-tokenizer"),
          "Smoke R4: smoke-tokenizer must remain ready after deleting sibling component"
        )
      }
    }
  }
}
