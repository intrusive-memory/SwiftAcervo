import Foundation
import Testing

@testable import SwiftAcervo
@testable import acervo

/// Unit tests for `CDNUploader.buildSyncArguments` and
/// `CDNUploader.buildManifestUploadArguments`. The goal is to lock down
/// the exact `aws` argv without ever spawning a real `aws` process.
@Suite("CDNUploader Argument Builder Tests")
struct CDNUploaderTests {

  private static let stagingDir = URL(fileURLWithPath: "/tmp/acervo-staging/org_repo")
  private static let slug = "org_repo"
  private static let bucket = "intrusive-memory"
  private static let endpoint = "https://r2.example.com"

  // MARK: - buildSyncArguments

  @Test("buildSyncArguments contains endpoint, S3 path, and both exclude patterns")
  func syncArgumentsCorePattern() {
    let args = CDNUploader.buildSyncArguments(
      localDirectory: Self.stagingDir,
      slug: Self.slug,
      bucket: Self.bucket,
      endpoint: Self.endpoint,
      dryRun: false,
      force: false
    )

    #expect(args.contains("aws"))
    #expect(args.contains("s3"))
    #expect(args.contains("sync"))
    #expect(args.contains("--endpoint-url"))
    #expect(args.contains(Self.endpoint))
    #expect(args.contains("s3://\(Self.bucket)/models/\(Self.slug)/"))
    #expect(args.contains(Self.stagingDir.path))

    // Both --exclude patterns must be present.
    let excludeCount = args.filter { $0 == "--exclude" }.count
    #expect(excludeCount == 2)
    #expect(args.contains("*.DS_Store"))
    #expect(args.contains(".huggingface/*"))
  }

  @Test("buildSyncArguments omits --dryrun and --exact-timestamps when flags are false")
  func syncArgumentsNoOptionalFlags() {
    let args = CDNUploader.buildSyncArguments(
      localDirectory: Self.stagingDir,
      slug: Self.slug,
      bucket: Self.bucket,
      endpoint: Self.endpoint,
      dryRun: false,
      force: false
    )
    #expect(!args.contains("--dryrun"))
    #expect(!args.contains("--exact-timestamps"))
    // Safety: never pass --delete.
    #expect(!args.contains("--delete"))
  }

  @Test("buildSyncArguments includes --dryrun when dryRun is true")
  func syncArgumentsDryRun() {
    let args = CDNUploader.buildSyncArguments(
      localDirectory: Self.stagingDir,
      slug: Self.slug,
      bucket: Self.bucket,
      endpoint: Self.endpoint,
      dryRun: true,
      force: false
    )
    #expect(args.contains("--dryrun"))
    #expect(!args.contains("--exact-timestamps"))
  }

  @Test("buildSyncArguments includes --exact-timestamps when force is true")
  func syncArgumentsForce() {
    let args = CDNUploader.buildSyncArguments(
      localDirectory: Self.stagingDir,
      slug: Self.slug,
      bucket: Self.bucket,
      endpoint: Self.endpoint,
      dryRun: false,
      force: true
    )
    #expect(args.contains("--exact-timestamps"))
    #expect(!args.contains("--dryrun"))
    #expect(!args.contains("--delete"))
  }

  @Test("buildSyncArguments includes both flags when dryRun and force are true")
  func syncArgumentsDryRunAndForce() {
    let args = CDNUploader.buildSyncArguments(
      localDirectory: Self.stagingDir,
      slug: Self.slug,
      bucket: Self.bucket,
      endpoint: Self.endpoint,
      dryRun: true,
      force: true
    )
    #expect(args.contains("--dryrun"))
    #expect(args.contains("--exact-timestamps"))
  }

  // MARK: - buildManifestUploadArguments

  @Test("buildManifestUploadArguments uploads manifest.json via s3 cp")
  func manifestUploadArguments() {
    let manifestURL = Self.stagingDir.appendingPathComponent("manifest.json")
    let args = CDNUploader.buildManifestUploadArguments(
      localManifestURL: manifestURL,
      slug: Self.slug,
      bucket: Self.bucket,
      endpoint: Self.endpoint,
      dryRun: false
    )

    #expect(args.contains("aws"))
    #expect(args.contains("s3"))
    #expect(args.contains("cp"))
    #expect(args.contains(manifestURL.path))
    #expect(args.contains("s3://\(Self.bucket)/models/\(Self.slug)/manifest.json"))
    #expect(args.contains("--endpoint-url"))
    #expect(args.contains(Self.endpoint))
    #expect(!args.contains("--dryrun"))
  }

  @Test("buildManifestUploadArguments includes --dryrun when dryRun is true")
  func manifestUploadDryRun() {
    let manifestURL = Self.stagingDir.appendingPathComponent("manifest.json")
    let args = CDNUploader.buildManifestUploadArguments(
      localManifestURL: manifestURL,
      slug: Self.slug,
      bucket: Self.bucket,
      endpoint: Self.endpoint,
      dryRun: true
    )
    #expect(args.contains("--dryrun"))
  }
}
