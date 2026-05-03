import ArgumentParser
import Foundation
import SwiftAcervo

/// Removes a model's bytes from one or more storage tiers.
///
/// Per requirements §6.6, the command operates against three independent
/// scopes: the staging directory used by `download` / `recache`, the
/// shared App Group cache used by consuming apps, and the CDN. Each is
/// addressable by its own flag; `--local` is a convenience that selects
/// both staging and cache. CDN deletes are destructive and prompt for
/// confirmation on a TTY (or require `--yes` when stdin is not a TTY).
struct DeleteCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "delete",
    abstract: "Delete a model from local cache, staging directory, and/or CDN.",
    discussion: """
      At least one of --local / --staging / --cache / --cdn is required.

      SCOPES
        --local      Implies both --staging and --cache.
        --staging    Removes $STAGING_DIR/<slug> (the directory used by
                     `acervo download` / `acervo recache`).
        --cache      Removes the model from the shared App Group cache
                     (~/Library/Group Containers/<group>/SharedModels/<slug>).
                     Equivalent to calling `Acervo.deleteModel(_:)` from a
                     library consumer.
        --cdn        Removes every object under models/<slug>/ from R2.
                     Destructive. Prompts on a TTY; requires --yes off-TTY.

      OPTIONS
        --dry-run    Print the actions that would be taken; perform none.
        --yes        Bypass the TTY confirmation prompt for --cdn.

      REQUIRED FOR --cdn
        R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ENDPOINT, R2_PUBLIC_URL
        R2_BUCKET (optional; defaults to intrusive-memory-models)

      EXAMPLES
        acervo delete mlx-community/Qwen2.5-7B-Instruct-4bit --local
        acervo delete mlx-community/Qwen2.5-7B-Instruct-4bit --staging --dry-run
        acervo delete mlx-community/Qwen2.5-7B-Instruct-4bit --cdn --yes
      """
  )

  @Argument(help: "Model identifier in 'org/repo' form.")
  var modelId: String

  @Flag(name: .customLong("local"), help: "Implies --staging and --cache.")
  var local: Bool = false

  @Flag(name: .customLong("staging"), help: "Delete the staging directory copy.")
  var staging: Bool = false

  @Flag(name: .customLong("cache"), help: "Delete the App Group cache copy.")
  var cache: Bool = false

  @Flag(name: .customLong("cdn"), help: "Delete from the CDN. Destructive.")
  var cdn: Bool = false

  @Flag(name: .customLong("dry-run"), help: "Print intended actions without performing them.")
  var dryRun: Bool = false

  @Flag(name: .customLong("yes"), help: "Bypass TTY confirmation prompts.")
  var yes: Bool = false

  @Option(
    name: [.short, .customLong("bucket")],
    help: "R2 bucket override (otherwise uses $R2_BUCKET)."
  )
  var bucket: String?

  @Option(
    name: .customLong("endpoint"),
    help: "R2 endpoint override (otherwise uses $R2_ENDPOINT)."
  )
  var endpoint: String?

  @OptionGroup var progressOptions: ProgressOptions

  func validate() throws {
    let scopes = [local, staging, cache, cdn]
    guard scopes.contains(true) else {
      throw ValidationError(
        "Specify at least one of --local / --staging / --cache / --cdn."
      )
    }
  }

  func run() async throws {
    // Resolve which scopes are active. --local implies both staging+cache.
    let doStaging = staging || local
    let doCache = cache || local
    let doCDN = cdn

    if doStaging {
      try runStagingDelete()
    }
    if doCache {
      try runCacheDelete()
    }
    if doCDN {
      try await runCDNDelete()
    }
  }

  // MARK: - --staging

  private func runStagingDelete() throws {
    let slug = modelId.replacingOccurrences(of: "/", with: "_")
    let stagingRoot = Self.resolveStagingRoot()
    let stagingURL = stagingRoot.appendingPathComponent(slug, isDirectory: true)

    guard FileManager.default.fileExists(atPath: stagingURL.path) else {
      FileHandle.standardOutput.write(
        Data("staging: nothing to delete at \(stagingURL.path)\n".utf8)
      )
      return
    }
    if dryRun {
      FileHandle.standardOutput.write(
        Data("staging: would delete \(stagingURL.path)\n".utf8)
      )
      return
    }
    try FileManager.default.removeItem(at: stagingURL)
    FileHandle.standardOutput.write(
      Data("staging: deleted \(stagingURL.path)\n".utf8)
    )
  }

  // MARK: - --cache

  private func runCacheDelete() throws {
    let dir: URL
    do {
      dir = try Acervo.modelDirectory(for: modelId)
    } catch let err as AcervoError {
      // invalidModelId surfaces here; rethrow it cleanly.
      throw err
    }
    guard FileManager.default.fileExists(atPath: dir.path) else {
      FileHandle.standardOutput.write(
        Data("cache: nothing to delete at \(dir.path)\n".utf8)
      )
      return
    }
    if dryRun {
      FileHandle.standardOutput.write(
        Data("cache: would delete \(dir.path)\n".utf8)
      )
      return
    }
    try Acervo.deleteModel(modelId)
    FileHandle.standardOutput.write(
      Data("cache: deleted \(dir.path)\n".utf8)
    )
  }

  // MARK: - --cdn

  private func runCDNDelete() async throws {
    let credentials = try CredentialResolver.resolve(
      bucketOverride: bucket,
      endpointOverride: endpoint
    )

    if dryRun {
      FileHandle.standardOutput.write(
        Data(
          "cdn: would delete every object under models/\(slug)/ from \(credentials.bucket)\n"
            .utf8
        )
      )
      return
    }

    let proceed = try TTYConfirm.confirm(
      prompt: "About to delete every object under models/\(slug)/ from \(credentials.bucket). Continue? [y/N] ",
      yesBypass: yes
    )
    guard proceed else {
      FileHandle.standardOutput.write(
        Data("cdn: cancelled.\n".utf8)
      )
      return
    }

    let reporter = DeleteProgressReporter(quiet: progressOptions.quiet)
    try await Acervo.deleteFromCDN(
      modelId: modelId,
      credentials: credentials,
      progress: { event in reporter.handle(event) }
    )
    FileHandle.standardOutput.write(
      Data("cdn: deleted models/\(slug)/ from \(credentials.bucket)\n".utf8)
    )
  }

  // MARK: - Helpers

  private var slug: String {
    modelId.replacingOccurrences(of: "/", with: "_")
  }

  private static func resolveStagingRoot() -> URL {
    if let envRoot = ProcessInfo.processInfo.environment["STAGING_DIR"], !envRoot.isEmpty {
      return URL(fileURLWithPath: envRoot, isDirectory: true)
    }
    return URL(fileURLWithPath: "/tmp/acervo-staging", isDirectory: true)
  }
}

/// Lightweight stdout sink for `AcervoDeleteProgress`. Writes one line per
/// batch event when not in `--quiet`. Not a TUI bar — the work is fast and
/// usually one batch.
final class DeleteProgressReporter: @unchecked Sendable {
  private let quiet: Bool
  init(quiet: Bool) { self.quiet = quiet }

  func handle(_ event: AcervoDeleteProgress) {
    if quiet { return }
    switch event {
    case .listingPrefix:
      FileHandle.standardOutput.write(Data("cdn: listing prefix…\n".utf8))
    case .deletingBatch(let count, let total):
      FileHandle.standardOutput.write(
        Data("cdn: deleted batch of \(count) (cumulative \(total))\n".utf8)
      )
    case .complete:
      FileHandle.standardOutput.write(Data("cdn: complete.\n".utf8))
    }
  }
}
