import ArgumentParser
import Foundation
import SwiftAcervo

/// Uploads a locally-staged model directory to the intrusive-memory CDN
/// and enforces integrity checks 2–6 plus the manifest-LAST orphan-prune
/// pipeline.
///
/// All CDN-side work is delegated to `Acervo.publishModel(...)`. The CLI
/// is a thin wrapper that resolves credentials, invokes the library, maps
/// progress events to stdout, and surfaces the orphan-prune escape hatch
/// (`--keep-orphans`) and the local-only `--dry-run` short-circuit.
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
        CHECK 6  Download config.json (or the first manifest entry) from the
                 CDN and verify its SHA-256.

      The <directory> argument must be the path to the staged model files.
      Use `acervo download` first if you need to fetch from HuggingFace,
      or use `acervo ship` to run the full pipeline in one step.

      Orphan prune runs by default — CDN keys not referenced by the new
      manifest are deleted after CHECK 6 passes. Pass `--keep-orphans` to
      preserve the previous additive-only behavior.

      REQUIRED ENVIRONMENT VARIABLES
        R2_ACCESS_KEY_ID       Cloudflare R2 access key
        R2_SECRET_ACCESS_KEY   Cloudflare R2 secret key
        R2_ENDPOINT            S3-compatible endpoint URL
        R2_PUBLIC_URL          Public CDN base URL used for CHECK 5/6

      OPTIONAL ENVIRONMENT VARIABLES
        R2_BUCKET     Bucket name (default: intrusive-memory-models)
        R2_REGION     Region (default: auto)

      EXAMPLES
        acervo upload mlx-community/Qwen2.5-7B-Instruct-4bit /tmp/acervo-staging/mlx-community_Qwen2.5-7B-Instruct-4bit
        acervo upload mlx-community/Qwen2.5-7B-Instruct-4bit /tmp/staging --dry-run
        acervo upload mlx-community/Qwen2.5-7B-Instruct-4bit /tmp/staging --keep-orphans
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
    help:
      "Generate and verify the manifest, then print a 'would upload' summary without contacting the CDN."
  )
  var dryRun: Bool = false

  @Flag(
    name: .customLong("force"),
    help:
      "Reserved flag retained for argv compatibility with the pre-v0.14.x shell-out pipeline. The native publish path always uploads exactly the manifest's file set, so this flag is a no-op today."
  )
  var force: Bool = false

  @Flag(
    name: .customLong("no-verify"),
    help:
      "Reserved flag retained for argv compatibility with the legacy upload pipeline. CHECKs 4/5/6 are now always run by Acervo.publishModel; this flag is a no-op today."
  )
  var noVerify: Bool = false

  @Option(
    name: [.short, .customLong("token")],
    help: "Unused for upload. Reserved for argv compatibility."
  )
  var token: String?

  @Option(
    name: [.short, .customLong("source")],
    help: "Unused for upload. Reserved for argv compatibility."
  )
  var source: String?

  @Option(
    name: [.short, .customLong("output")],
    help: "Unused for upload. Reserved for argv compatibility."
  )
  var output: String?

  @Flag(
    name: .customLong("keep-orphans"),
    help:
      "Skip the orphan-prune step. By default, keys on the CDN not referenced by the new manifest are deleted."
  )
  var keepOrphans: Bool = false

  @OptionGroup var progressOptions: ProgressOptions

  func run() async throws {
    try ToolCheck.validate()

    let credentials = try CredentialResolver.resolve(
      bucketOverride: bucket,
      endpointOverride: endpoint
    )

    let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
    let slug = Self.slug(from: modelId)

    // ── DRY-RUN SHORT-CIRCUIT (pre-flight only, no PUTs) ─────────────────
    //
    // `--dry-run` runs manifest generation locally so the operator still
    // gets CHECK 2 / CHECK 3 signal, then prints what would be uploaded
    // without contacting the CDN. Implemented entirely in the CLI so we
    // do not need to add a `dryRun:` parameter to `Acervo.publishModel`
    // (REQUIREMENTS §3.1.3 / framework control F5).

    if dryRun {
      let generator = ManifestGenerator(modelId: modelId)
      let reporterBox = ManifestProgressReporterBox(quiet: progressOptions.quiet)
      let manifestURL = try await generator.generate(
        directory: directoryURL,
        progress: { completed, total in
          reporterBox.handle(completed: completed, total: total)
        }
      )
      let manifestData = try Data(contentsOf: manifestURL)
      let manifest = try JSONDecoder().decode(CDNManifest.self, from: manifestData)
      let totalBytes = manifest.files.reduce(into: Int64(0)) { $0 += $1.sizeBytes }
      FileHandle.standardOutput.write(
        Data(
          "dry-run: would upload \(manifest.files.count) files (\(totalBytes) bytes total) to models/\(slug)/ on \(credentials.bucket).\n"
            .utf8
        )
      )
      return
    }

    // ── UPLOAD PHASE (delegated to Acervo.publishModel) ──────────────────

    let reporter = PublishProgressReporter(
      quiet: progressOptions.quiet,
      style: .ship
    )
    _ = try await PublishRunner.run(
      modelId: modelId,
      directory: directoryURL,
      credentials: credentials,
      keepOrphans: keepOrphans,
      progress: { event in reporter.handle(event) }
    )

    FileHandle.standardOutput.write(
      Data("Upload complete for \(modelId).\n".utf8)
    )
  }

  // MARK: - Helpers

  private static func slug(from modelId: String) -> String {
    modelId.replacingOccurrences(of: "/", with: "_")
  }
}
