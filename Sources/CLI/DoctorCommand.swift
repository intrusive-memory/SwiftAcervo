import ArgumentParser
import Foundation
import SwiftAcervo

/// Reports how SwiftAcervo would resolve model storage in the current
/// environment, without resolving it.
///
/// `Acervo.sharedModelsDirectory` and `Acervo.cdnBaseURL` trap with
/// `fatalError` when nothing is configured — deliberately, because a silent
/// per-process fallback is the divergence the App Group container exists to
/// prevent. But that is exactly the moment an operator needs a readout, so this
/// command goes through `Acervo.environmentDiagnostics()`, which inspects the
/// environment directly and can describe a broken configuration instead of
/// dying on it.
///
/// This is the reference implementation of the `doctor` subcommand every
/// binary in the ecosystem that reaches models through Acervo should carry.
struct DoctorCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "doctor",
    abstract: "Report how model storage and the CDN resolve in this environment.",
    discussion: """
      Prints every SwiftAcervo environment variable, its current value, and the
      effective source of the shared models directory and CDN base URL.

      Safe to run when the configuration is broken: it never resolves through
      the trapping accessors, so a missing App Group id is reported rather than
      fatal.

      EXIT STATUS
        0  model storage and the CDN both resolve
        1  one or both are unconfigured (use --quiet in scripts)

      EXAMPLES
        acervo doctor
        ACERVO_MODELS_DIR=/tmp/models acervo doctor
        acervo doctor --quiet && echo configured
      """
  )

  @Flag(
    name: [.short, .customLong("quiet")],
    help: "Suppress the report; signal configuration state through exit status only."
  )
  var quiet = false

  func run() async throws {
    if !quiet {
      FileHandle.standardOutput.write(Data((Acervo.environmentDiagnostics() + "\n").utf8))
    }

    // Ask the library, not the environment: a codesigned acervo resolves its
    // App Group from the entitlement with no variable set, and checking the
    // variables directly would report that healthy setup as broken.
    let storageConfigured = Acervo.resolvedSharedModelsDirectory != nil
    // The CDN has no non-trapping accessor and a CLI has no Info.plist, so the
    // environment variable is the only source available here.
    let cdnConfigured = Acervo.EnvironmentVariable.cdnBaseURL.currentValue != nil

    guard storageConfigured && cdnConfigured else {
      throw ExitCode(1)
    }
  }
}
