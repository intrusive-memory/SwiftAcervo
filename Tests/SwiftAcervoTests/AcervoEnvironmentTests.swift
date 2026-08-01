// Companion tests for Sources/SwiftAcervo/Acervo+Environment.swift
import Foundation
import Testing

@testable import SwiftAcervo

/// Rendering tests for the shared environment help block.
///
/// These touch no process-wide state (they only read `EnvironmentVariable`
/// metadata and format strings), so they stay at the top level and run in
/// parallel. The env-var-reading tests live in
/// `SharedStaticStateSuite.AppGroupEnvironmentSuite` below.
@Suite("AcervoEnvironmentHelpTests")
struct AcervoEnvironmentHelpTests {

  // MARK: - Enum ↔ implementation parity
  //
  // The whole point of `EnvironmentVariable` is that no consumer hardcodes
  // these names. If the enum drifts from the constants the library actually
  // reads, every downstream `--help` documents a variable that does nothing.

  @Test("every EnvironmentVariable case matches the constant the library reads")
  func casesMatchLibraryConstants() {
    #expect(Acervo.EnvironmentVariable.appGroupID.rawValue == Acervo.appGroupEnvironmentVariable)
    #expect(
      Acervo.EnvironmentVariable.modelsDirectory.rawValue
        == Acervo.modelsDirectoryOverrideVariable
    )
    #expect(Acervo.EnvironmentVariable.cdnBaseURL.rawValue == Acervo.cdnBaseURLEnvironmentVariable)
    #expect(Acervo.EnvironmentVariable.offline.rawValue == Acervo.offlineModeEnvironmentVariable)
  }

  @Test("allCases covers exactly the four documented variables")
  func allCasesIsComplete() {
    let names = Set(Acervo.EnvironmentVariable.allCases.map(\.name))
    #expect(
      names == [
        "ACERVO_APP_GROUP_ID",
        "ACERVO_MODELS_DIR",
        "ACERVO_CDN_BASE_URL",
        "ACERVO_OFFLINE",
      ])
  }

  // MARK: - Help block rendering

  /// The regression this file exists to prevent: `swift-argument-parser`
  /// re-flows any `discussion` line that reaches the terminal width, which
  /// collapses the continuation indent and renders the block unreadable.
  @Test("no rendered line reaches the default 79-column budget")
  func defaultRenderFitsWidth() {
    for line in Acervo.environmentHelp().split(separator: "\n", omittingEmptySubsequences: false) {
      #expect(line.count <= 79, "over-wide help line (\(line.count)): \(line)")
    }
  }

  /// Widths start at 60: the name gutter is 23 columns and the longest
  /// unbreakable token (`com.apple.security.application-groups`) is 37, so 60
  /// is the narrowest budget the block can honor without hyphenating. Narrower
  /// budgets deliberately overrun rather than split a token — see
  /// ``longWordsStayIntact()``.
  @Test("custom width is respected", arguments: [60, 79, 100, 120])
  func customWidthIsRespected(width: Int) {
    let rendered = Acervo.environmentHelp(width: width)
    for line in rendered.split(separator: "\n", omittingEmptySubsequences: false) {
      #expect(line.count <= width, "over-wide help line (\(line.count)): \(line)")
    }
  }

  @Test("every variable name appears in the rendered block")
  func allVariablesAreDocumented() {
    let rendered = Acervo.environmentHelp()
    for variable in Acervo.EnvironmentVariable.allCases {
      #expect(rendered.contains(variable.name), "missing \(variable.name) from help block")
    }
  }

  @Test("title is emitted by default and omitted when nil")
  func titleIsOptional() {
    #expect(Acervo.environmentHelp().hasPrefix("MODEL STORAGE (SwiftAcervo)\n"))
    #expect(Acervo.environmentHelp(title: nil).hasPrefix("  ACERVO_"))
  }

  @Test("indent is applied to each variable entry")
  func indentIsApplied() {
    let rendered = Acervo.environmentHelp(title: nil, indent: "    ")
    #expect(rendered.hasPrefix("    ACERVO_APP_GROUP_ID"))
  }

  @Test("block has no trailing newline so callers control spacing")
  func noTrailingNewline() {
    #expect(!Acervo.environmentHelp().hasSuffix("\n"))
  }

  @Test("a word longer than the text column is not broken mid-token")
  func longWordsStayIntact() {
    // URLs and entitlement keys must remain copy-pasteable even at a narrow
    // budget, so the greedy wrapper never hyphenates.
    let rendered = Acervo.environmentHelp(width: 24)
    #expect(rendered.contains("com.apple.security.application-groups"))
    #expect(rendered.contains(Acervo.cdnBaseURLInfoPlistKey))
  }

  // MARK: - Per-variable metadata

  @Test("the models-directory override is documented as optional")
  func overrideIsOptional() {
    #expect(Acervo.EnvironmentVariable.modelsDirectory.isRequired == false)
    #expect(Acervo.EnvironmentVariable.offline.isRequired == false)
    #expect(Acervo.EnvironmentVariable.appGroupID.isRequired)
    #expect(Acervo.EnvironmentVariable.cdnBaseURL.isRequired)
  }

  @Test("only the variables with a bundle-level equivalent advertise one")
  func bundleAlternatives() {
    #expect(Acervo.EnvironmentVariable.appGroupID.bundleAlternative != nil)
    #expect(
      Acervo.EnvironmentVariable.cdnBaseURL.bundleAlternative?
        .contains(Acervo.cdnBaseURLInfoPlistKey) == true
    )
    #expect(Acervo.EnvironmentVariable.modelsDirectory.bundleAlternative == nil)
    #expect(Acervo.EnvironmentVariable.offline.bundleAlternative == nil)
  }
}

extension SharedStaticStateSuite.AppGroupEnvironmentSuite {

  /// Tests for `currentValue` and `environmentDiagnostics()`, both of which
  /// read the process environment.
  ///
  /// Nested under `AppGroupEnvironmentSuite` (`.serialized`) because they
  /// mutate `ACERVO_MODELS_DIR` / `ACERVO_APP_GROUP_ID`, which every
  /// `Acervo.sharedModelsDirectory` reader also consults.
  @Suite("AcervoEnvironmentDiagnosticsTests")
  struct AcervoEnvironmentDiagnosticsTests {

    /// Snapshots and restores `variable` around `body`, setting it to `value`
    /// (or unsetting when `value` is nil). Restores on throw so serialized
    /// siblings see a clean slate.
    private func withEnv<R>(
      _ variable: Acervo.EnvironmentVariable,
      _ value: String?,
      _ body: () throws -> R
    ) rethrows -> R {
      let key = variable.rawValue
      let previous = ProcessInfo.processInfo.environment[key]
      if let value {
        setenv(key, value, 1)
      } else {
        unsetenv(key)
      }
      defer {
        if let previous {
          setenv(key, previous, 1)
        } else {
          unsetenv(key)
        }
      }
      return try body()
    }

    // MARK: - currentValue

    @Test("currentValue reads the process environment")
    func currentValueReadsEnvironment() {
      withEnv(.modelsDirectory, "/tmp/acervo-current-value") {
        #expect(
          Acervo.EnvironmentVariable.modelsDirectory.currentValue == "/tmp/acervo-current-value")
      }
    }

    @Test("currentValue normalizes empty to nil, matching resolution semantics")
    func emptyValueIsNil() {
      // Every resolution site in the library treats "" as unset; the
      // diagnostic surface must agree or it will report a variable as
      // configured when it is inert.
      withEnv(.modelsDirectory, "") {
        #expect(Acervo.EnvironmentVariable.modelsDirectory.currentValue == nil)
      }
    }

    @Test("currentValue is nil when the variable is unset")
    func unsetValueIsNil() {
      withEnv(.modelsDirectory, nil) {
        #expect(Acervo.EnvironmentVariable.modelsDirectory.currentValue == nil)
      }
    }

    // MARK: - environmentDiagnostics

    @Test("diagnostics report the override as the effective source")
    func diagnosticsReportOverride() {
      withEnv(.modelsDirectory, "/tmp/acervo-diagnostics") {
        let report = Acervo.environmentDiagnostics()
        #expect(report.contains("ACERVO_MODELS_DIR override → /tmp/acervo-diagnostics"))
      }
    }

    @Test("diagnostics name every variable and its state")
    func diagnosticsListAllVariables() {
      withEnv(.modelsDirectory, "/tmp/acervo-diagnostics-list") {
        let report = Acervo.environmentDiagnostics()
        for variable in Acervo.EnvironmentVariable.allCases {
          #expect(report.contains(variable.name), "diagnostics omit \(variable.name)")
        }
        #expect(report.contains("(unset)"))
      }
    }

    /// `sharedModelsDirectory` traps by design when nothing is configured —
    /// which is exactly when an operator runs a diagnostic. The report must
    /// therefore describe the missing configuration instead of resolving it.
    @Test("diagnostics do not trap when no model storage is configured")
    func diagnosticsSurviveMissingConfiguration() {
      withEnv(.modelsDirectory, nil) {
        withEnv(.appGroupID, nil) {
          let report = Acervo.environmentDiagnostics()
          #expect(report.contains("SwiftAcervo \(Acervo.version)"))
          // An entitled host would still resolve a group; an unentitled test
          // runner would not. Either way the call must return a report.
          #expect(report.contains("Shared models directory resolves from:"))
        }
      }
    }

    // MARK: - resolvedSharedModelsDirectory

    /// The invariant that lets `doctor` commands and settings screens ask
    /// "is storage configured?" without risking the trap — and that stops the
    /// two accessors from ever disagreeing about the path.
    @Test("resolvedSharedModelsDirectory matches sharedModelsDirectory when configured")
    func optionalAccessorAgreesWithTrappingOne() {
      withEnv(.modelsDirectory, "/tmp/acervo-optional-accessor") {
        #expect(Acervo.resolvedSharedModelsDirectory == Acervo.sharedModelsDirectory)
      }
      withIsolatedSharedModelsDirectory { sharedDir in
        #expect(Acervo.resolvedSharedModelsDirectory == sharedDir)
      }
    }

    @Test("resolvedSharedModelsDirectory is nil when nothing is configured")
    func optionalAccessorIsNilWhenUnconfigured() throws {
      withEnv(.modelsDirectory, nil) {
        withEnv(.appGroupID, nil) {
          // A codesigned host binary can still resolve a group from its
          // entitlement, in which case there is nothing to assert — the
          // unconfigured branch is unreachable there.
          try? #require(Acervo.resolvedAppGroupIdentifier == nil)
          if Acervo.resolvedAppGroupIdentifier == nil {
            #expect(Acervo.resolvedSharedModelsDirectory == nil)
          }
        }
      }
    }

    @Test("resolution reports the override as its source")
    func resolutionReportsOverrideSource() {
      withEnv(.modelsDirectory, "/tmp/acervo-resolution-source") {
        guard case .override(let url) = Acervo.modelsDirectoryResolution else {
          Issue.record("expected .override, got \(Acervo.modelsDirectoryResolution)")
          return
        }
        #expect(url.path == "/tmp/acervo-resolution-source")
      }
    }

    @Test("resolution attributes an env-supplied group to the environment")
    func resolutionAttributesEnvironmentSource() {
      withEnv(.modelsDirectory, nil) {
        withIsolatedSharedModelsDirectory { _ in
          guard case .appGroup(_, _, let fromEnvironment) = Acervo.modelsDirectoryResolution
          else {
            Issue.record("expected .appGroup, got \(Acervo.modelsDirectoryResolution)")
            return
          }
          #expect(
            fromEnvironment, "group came from ACERVO_APP_GROUP_ID but was not attributed to it")
        }
      }
    }

    @Test("diagnostics report the CDN base URL source")
    func diagnosticsReportCDNSource() {
      withEnv(.cdnBaseURL, "https://example.test/models") {
        let report = Acervo.environmentDiagnostics()
        #expect(
          report.contains("CDN base URL: https://example.test/models (from ACERVO_CDN_BASE_URL)"))
      }
    }
  }
}
