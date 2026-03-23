import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

/// Tests for CDNManifest: JSON decoding, checksum verification, and validation.
@Suite("CDN Manifest Tests")
struct CDNManifestTests {

  // MARK: - JSON Decoding

  @Test("Manifest decodes from valid JSON")
  func decodeValidJSON() throws {
    let json = """
      {
          "manifestVersion": 1,
          "modelId": "org/repo",
          "slug": "org_repo",
          "updatedAt": "2026-03-22T00:00:00Z",
          "files": [
              {
                  "path": "config.json",
                  "sha256": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
                  "sizeBytes": 1234
              }
          ],
          "manifestChecksum": "placeholder"
      }
      """
    let data = Data(json.utf8)
    let manifest = try JSONDecoder().decode(CDNManifest.self, from: data)

    #expect(manifest.manifestVersion == 1)
    #expect(manifest.modelId == "org/repo")
    #expect(manifest.slug == "org_repo")
    #expect(manifest.files.count == 1)
    #expect(manifest.files[0].path == "config.json")
    #expect(manifest.files[0].sizeBytes == 1234)
  }

  @Test("Manifest decodes multiple files")
  func decodeMultipleFiles() throws {
    let json = """
      {
          "manifestVersion": 1,
          "modelId": "org/repo",
          "slug": "org_repo",
          "updatedAt": "2026-03-22T00:00:00Z",
          "files": [
              {"path": "config.json", "sha256": "aaaa", "sizeBytes": 100},
              {"path": "model.safetensors", "sha256": "bbbb", "sizeBytes": 5000000000},
              {"path": "speech_tokenizer/config.json", "sha256": "cccc", "sizeBytes": 2048}
          ],
          "manifestChecksum": "placeholder"
      }
      """
    let data = Data(json.utf8)
    let manifest = try JSONDecoder().decode(CDNManifest.self, from: data)

    #expect(manifest.files.count == 3)
    #expect(manifest.files[1].path == "model.safetensors")
    #expect(manifest.files[1].sizeBytes == 5_000_000_000)
    #expect(manifest.files[2].path == "speech_tokenizer/config.json")
  }

  // MARK: - Checksum Verification

  @Test("verifyChecksum returns true for valid checksum")
  func verifyChecksumValid() throws {
    let checksums = ["aaaa", "bbbb", "cccc"]
    let validChecksum = CDNManifest.computeChecksum(from: checksums)

    let json = """
      {
          "manifestVersion": 1,
          "modelId": "org/repo",
          "slug": "org_repo",
          "updatedAt": "2026-03-22T00:00:00Z",
          "files": [
              {"path": "a.json", "sha256": "aaaa", "sizeBytes": 10},
              {"path": "b.json", "sha256": "bbbb", "sizeBytes": 20},
              {"path": "c.json", "sha256": "cccc", "sizeBytes": 30}
          ],
          "manifestChecksum": "\(validChecksum)"
      }
      """
    let manifest = try JSONDecoder().decode(CDNManifest.self, from: Data(json.utf8))
    #expect(manifest.verifyChecksum())
  }

  @Test("verifyChecksum returns false for tampered checksum")
  func verifyChecksumTampered() throws {
    let json = """
      {
          "manifestVersion": 1,
          "modelId": "org/repo",
          "slug": "org_repo",
          "updatedAt": "2026-03-22T00:00:00Z",
          "files": [
              {"path": "a.json", "sha256": "aaaa", "sizeBytes": 10}
          ],
          "manifestChecksum": "0000000000000000000000000000000000000000000000000000000000000000"
      }
      """
    let manifest = try JSONDecoder().decode(CDNManifest.self, from: Data(json.utf8))
    #expect(!manifest.verifyChecksum())
  }

  @Test("computeChecksum is deterministic and order-independent")
  func computeChecksumDeterministic() {
    // Same checksums in different order should produce same result
    let result1 = CDNManifest.computeChecksum(from: ["cccc", "aaaa", "bbbb"])
    let result2 = CDNManifest.computeChecksum(from: ["aaaa", "bbbb", "cccc"])
    let result3 = CDNManifest.computeChecksum(from: ["bbbb", "cccc", "aaaa"])

    #expect(result1 == result2)
    #expect(result2 == result3)
  }

  @Test("computeChecksum returns 64-character lowercase hex string")
  func computeChecksumFormat() {
    let result = CDNManifest.computeChecksum(from: ["abc", "def"])
    #expect(result.count == 64)
    let hexChars = CharacterSet(charactersIn: "0123456789abcdef")
    #expect(result.unicodeScalars.allSatisfy { hexChars.contains($0) })
  }

  @Test("computeChecksum differs for different inputs")
  func computeChecksumDiffers() {
    let result1 = CDNManifest.computeChecksum(from: ["aaaa"])
    let result2 = CDNManifest.computeChecksum(from: ["bbbb"])
    #expect(result1 != result2)
  }

  // MARK: - File Lookup

  @Test("file(at:) returns correct entry")
  func fileLookup() throws {
    let checksums = ["aaaa", "bbbb"]
    let checksum = CDNManifest.computeChecksum(from: checksums)
    let manifest = CDNManifest(
      manifestVersion: 1,
      modelId: "org/repo",
      slug: "org_repo",
      updatedAt: "2026-03-22T00:00:00Z",
      files: [
        CDNManifestFile(path: "config.json", sha256: "aaaa", sizeBytes: 100),
        CDNManifestFile(path: "model.safetensors", sha256: "bbbb", sizeBytes: 5000),
      ],
      manifestChecksum: checksum
    )

    let found = manifest.file(at: "model.safetensors")
    #expect(found?.sha256 == "bbbb")
    #expect(found?.sizeBytes == 5000)

    let notFound = manifest.file(at: "nonexistent.json")
    #expect(notFound == nil)
  }

  // MARK: - Version Validation

  @Test("supportedVersion is 1")
  func supportedVersion() {
    #expect(CDNManifest.supportedVersion == 1)
  }
}
