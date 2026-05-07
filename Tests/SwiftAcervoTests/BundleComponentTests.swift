// BundleComponentTests.swift
// SwiftAcervoTests — OPERATION SHARED PANTRY, Sorties 2, 3 & 4
//
// Tests for the bundle-component shape: multiple ComponentDescriptors sharing
// one repoId (and therefore one CDN manifest), each declaring a distinct files
// subset. The trigger case is black-forest-labs/FLUX.2-klein-4B.
//
// Requirements under test:
//   R1 — ensureComponentReady downloads exactly the declared files (no more, no less).
//   R2 — withComponentAccess exposes only declared files; subfolder layout preserved.
//   R3 — isComponentReady checks declared files only; sibling files are irrelevant.
//   R4 — deleteComponent removes declared files only; sibling files remain untouched.
//   R5 — fetchManifest(forComponent:) returns the full CDN manifest unchanged.
//   R6 — Re-register canary fires only for id-collision with changed content.
//
// Implementation notes:
//   - All descriptors use the pre-hydrated files: initializer (per Sortie 1 audit
//     finding: R1 is HONORED for explicit-files path, GAP for un-hydrated path).
//   - R1 tests call AcervoDownloader.downloadFiles directly with MockURLProtocol.session()
//     to simulate what downloadComponent does, keeping MockURLProtocol interception intact.
//   - R3 tests create files on disk directly (simulate-download pattern used throughout
//     ComponentDownloadTests.swift and ComponentIntegrationTests.swift).
//   - R4 tests are expected to FAIL against current source (Acervo.swift:1842 removes the
//     entire slug directory). They pin the *intended* behavior; Sortie 5 fixes the source.
//   - R6 tests capture stderr via dup2+Pipe (same pattern as HydrationTests.swift:209-244).
//     The canary emits to FileHandle.standardError (ComponentRegistry.swift:70).
//   - All tests are nested under SharedStaticStateSuite.MockURLProtocolSuite and use
//     withIsolatedAcervoState / withIsolatedAcervoStateSync / withIsolatedComponentRegistrySync
//     so static state (MockURLProtocol responder and ACERVO_APP_GROUP_ID) is
//     snapshot/restored around each test.

import Foundation
import Testing

@testable import SwiftAcervo

// MARK: - BundleComponentTests

extension SharedStaticStateSuite.MockURLProtocolSuite {

  @Suite("Bundle Component Tests (R1, R3)")
  struct BundleComponentTests {

    // MARK: - Helpers

    /// Fresh temp directory per test.
    private static func makeTempDir() throws -> URL {
      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("BundleComponentTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      return dir
    }

    /// Creates specific files on disk at <tempDir>/<slug>/<relativePath>.
    private static func createFilesOnDisk(
      paths: [String],
      repoId: String,
      in baseDirectory: URL,
      fileBodies: [String: Data]
    ) throws {
      let slug = Acervo.slugify(repoId)
      let componentDir = baseDirectory.appendingPathComponent(slug)
      let fm = FileManager.default
      for path in paths {
        let fileURL = componentDir.appendingPathComponent(path)
        let parentDir = fileURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try (fileBodies[path] ?? Data("stub-\(path)".utf8)).write(to: fileURL)
      }
    }

    /// Returns true if a file exists at <baseDirectory>/<slug>/<relativePath>.
    private static func fileExists(
      _ relativePath: String,
      repoId: String,
      in baseDirectory: URL
    ) -> Bool {
      let slug = Acervo.slugify(repoId)
      let fileURL = baseDirectory.appendingPathComponent(slug).appendingPathComponent(relativePath)
      return FileManager.default.fileExists(atPath: fileURL.path)
    }

    // MARK: - R1: ensureComponentReady downloads exactly declared files

    /// R1 test 1: After simulating ensureComponentReady("bundle-transformer") via
    /// AcervoDownloader.downloadFiles with the transformer file list, assert that
    /// exactly the transformer files are on disk and the text_encoder/vae files are NOT.
    ///
    /// Strategy: call AcervoDownloader.downloadFiles with the transformer-only file list
    /// (exactly what downloadComponent does for a pre-hydrated descriptor) using
    /// MockURLProtocol.session(), then inspect the filesystem.
    @Test("R1: ensureComponentReady for transformer component downloads only transformer files")
    func testEnsureComponentReady_R1_TransformerOnlyDownloadsTransformerFiles() async throws {
      try await withIsolatedAcervoState {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        let (manifest, fileBodies) = BundleFixtures.fluxStyleManifest()
        MockURLProtocol.responder = BundleFixtures.makeResponder(
          manifest: manifest,
          fileBodies: fileBodies
        )

        let repoId = manifest.modelId
        let slug = Acervo.slugify(repoId)
        let (transformerDesc, textEncoderDesc, vaeDesc) = BundleFixtures.bundleDescriptors(
          repoId: repoId)

        Acervo.register(transformerDesc)
        Acervo.register(textEncoderDesc)
        Acervo.register(vaeDesc)

        let tempDir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let destination = tempDir.appendingPathComponent(slug)
        try AcervoDownloader.ensureDirectory(at: destination)

        // Simulate what downloadComponent does for "bundle-transformer":
        // pass only the transformer's declared file list.
        let transformerFiles = transformerDesc.files.map(\.relativePath)
        try await AcervoDownloader.downloadFiles(
          modelId: repoId,
          requestedFiles: transformerFiles,
          destination: destination,
          force: false,
          progress: nil,
          session: MockURLProtocol.session()
        )

        // Transformer files MUST be on disk.
        #expect(
          Self.fileExists("transformer/model.safetensors", repoId: repoId, in: tempDir),
          "R1: transformer/model.safetensors must be downloaded"
        )

        // text_encoder and vae files must NOT be on disk.
        #expect(
          !Self.fileExists("text_encoder/config.json", repoId: repoId, in: tempDir),
          "R1: text_encoder/config.json must NOT be downloaded for bundle-transformer"
        )
        #expect(
          !Self.fileExists("text_encoder/model.safetensors", repoId: repoId, in: tempDir),
          "R1: text_encoder/model.safetensors must NOT be downloaded for bundle-transformer"
        )
        #expect(
          !Self.fileExists("vae/config.json", repoId: repoId, in: tempDir),
          "R1: vae/config.json must NOT be downloaded for bundle-transformer"
        )
        #expect(
          !Self.fileExists("vae/diffusion_pytorch_model.safetensors", repoId: repoId, in: tempDir),
          "R1: vae/diffusion_pytorch_model.safetensors must NOT be downloaded for bundle-transformer"
        )
      }
    }

    /// R1 test 2: After also simulating ensureComponentReady("bundle-text-encoder"),
    /// assert transformer + text_encoder files are on disk and vae files are NOT.
    ///
    /// Verifies that downloading a second bundle component adds exactly its declared
    /// files without touching the already-present transformer files or adding vae files.
    @Test(
      "R1: ensureComponentReady for text-encoder adds text-encoder files, leaves vae untouched"
    )
    func testEnsureComponentReady_R1_TextEncoderAddsItsFilesLeaveVaeUntouched() async throws {
      try await withIsolatedAcervoState {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        let (manifest, fileBodies) = BundleFixtures.fluxStyleManifest()
        MockURLProtocol.responder = BundleFixtures.makeResponder(
          manifest: manifest,
          fileBodies: fileBodies
        )

        let repoId = manifest.modelId
        let slug = Acervo.slugify(repoId)
        let (transformerDesc, textEncoderDesc, vaeDesc) = BundleFixtures.bundleDescriptors(
          repoId: repoId)

        Acervo.register(transformerDesc)
        Acervo.register(textEncoderDesc)
        Acervo.register(vaeDesc)

        let tempDir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let destination = tempDir.appendingPathComponent(slug)
        try AcervoDownloader.ensureDirectory(at: destination)

        let mockSession = MockURLProtocol.session()

        // Step 1: Download transformer component only.
        try await AcervoDownloader.downloadFiles(
          modelId: repoId,
          requestedFiles: transformerDesc.files.map(\.relativePath),
          destination: destination,
          force: false,
          progress: nil,
          session: mockSession
        )

        // Step 2: Download text_encoder component.
        try await AcervoDownloader.downloadFiles(
          modelId: repoId,
          requestedFiles: textEncoderDesc.files.map(\.relativePath),
          destination: destination,
          force: false,
          progress: nil,
          session: mockSession
        )

        // Transformer files MUST still be on disk.
        #expect(
          Self.fileExists("transformer/model.safetensors", repoId: repoId, in: tempDir),
          "R1: transformer/model.safetensors must remain after text-encoder download"
        )

        // text_encoder files MUST be on disk.
        #expect(
          Self.fileExists("text_encoder/config.json", repoId: repoId, in: tempDir),
          "R1: text_encoder/config.json must be downloaded"
        )
        #expect(
          Self.fileExists("text_encoder/model.safetensors", repoId: repoId, in: tempDir),
          "R1: text_encoder/model.safetensors must be downloaded"
        )

        // vae files must NOT be on disk — downloading text_encoder must not pull vae.
        #expect(
          !Self.fileExists("vae/config.json", repoId: repoId, in: tempDir),
          "R1: vae/config.json must NOT be downloaded when only text-encoder is ensured"
        )
        #expect(
          !Self.fileExists(
            "vae/diffusion_pytorch_model.safetensors", repoId: repoId, in: tempDir),
          "R1: vae/diffusion_pytorch_model.safetensors must NOT be downloaded for text-encoder"
        )
      }
    }

    // MARK: - R3: isComponentReady checks declared files only

    /// R3 test 1: With only transformer files on disk, isComponentReady("bundle-transformer")
    /// is true and isComponentReady("bundle-vae") is false. After all components are ensured,
    /// all three return true.
    ///
    /// Verifies that isComponentReady does not scan the whole slug directory — it checks only
    /// the descriptor's declared files, regardless of what sibling files exist.
    @Test(
      "R3: isComponentReady checks declared files only — sibling files do not affect result"
    )
    func testIsComponentReady_R3_SiblingFilesDoNotAffectReadiness() throws {
      try withIsolatedAcervoStateSync {
        let (manifest, fileBodies) = BundleFixtures.fluxStyleManifest()
        let repoId = manifest.modelId
        let (transformerDesc, textEncoderDesc, vaeDesc) = BundleFixtures.bundleDescriptors(
          repoId: repoId)

        Acervo.register(transformerDesc)
        Acervo.register(textEncoderDesc)
        Acervo.register(vaeDesc)

        let tempDir = try FileManager.default.url(
          for: .itemReplacementDirectory,
          in: .userDomainMask,
          appropriateFor: FileManager.default.temporaryDirectory,
          create: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Phase 1: Only transformer files exist on disk.
        try Self.createFilesOnDisk(
          paths: transformerDesc.files.map(\.relativePath),
          repoId: repoId,
          in: tempDir,
          fileBodies: fileBodies
        )

        // bundle-transformer should be ready (all its files are on disk).
        #expect(
          Acervo.isComponentReady("bundle-transformer", in: tempDir) == true,
          "R3: bundle-transformer must be ready when its files exist on disk"
        )

        // bundle-vae should NOT be ready (its files are absent).
        #expect(
          Acervo.isComponentReady("bundle-vae", in: tempDir) == false,
          "R3: bundle-vae must NOT be ready when its files are absent"
        )

        // bundle-text-encoder should NOT be ready (its files are absent).
        #expect(
          Acervo.isComponentReady("bundle-text-encoder", in: tempDir) == false,
          "R3: bundle-text-encoder must NOT be ready when its files are absent"
        )

        // Phase 2: Add text_encoder files.
        try Self.createFilesOnDisk(
          paths: textEncoderDesc.files.map(\.relativePath),
          repoId: repoId,
          in: tempDir,
          fileBodies: fileBodies
        )

        // Phase 3: Add vae files.
        try Self.createFilesOnDisk(
          paths: vaeDesc.files.map(\.relativePath),
          repoId: repoId,
          in: tempDir,
          fileBodies: fileBodies
        )

        // All three should be ready.
        #expect(
          Acervo.isComponentReady("bundle-transformer", in: tempDir) == true,
          "R3: bundle-transformer must be ready after all components ensured"
        )
        #expect(
          Acervo.isComponentReady("bundle-text-encoder", in: tempDir) == true,
          "R3: bundle-text-encoder must be ready after all components ensured"
        )
        #expect(
          Acervo.isComponentReady("bundle-vae", in: tempDir) == true,
          "R3: bundle-vae must be ready after all components ensured"
        )
      }
    }

    /// R3 test 2: Delete one declared file from the transformer component; assert
    /// isComponentReady("bundle-transformer") flips to false.
    ///
    /// Verifies that readiness is per-file: removing any one declared file makes
    /// the component not-ready, regardless of what other files exist in the directory.
    @Test(
      "R3: deleting one declared file flips isComponentReady to false for that component only"
    )
    func testIsComponentReady_R3_DeletedDeclaredFileFlipsReadinessToFalse() throws {
      try withIsolatedAcervoStateSync {
        let (manifest, fileBodies) = BundleFixtures.fluxStyleManifest()
        let repoId = manifest.modelId
        let (transformerDesc, textEncoderDesc, vaeDesc) = BundleFixtures.bundleDescriptors(
          repoId: repoId)

        Acervo.register(transformerDesc)
        Acervo.register(textEncoderDesc)
        Acervo.register(vaeDesc)

        let tempDir = try FileManager.default.url(
          for: .itemReplacementDirectory,
          in: .userDomainMask,
          appropriateFor: FileManager.default.temporaryDirectory,
          create: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Populate all files for all three components.
        let allPaths =
          transformerDesc.files.map(\.relativePath)
          + textEncoderDesc.files.map(\.relativePath)
          + vaeDesc.files.map(\.relativePath)
        try Self.createFilesOnDisk(
          paths: allPaths,
          repoId: repoId,
          in: tempDir,
          fileBodies: fileBodies
        )

        // All three ready.
        #expect(Acervo.isComponentReady("bundle-transformer", in: tempDir) == true)
        #expect(Acervo.isComponentReady("bundle-text-encoder", in: tempDir) == true)
        #expect(Acervo.isComponentReady("bundle-vae", in: tempDir) == true)

        // Delete one declared file from the transformer component.
        // transformerDesc.files contains exactly one entry: "transformer/model.safetensors".
        let deletedRelativePath = transformerDesc.files[0].relativePath
        let slug = Acervo.slugify(repoId)
        let deletedURL =
          tempDir.appendingPathComponent(slug).appendingPathComponent(deletedRelativePath)

        try FileManager.default.removeItem(at: deletedURL)

        // bundle-transformer MUST flip to not-ready.
        #expect(
          Acervo.isComponentReady("bundle-transformer", in: tempDir) == false,
          "R3: removing a declared file must flip isComponentReady to false"
        )

        // Sibling components MUST remain ready — their files are untouched.
        #expect(
          Acervo.isComponentReady("bundle-text-encoder", in: tempDir) == true,
          "R3: deleting transformer file must not affect bundle-text-encoder readiness"
        )
        #expect(
          Acervo.isComponentReady("bundle-vae", in: tempDir) == true,
          "R3: deleting transformer file must not affect bundle-vae readiness"
        )
      }
    }

    // MARK: - R2: withComponentAccess exposes declared files with subfolder layout

    /// R2 test 1: Call withComponentAccess for "bundle-transformer" and assert the handle's
    /// availableFiles() returns ONLY the transformer's declared file, not text_encoder or vae
    /// files. Also assert url(matching:) throws when the suffix only matches a sibling
    /// component's file (not declared in the transformer descriptor).
    ///
    /// This pins the audit finding (R2 HONORED): ComponentHandle iterates descriptor.files
    /// exclusively; sibling files on disk are invisible to the handle's access API.
    @Test("R2: withComponentAccess handle exposes only declared transformer files")
    func testWithComponentAccess_R2_HandleExposesOnlyDeclaredFiles() async throws {
      try await withIsolatedAcervoState {
        let (manifest, fileBodies) = BundleFixtures.fluxStyleManifest()
        let repoId = manifest.modelId
        let (transformerDesc, textEncoderDesc, vaeDesc) = BundleFixtures.bundleDescriptors(
          repoId: repoId)

        Acervo.register(transformerDesc)
        Acervo.register(textEncoderDesc)
        Acervo.register(vaeDesc)

        let tempDir = try FileManager.default.url(
          for: .itemReplacementDirectory,
          in: .userDomainMask,
          appropriateFor: FileManager.default.temporaryDirectory,
          create: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Put ALL files on disk (all 3 components' files exist in the shared slug directory).
        let allPaths =
          transformerDesc.files.map(\.relativePath)
          + textEncoderDesc.files.map(\.relativePath)
          + vaeDesc.files.map(\.relativePath)
        try Self.createFilesOnDisk(
          paths: allPaths,
          repoId: repoId,
          in: tempDir,
          fileBodies: fileBodies
        )

        let manager = AcervoManager.shared

        // withComponentAccess for bundle-transformer only — even though sibling files exist.
        try await manager.withComponentAccess("bundle-transformer", in: tempDir) { handle in
          // availableFiles() must return ONLY the transformer's declared files.
          let available = handle.availableFiles()
          #expect(
            available == ["transformer/model.safetensors"],
            "R2: availableFiles() must return only transformer's declared files, got: \(available)"
          )

          // url(matching:) for a suffix that only exists in the text_encoder descriptor
          // must throw — the transformer handle cannot see sibling-declared files.
          #expect(
            throws: (any Error).self,
            "R2: url(matching:) for a text_encoder-only suffix must throw for transformer handle"
          ) {
            try handle.url(matching: "text_encoder/config.json")
          }

          // url(matching:) for a suffix that only exists in the vae descriptor must throw.
          #expect(
            throws: (any Error).self,
            "R2: url(matching:) for a vae-only suffix must throw for transformer handle"
          ) {
            try handle.url(matching: "diffusion_pytorch_model.safetensors")
          }

          // url(matching:) for the transformer's own file must succeed.
          let transformerURL = try handle.url(matching: "model.safetensors")
          #expect(
            transformerURL.path.hasSuffix("transformer/model.safetensors"),
            "R2: url(matching:) must resolve to the transformer's model.safetensors"
          )
        }
      }
    }

    /// R2 test 2: After creating files on disk, call withComponentAccess for
    /// "bundle-text-encoder" and assert that url(for: "text_encoder/config.json")
    /// returns a URL whose trailing path components preserve the subfolder structure.
    /// Assert the file actually exists on disk at that URL.
    ///
    /// This pins the audit finding that url(for:) appends the relative path component-
    /// by-component (no flattening), so "text_encoder/config.json" is preserved as
    /// a subdirectory entry, not flattened to "config.json".
    @Test("R2: subfolder structure is preserved — text_encoder/config.json stays in subfolder")
    func testWithComponentAccess_R2_SubfolderStructurePreservedOnDisk() async throws {
      try await withIsolatedAcervoState {
        let (manifest, fileBodies) = BundleFixtures.fluxStyleManifest()
        let repoId = manifest.modelId
        let (transformerDesc, textEncoderDesc, _) = BundleFixtures.bundleDescriptors(
          repoId: repoId)

        Acervo.register(transformerDesc)
        Acervo.register(textEncoderDesc)

        let tempDir = try FileManager.default.url(
          for: .itemReplacementDirectory,
          in: .userDomainMask,
          appropriateFor: FileManager.default.temporaryDirectory,
          create: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create text_encoder files on disk.
        let textEncoderPaths = textEncoderDesc.files.map(\.relativePath)
        try Self.createFilesOnDisk(
          paths: textEncoderPaths,
          repoId: repoId,
          in: tempDir,
          fileBodies: fileBodies
        )

        let manager = AcervoManager.shared

        try await manager.withComponentAccess("bundle-text-encoder", in: tempDir) { handle in
          // url(for:) must return a URL whose path ends with "text_encoder/config.json" —
          // the subfolder component is preserved, not stripped.
          let configURL = try handle.url(for: "text_encoder/config.json")
          #expect(
            configURL.path.hasSuffix("text_encoder/config.json"),
            "R2: url(for: 'text_encoder/config.json') must preserve subfolder path, got: \(configURL.path)"
          )

          // The file must actually exist on disk at the returned URL.
          #expect(
            FileManager.default.fileExists(atPath: configURL.path),
            "R2: file at text_encoder/config.json must exist on disk at the returned URL"
          )

          // Verify the parent directory is "text_encoder", not the slug root.
          let parentDir = configURL.deletingLastPathComponent().lastPathComponent
          #expect(
            parentDir == "text_encoder",
            "R2: parent directory of config.json must be 'text_encoder', got: \(parentDir)"
          )

          // url(for:) for the safetensors file must also preserve its subfolder.
          let weightsURL = try handle.url(for: "text_encoder/model.safetensors")
          #expect(
            weightsURL.path.hasSuffix("text_encoder/model.safetensors"),
            "R2: url(for: 'text_encoder/model.safetensors') must preserve subfolder path"
          )
          #expect(
            FileManager.default.fileExists(atPath: weightsURL.path),
            "R2: text_encoder/model.safetensors must exist on disk at the returned URL"
          )
        }
      }
    }

    // MARK: - R5: fetchManifest(forComponent:) returns full manifest

    /// R5 test: Call fetchManifest(forComponent: "bundle-transformer") and assert the
    /// returned manifest contains ALL files in the bundle (not just the transformer
    /// subset). Also assert the manifest matches what fetchManifest(for: repoId) returns —
    /// both return the full CDN manifest, unfiltered by component scope.
    ///
    /// This pins the audit finding (R5 HONORED): fetchManifest(forComponent:) delegates
    /// to fetchManifest(for: descriptor.repoId) with no file filtering.
    @Test("R5: fetchManifest(forComponent:) returns the full CDN manifest for any bundle component")
    func testFetchManifest_R5_ComponentManifestMatchesFullManifest() async throws {
      try await withIsolatedAcervoState {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        let (manifest, fileBodies) = BundleFixtures.fluxStyleManifest()
        MockURLProtocol.responder = BundleFixtures.makeResponder(
          manifest: manifest,
          fileBodies: fileBodies
        )

        let repoId = manifest.modelId
        let (transformerDesc, textEncoderDesc, vaeDesc) = BundleFixtures.bundleDescriptors(
          repoId: repoId)

        Acervo.register(transformerDesc)
        Acervo.register(textEncoderDesc)
        Acervo.register(vaeDesc)

        let mockSession = MockURLProtocol.session()

        // Fetch manifest via component ID (R5 path).
        let componentManifest = try await Acervo.fetchManifest(
          forComponent: "bundle-transformer",
          session: mockSession
        )

        // Fetch manifest directly via repo ID (the "full manifest" baseline).
        let directManifest = try await Acervo.fetchManifest(
          for: repoId,
          session: mockSession
        )

        // Both manifests must contain ALL 5 files from the bundle fixture,
        // not just the transformer's 1 file.
        let expectedPaths = BundleFixtures.fileContents.keys.sorted()
        let componentPaths = componentManifest.files.map(\.path).sorted()
        let directPaths = directManifest.files.map(\.path).sorted()

        #expect(
          componentPaths == expectedPaths,
          "R5: fetchManifest(forComponent:) must return ALL bundle files, got: \(componentPaths)"
        )
        #expect(
          directPaths == expectedPaths,
          "R5: fetchManifest(for:) baseline must return ALL bundle files, got: \(directPaths)"
        )

        // Both manifests must agree on file paths (equality of the filtered-and-sorted path list).
        #expect(
          componentPaths == directPaths,
          "R5: fetchManifest(forComponent:) and fetchManifest(for:) must return identical file lists"
        )

        // Both manifests must agree on modelId and manifestChecksum.
        #expect(
          componentManifest.modelId == directManifest.modelId,
          "R5: both manifests must have the same modelId"
        )
        #expect(
          componentManifest.manifestChecksum == directManifest.manifestChecksum,
          "R5: both manifests must have the same manifestChecksum"
        )

        // The component manifest must include sibling-only files —
        // transformer-only: transformer/model.safetensors (1 file)
        // the other 4 files belong to text_encoder and vae components.
        let transformerFilePaths = transformerDesc.files.map(\.relativePath)
        let siblingOnlyPaths = componentPaths.filter { !transformerFilePaths.contains($0) }
        #expect(
          siblingOnlyPaths.count == 4,
          "R5: manifest must include 4 sibling-component files (text_encoder + vae), got: \(siblingOnlyPaths)"
        )
      }
    }

    // MARK: - R4: deleteComponent removes declared files only (sibling-safe)
    //
    // NOTE: All three R4 tests are EXPECTED TO FAIL against the current source.
    // Acervo.swift:1842 removes the entire slug directory, which destroys sibling
    // component files. These tests pin the INTENDED behavior (declared-files-only
    // delete + sibling-safe). Sortie 5 will fix the source to make them pass.
    //
    // Per Q1 resolution in manifest-as-bundle-audit.md:
    //   "delete declared files only; remove slug dir if empty after all files removed"
    //
    // R4 test 3 will also fail today because the very first deleteComponent call
    // already removes the whole slug dir, leaving nothing for the subsequent tests
    // to inspect (the slug dir is gone before tests 1 and 2 can check for siblings).

    /// R4 test 1: Register 3 bundle components, ensure-ready all three by creating files
    /// on disk, then deleteComponent("bundle-transformer"). Assert transformer files are
    /// gone AND text_encoder + vae files remain untouched.
    ///
    /// Expected to FAIL against current source (whole slug dir is removed).
    /// Sortie 5 must fix deleteComponent to iterate descriptor.files only.
    @Test("R4: deleteComponent removes only transformer files, preserves sibling files")
    func testDeleteComponent_R4_RemovesDeclaredFilesAndPreservesSiblings() throws {
      try withIsolatedAcervoStateSync {
        let (manifest, fileBodies) = BundleFixtures.fluxStyleManifest()
        let repoId = manifest.modelId
        let (transformerDesc, textEncoderDesc, vaeDesc) = BundleFixtures.bundleDescriptors(
          repoId: repoId)

        Acervo.register(transformerDesc)
        Acervo.register(textEncoderDesc)
        Acervo.register(vaeDesc)

        let tempDir = try FileManager.default.url(
          for: .itemReplacementDirectory,
          in: .userDomainMask,
          appropriateFor: FileManager.default.temporaryDirectory,
          create: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Populate all 5 files on disk (all 3 components ready).
        let allPaths =
          transformerDesc.files.map(\.relativePath)
          + textEncoderDesc.files.map(\.relativePath)
          + vaeDesc.files.map(\.relativePath)
        try Self.createFilesOnDisk(
          paths: allPaths,
          repoId: repoId,
          in: tempDir,
          fileBodies: fileBodies
        )

        // Precondition: all three components ready.
        #expect(Acervo.isComponentReady("bundle-transformer", in: tempDir) == true)
        #expect(Acervo.isComponentReady("bundle-text-encoder", in: tempDir) == true)
        #expect(Acervo.isComponentReady("bundle-vae", in: tempDir) == true)

        // Delete only the transformer component.
        try Acervo.deleteComponent("bundle-transformer", in: tempDir)

        // INTENDED BEHAVIOR (R4): transformer files must be gone.
        #expect(
          !Self.fileExists("transformer/model.safetensors", repoId: repoId, in: tempDir),
          "R4: transformer/model.safetensors must be removed by deleteComponent"
        )

        // INTENDED BEHAVIOR (R4): sibling files must survive.
        // These assertions will FAIL against current source (slug dir is removed wholesale).
        #expect(
          Self.fileExists("text_encoder/config.json", repoId: repoId, in: tempDir),
          "R4: text_encoder/config.json must survive deleteComponent('bundle-transformer')"
        )
        #expect(
          Self.fileExists("text_encoder/model.safetensors", repoId: repoId, in: tempDir),
          "R4: text_encoder/model.safetensors must survive deleteComponent('bundle-transformer')"
        )
        #expect(
          Self.fileExists("vae/config.json", repoId: repoId, in: tempDir),
          "R4: vae/config.json must survive deleteComponent('bundle-transformer')"
        )
        #expect(
          Self.fileExists(
            "vae/diffusion_pytorch_model.safetensors", repoId: repoId, in: tempDir),
          "R4: vae/diffusion_pytorch_model.safetensors must survive deleteComponent('bundle-transformer')"
        )
      }
    }

    /// R4 test 2: After deleting only the transformer component, assert
    /// isComponentReady returns true for the surviving sibling components.
    ///
    /// Expected to FAIL against current source (slug dir is removed wholesale,
    /// so text_encoder and vae files are gone and isComponentReady returns false).
    @Test("R4: sibling components remain ready after partial deleteComponent")
    func testDeleteComponent_R4_SiblingComponentsRemainReadyAfterPartialDelete() throws {
      try withIsolatedAcervoStateSync {
        let (manifest, fileBodies) = BundleFixtures.fluxStyleManifest()
        let repoId = manifest.modelId
        let (transformerDesc, textEncoderDesc, vaeDesc) = BundleFixtures.bundleDescriptors(
          repoId: repoId)

        Acervo.register(transformerDesc)
        Acervo.register(textEncoderDesc)
        Acervo.register(vaeDesc)

        let tempDir = try FileManager.default.url(
          for: .itemReplacementDirectory,
          in: .userDomainMask,
          appropriateFor: FileManager.default.temporaryDirectory,
          create: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Populate all files for all three components.
        let allPaths =
          transformerDesc.files.map(\.relativePath)
          + textEncoderDesc.files.map(\.relativePath)
          + vaeDesc.files.map(\.relativePath)
        try Self.createFilesOnDisk(
          paths: allPaths,
          repoId: repoId,
          in: tempDir,
          fileBodies: fileBodies
        )

        // Delete the transformer component only.
        try Acervo.deleteComponent("bundle-transformer", in: tempDir)

        // INTENDED BEHAVIOR (R4): transformer is no longer ready.
        #expect(
          Acervo.isComponentReady("bundle-transformer", in: tempDir) == false,
          "R4: bundle-transformer must not be ready after deleteComponent"
        )

        // INTENDED BEHAVIOR (R4): siblings must still be ready.
        // These will FAIL against current source (their files are gone).
        #expect(
          Acervo.isComponentReady("bundle-text-encoder", in: tempDir) == true,
          "R4: bundle-text-encoder must remain ready after deleting bundle-transformer"
        )
        #expect(
          Acervo.isComponentReady("bundle-vae", in: tempDir) == true,
          "R4: bundle-vae must remain ready after deleting bundle-transformer"
        )
      }
    }

    /// R4 test 3: After deleting all three components (one at a time), assert the
    /// slug directory is empty or removed.
    ///
    /// Per Q1 resolution: intended behavior is "delete declared files; remove slug dir
    /// if empty." Once all 3 components are deleted, the slug dir should be gone.
    ///
    /// Expected to FAIL against current source (deleteComponent("bundle-transformer")
    /// already removes the entire slug dir; the subsequent deleteComponent calls for
    /// "bundle-text-encoder" and "bundle-vae" will throw componentNotRegistered or
    /// simply no-op because the dir is already absent).
    @Test("R4: slug directory removed after all bundle components are deleted")
    func testDeleteComponent_R4_SlugDirRemovedAfterAllComponentsDeleted() throws {
      try withIsolatedAcervoStateSync {
        let (manifest, fileBodies) = BundleFixtures.fluxStyleManifest()
        let repoId = manifest.modelId
        let (transformerDesc, textEncoderDesc, vaeDesc) = BundleFixtures.bundleDescriptors(
          repoId: repoId)

        Acervo.register(transformerDesc)
        Acervo.register(textEncoderDesc)
        Acervo.register(vaeDesc)

        let tempDir = try FileManager.default.url(
          for: .itemReplacementDirectory,
          in: .userDomainMask,
          appropriateFor: FileManager.default.temporaryDirectory,
          create: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Populate all files for all three components.
        let allPaths =
          transformerDesc.files.map(\.relativePath)
          + textEncoderDesc.files.map(\.relativePath)
          + vaeDesc.files.map(\.relativePath)
        try Self.createFilesOnDisk(
          paths: allPaths,
          repoId: repoId,
          in: tempDir,
          fileBodies: fileBodies
        )

        // Delete all three components. Per Q1 resolution, each call removes
        // only its declared files; the slug dir is removed only when empty.
        //
        // With current (broken) source: the first call removes the whole slug dir;
        // the subsequent calls may throw or no-op, but do not restore files.
        // With intended (fixed) source: all 5 files are removed across the 3 calls,
        // and the slug dir is pruned when empty after the last call.
        try Acervo.deleteComponent("bundle-transformer", in: tempDir)
        // The second and third deletes should succeed even if the slug dir was not
        // yet removed (their declared files are still present in the fixed impl).
        // In the broken impl, these are no-ops (dir already gone).
        try? Acervo.deleteComponent("bundle-text-encoder", in: tempDir)
        try? Acervo.deleteComponent("bundle-vae", in: tempDir)

        // INTENDED BEHAVIOR (R4 + Q1): after all components are deleted, the slug
        // directory must be absent (either removed by the last deleteComponent or
        // found empty and then removed).
        let slug = Acervo.slugify(repoId)
        let slugDir = tempDir.appendingPathComponent(slug)
        let slugExists = FileManager.default.fileExists(atPath: slugDir.path)
        if slugExists {
          // If the slug dir still exists, it must be empty (all declared files removed).
          let contents = (try? FileManager.default.contentsOfDirectory(atPath: slugDir.path)) ?? []
          #expect(
            contents.isEmpty,
            "R4: slug directory must be empty after deleting all bundle components, contents: \(contents)"
          )
        }
        // Primary assertion: slug dir is gone or empty.
        // This passes trivially with current source (whole dir removed on first delete)
        // but the sibling tests above will have already failed, making this moot.
        #expect(
          !slugExists
            || {
              let contents =
                (try? FileManager.default.contentsOfDirectory(atPath: slugDir.path)) ?? []
              return contents.isEmpty
            }(),
          "R4: slug directory must not exist (or be empty) after deleting all bundle components"
        )
      }
    }

    // MARK: - R6: Re-register canary distinguishes sibling registration from id-collision
    //
    // The canary is a stderr write in ComponentRegistry.register(_:) at:
    //   ComponentRegistry.swift:66-70
    //   "[SwiftAcervo] Warning: re-registering component '<id>' with different repoId or files..."
    //
    // Observation mechanism: dup2 + Pipe (same as HydrationTests.swift:209-244).
    //
    // R6 (negative): distinct IDs sharing a repoId do NOT fire the canary.
    // R6 (positive): same ID re-registered with different files DOES fire the canary.
    // R6 (idempotent): same ID re-registered with identical descriptor does NOT fire the canary.

    /// R6 test (negative — should not fire): Register 3 distinct component IDs
    /// against the same repoId. Assert NO re-register warning text appears in stderr.
    ///
    /// This pins the audit finding: distinct IDs go to the else branch in
    /// ComponentRegistry.register(_:) at line 95 — no warning, no canary.
    @Test("R6: distinct component IDs sharing repoId do not trigger re-register canary")
    func testReregisterCanary_R6_DoesNotFireForSiblingComponents() throws {
      try withIsolatedComponentRegistrySync {
        let repoId = "test-bundle-org/flux-style-bundle"
        let (transformerDesc, textEncoderDesc, vaeDesc) = BundleFixtures.bundleDescriptors(
          repoId: repoId)

        // Capture stderr while registering 3 distinct IDs against the same repoId.
        let captured = try BundleStderrCapture.capturing {
          Acervo.register(transformerDesc)
          Acervo.register(textEncoderDesc)
          Acervo.register(vaeDesc)
        }

        // No re-register warning must appear — sibling registration is always silent.
        #expect(
          !captured.contains("[SwiftAcervo] Warning: re-registering component"),
          "R6: registering distinct IDs against the same repoId must NOT trigger canary. Captured stderr: \(captured)"
        )
      }
    }

    /// R6 test (positive — should fire): Register id = "bundle-transformer" with one file
    /// list, then re-register the same id with a different file list. Assert the re-register
    /// canary fires (the !sameFiles branch in ComponentRegistry.swift:66).
    @Test("R6: re-registering same id with different files fires re-register canary")
    func testReregisterCanary_R6_FiresOnSameIdDifferentFiles() throws {
      try withIsolatedComponentRegistrySync {
        let repoId = "test-bundle-org/flux-style-bundle"

        let originalDesc = ComponentDescriptor(
          id: "bundle-transformer",
          type: .backbone,
          displayName: "Bundle Transformer",
          repoId: repoId,
          files: [ComponentFile(relativePath: "transformer/model.safetensors")],
          estimatedSizeBytes: 100,
          minimumMemoryBytes: 0
        )

        // Register original descriptor — no warning expected.
        Acervo.register(originalDesc)

        // Now re-register the same ID with a DIFFERENT file list.
        let conflictDesc = ComponentDescriptor(
          id: "bundle-transformer",
          type: .backbone,
          displayName: "Bundle Transformer",
          repoId: repoId,
          files: [
            ComponentFile(relativePath: "transformer/model.safetensors"),
            ComponentFile(relativePath: "transformer/config.json"),  // extra file → triggers canary
          ],
          estimatedSizeBytes: 100,
          minimumMemoryBytes: 0
        )

        // Capture stderr only during the conflicting re-registration.
        let captured = try BundleStderrCapture.capturing {
          Acervo.register(conflictDesc)
        }

        // The canary MUST fire (same id, different files).
        #expect(
          captured.contains("[SwiftAcervo] Warning: re-registering component"),
          "R6: re-registering same id with different files must emit canary. Captured stderr: \(captured)"
        )
        #expect(
          captured.contains("bundle-transformer"),
          "R6: canary message must name the conflicting component id. Captured stderr: \(captured)"
        )
      }
    }

    /// R6 test (idempotent — should not fire): Register id = "bundle-transformer" twice
    /// with the SAME descriptor (equivalent file list, type, displayName, etc.). Assert
    /// canary does NOT fire — this is the manifest-destiny-01 idempotent short-circuit
    /// at ComponentRegistry.swift:52-62.
    @Test("R6: idempotent re-registration of identical descriptor does not fire canary")
    func testReregisterCanary_R6_DoesNotFireForIdenticalDescriptor() throws {
      try withIsolatedComponentRegistrySync {
        let repoId = "test-bundle-org/flux-style-bundle"

        let desc = ComponentDescriptor(
          id: "bundle-transformer",
          type: .backbone,
          displayName: "Bundle Transformer",
          repoId: repoId,
          files: [ComponentFile(relativePath: "transformer/model.safetensors")],
          estimatedSizeBytes: 100,
          minimumMemoryBytes: 0
        )

        // First registration — no canary (new key, else branch at line 95).
        Acervo.register(desc)

        // Capture stderr during the SECOND registration of an identical descriptor.
        let captured = try BundleStderrCapture.capturing {
          Acervo.register(desc)  // exactly the same descriptor object
        }

        // No canary must fire — idempotent short-circuit returns early.
        #expect(
          !captured.contains("[SwiftAcervo] Warning: re-registering component"),
          "R6: idempotent re-registration must NOT emit canary. Captured stderr: \(captured)"
        )
      }
    }
  }
}

// MARK: - BundleStderrCapture

/// Thread-safe stderr capture helper for R6 canary tests.
///
/// Uses the same dup2 + Pipe approach as HydrationTests.swift (lines 209-244):
///   1. Save the real stderr fd via dup(STDERR_FILENO).
///   2. Redirect STDERR_FILENO to a Pipe's write end.
///   3. Drain the read end via readabilityHandler into a thread-safe buffer.
///   4. Close the write end to flush, restore the real fd, return collected bytes.
///
/// This is the only reliable way to observe `FileHandle.standardError.write(...)` from
/// tests, because OSLog/Logger calls are not captured by dup2 (they bypass file
/// descriptors entirely). The ComponentRegistry canary uses FileHandle.standardError,
/// so dup2 capture works correctly here.
private enum BundleStderrCapture {

  private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) {
      lock.lock()
      defer { lock.unlock() }
      buffer.append(data)
    }

    func stringValue() -> String {
      lock.lock()
      defer { lock.unlock() }
      return String(data: buffer, encoding: .utf8) ?? ""
    }
  }

  /// Redirects stderr to a pipe, executes `body`, flushes, restores, and returns
  /// everything written to stderr during `body` as a `String`.
  static func capturing(_ body: () throws -> Void) throws -> String {
    let savedStderr = dup(STDERR_FILENO)
    guard savedStderr >= 0 else {
      throw BundleStderrCaptureError.dupFailed
    }
    let pipe = Pipe()
    dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

    let collector = Collector()
    let readHandle = pipe.fileHandleForReading
    readHandle.readabilityHandler = { handle in
      let chunk = handle.availableData
      if chunk.isEmpty {
        handle.readabilityHandler = nil
      } else {
        collector.append(chunk)
      }
    }

    do {
      try body()
    } catch {
      try? pipe.fileHandleForWriting.close()
      readHandle.readabilityHandler = nil
      dup2(savedStderr, STDERR_FILENO)
      close(savedStderr)
      throw error
    }

    try? pipe.fileHandleForWriting.close()
    // Give the readabilityHandler a moment to drain any remaining bytes.
    Thread.sleep(forTimeInterval: 0.05)
    readHandle.readabilityHandler = nil
    dup2(savedStderr, STDERR_FILENO)
    close(savedStderr)

    return collector.stringValue()
  }
}

private enum BundleStderrCaptureError: Error {
  case dupFailed
}
