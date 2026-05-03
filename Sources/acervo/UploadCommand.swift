import ArgumentParser
import Foundation
import SwiftAcervo

/// Uploads a locally-staged model directory to the intrusive-memory CDN
/// and enforces integrity checks 2–6.
///
/// The pipeline runs in this order:
///
/// 1. **CHECK 2+3** — `ManifestGenerator.generate` scans the directory,
///    refuses zero-byte files (CHECK 2), writes `manifest.json`, and
///    immediately re-reads it to verify the checksum (CHECK 3).
/// 2. **CHECK 4** — `CDNUploader.verifyBeforeUpload` re-hashes every file
///    against the freshly generated manifest before any `aws` process is
///    spawned.
/// 3. `CDNUploader.sync` — mirrors the directory to R2 via `aws s3 sync`.
/// 4. `CDNUploader.uploadManifest` — copies `manifest.json` to R2 via
///    `aws s3 cp` once sync completes.
/// 5. **CHECK 5** — `CDNUploader.verifyManifestOnCDN` fetches the manifest
///    from the CDN and validates its checksum.
/// 6. **CHECK 6** — `CDNUploader.spotCheckFileOnCDN` downloads `config.json`
///    from the CDN and compares its SHA-256 to the manifest entry.
struct UploadCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "upload",
    abstract: "Upload a staged model directory to the intrusive-memory CDN.",
    discussion: """
      Runs integrity CHECKs 2–6 against a locally-staged model directory:

        CHECK 2  Refuse manifest generation if any file is zero bytes.
        CHECK 3  Re-read manifest.json after writing and verify its checksum.
        CHECK 4  Re-hash every staged file against the manifest before uploading.
        CHECK 5  Fetch manifest.json from the CDN and validate its checksum.
        CHECK 6  Download config.json from the CDN and verify its SHA-256.

      The <directory> argument must be the path to the staged model files.
      Use `acervo download` first if you need to fetch from HuggingFace,
      or use `acervo ship` to run the full pipeline in one step.

      REQUIRED TOOLS
        aws   AWS CLI v2 (brew install awscli)

      REQUIRED ENVIRONMENT VARIABLES
        R2_ACCESS_KEY_ID       Cloudflare R2 access key
        R2_SECRET_ACCESS_KEY   Cloudflare R2 secret key

      OPTIONAL ENVIRONMENT VARIABLES
        R2_BUCKET     Bucket name (default: intrusive-memory-models)
        R2_ENDPOINT   S3-compatible endpoint URL
        R2_PUBLIC_URL Public CDN base URL used for CHECK 5/6

      EXAMPLES
        acervo upload mlx-community/Qwen2.5-7B-Instruct-4bit /tmp/acervo-staging/mlx-community_Qwen2.5-7B-Instruct-4bit
        acervo upload mlx-community/Qwen2.5-7B-Instruct-4bit /tmp/staging --dry-run
      """
  )

  @Argument(help: "HuggingFace model identifier in 'org/repo' form.")
  var modelId: String

  @Argument(help: "Local directory containing the staged model files.")
  var directory: String

  @Option(
    name: [.short, .customLong("bucket")],
    help: "R2 bucket name. Defaults to $R2_BUCKET environment variable."
  )
  var bucket: String?

  @Option(
    name: [.short, .customLong("prefix")],
    help: "Key prefix for uploaded objects (default: 'models/')."
  )
  var prefix: String = "models/"

  @Option(
    name: .customLong("endpoint"),
    help: "R2 endpoint URL. Defaults to $R2_ENDPOINT environment variable."
  )
  var endpoint: String?

  @Flag(
    name: .customLong("dry-run"),
    help: "Pass --dryrun to aws; no files are transferred."
  )
  var dryRun: Bool = false

  @Flag(
    name: .customLong("force"),
    help:
      "Pass --exact-timestamps to aws s3 sync. Changes comparison semantics so files with newer local timestamps trigger re-upload. This is NOT a force-upload-everything switch; files whose timestamps match the remote are still skipped."
  )
  var force: Bool = false

  @OptionGroup var progressOptions: ProgressOptions

  func run() async throws {
    try ToolCheck.validate()

    let resolvedBucket = try resolveBucket()
    let resolvedEndpoint = try resolveEndpoint()
    let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
    let slug = Self.slug(from: modelId)
    let publicBaseURL = Self.resolvePublicBaseURL()

    // CHECK 2+3: generate manifest, refuse zero-byte files, verify on re-read.
    let generator = ManifestGenerator(modelId: modelId)
    let reporterBox = ManifestProgressReporterBox(quiet: progressOptions.quiet)
    let manifestURL = try await generator.generate(
      directory: directoryURL,
      progress: { completed, total in
        reporterBox.handle(completed: completed, total: total)
      }
    )
    FileHandle.standardOutput.write(
      Data("manifest written to \(manifestURL.path)\n".utf8)
    )

    let manifestData = try Data(contentsOf: manifestURL)
    let manifest = try JSONDecoder().decode(CDNManifest.self, from: manifestData)

    // CHECK 4: re-hash every file against the manifest before any aws process is spawned.
    let uploader = CDNUploader()
    let check4Reporter = ProgressReporter(
      label: "CHECK 4 re-hash: ",
      total: manifest.files.count,
      quiet: progressOptions.quiet
    )
    try await uploader.verifyBeforeUpload(
      directory: directoryURL, manifest: manifest, reporter: check4Reporter
    )
    FileHandle.standardOutput.write(
      Data("CHECK 4 passed: all staged files match the manifest.\n".utf8)
    )

    // Sync files to CDN.
    try await uploader.sync(
      localDirectory: directoryURL,
      slug: slug,
      bucket: resolvedBucket,
      endpoint: resolvedEndpoint,
      dryRun: dryRun,
      force: force,
      quiet: progressOptions.quiet
    )

    // Upload manifest separately after sync completes.
    try await uploader.uploadManifest(
      localURL: manifestURL,
      slug: slug,
      bucket: resolvedBucket,
      endpoint: resolvedEndpoint,
      dryRun: dryRun,
      quiet: progressOptions.quiet
    )
    FileHandle.standardOutput.write(
      Data("manifest.json uploaded to CDN.\n".utf8)
    )

    // CHECK 5: verify manifest is fetchable and checksums on CDN.
    _ = try await uploader.verifyManifestOnCDN(publicBaseURL: publicBaseURL, slug: slug)
    FileHandle.standardOutput.write(
      Data("CHECK 5 passed: CDN manifest verified.\n".utf8)
    )

    // CHECK 6: spot-check config.json on CDN.
    guard
      let configEntry = manifest.files.first(where: { $0.path == "config.json" })
    else {
      FileHandle.standardOutput.write(
        Data("CHECK 6 skipped: config.json not present in manifest.\n".utf8)
      )
      return
    }
    try await uploader.spotCheckFileOnCDN(
      publicBaseURL: publicBaseURL,
      slug: slug,
      filename: "config.json",
      expectedSHA256: configEntry.sha256
    )
    FileHandle.standardOutput.write(
      Data("CHECK 6 passed: config.json spot-check succeeded.\n".utf8)
    )

    FileHandle.standardOutput.write(
      Data("Upload complete for \(modelId).\n".utf8)
    )
  }

  // MARK: - Helpers

  private func resolveBucket() throws -> String {
    if let bucket { return bucket }
    if let env = ProcessInfo.processInfo.environment["R2_BUCKET"], !env.isEmpty {
      return env
    }
    throw AcervoToolError.missingEnvironmentVariable("R2_BUCKET")
  }

  private func resolveEndpoint() throws -> String {
    if let endpoint { return endpoint }
    if let env = ProcessInfo.processInfo.environment["R2_ENDPOINT"], !env.isEmpty {
      return env
    }
    throw AcervoToolError.missingEnvironmentVariable("R2_ENDPOINT")
  }

  private static func slug(from modelId: String) -> String {
    modelId.replacingOccurrences(of: "/", with: "_")
  }

  private static func resolvePublicBaseURL() -> URL {
    if let raw = ProcessInfo.processInfo.environment["R2_PUBLIC_URL"],
      let url = URL(string: raw)
    {
      return url
    }
    return URL(string: "https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev")!
  }
}
