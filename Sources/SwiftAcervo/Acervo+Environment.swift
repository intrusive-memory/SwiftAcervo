// Acervo+Environment.swift
// SwiftAcervo
//
// The single canonical description of every environment variable SwiftAcervo
// reads. The variables themselves are declared next to the code that consumes
// them (`Acervo+PathResolution.swift`, `Acervo+CDNConfiguration.swift`,
// `Acervo.swift`); this file is the one place that *describes* them for humans.
//
// Consuming binaries must not hand-write this documentation — every CLI that
// reaches models through Acervo interpolates `Acervo.environmentHelp()` into
// its `--help` output so the wording can never drift between packages:
//
//     static let configuration = CommandConfiguration(
//       commandName: "mytool",
//       abstract: "…",
//       discussion: """
//         …
//
//         \(Acervo.environmentHelp())
//         """
//     )

import Foundation

extension Acervo {

  /// Every environment variable SwiftAcervo consults, with its documentation.
  ///
  /// Enumerating these in one `CaseIterable` type is what makes the help text
  /// consumers print impossible to drift: adding a variable here adds it to
  /// every downstream binary's `--help` on the next dependency bump.
  ///
  /// The raw value is the variable name as it appears in the environment.
  public enum EnvironmentVariable: String, CaseIterable, Sendable {

    /// `ACERVO_APP_GROUP_ID` — App Group identifier used to locate the shared
    /// models container. See ``Acervo/appGroupEnvironmentVariable``.
    case appGroupID = "ACERVO_APP_GROUP_ID"

    /// `ACERVO_MODELS_DIR` — absolute path that replaces the shared models
    /// directory outright. See ``Acervo/modelsDirectoryOverrideVariable``.
    case modelsDirectory = "ACERVO_MODELS_DIR"

    /// `ACERVO_CDN_BASE_URL` — base URL every download and manifest fetch is
    /// built from. See ``Acervo/cdnBaseURLEnvironmentVariable``.
    case cdnBaseURL = "ACERVO_CDN_BASE_URL"

    /// `ACERVO_OFFLINE` — when `1`, forbids all outbound fetches.
    /// See ``Acervo/offlineModeEnvironmentVariable``.
    case offline = "ACERVO_OFFLINE"

    /// The variable name as it appears in the process environment.
    public var name: String { rawValue }

    /// Whether SwiftAcervo traps with `fatalError` when this variable (and its
    /// non-environment alternative, if any) supplies no value.
    ///
    /// `ACERVO_APP_GROUP_ID` and `ACERVO_CDN_BASE_URL` are only *conditionally*
    /// required: the first is unnecessary when ``modelsDirectory`` is set or an
    /// App Group entitlement is present, the second when the app carries an
    /// `AcervoCDNBaseURL` `Info.plist` key. Neither has a silent default.
    public var isRequired: Bool {
      switch self {
      case .appGroupID, .cdnBaseURL: return true
      case .modelsDirectory, .offline: return false
      }
    }

    /// The non-environment way a UI app can supply the same value, if one
    /// exists — an entitlement key or an `Info.plist` key.
    ///
    /// `nil` for variables that have no bundle-level equivalent.
    public var bundleAlternative: String? {
      switch self {
      case .appGroupID: return "com.apple.security.application-groups (entitlement)"
      case .cdnBaseURL: return "\(Acervo.cdnBaseURLInfoPlistKey) (Info.plist)"
      case .modelsDirectory, .offline: return nil
      }
    }

    /// Human-readable description of what the variable does.
    ///
    /// Stored as one unwrapped paragraph;
    /// ``Acervo/environmentHelp(title:indent:width:)`` word-wraps it to the
    /// column left over after the name gutter. Do not pre-wrap it here —
    /// `swift-argument-parser` re-flows any `discussion` line that overruns the
    /// terminal, which would break continuation alignment.
    public var summary: String {
      switch self {
      case .appGroupID:
        return """
          App Group identifier that locates the shared models directory: \
          ~/Library/Group Containers/<id>/SharedModels. Required for CLIs, \
          scripts, and test runners, which have no entitlement to read it \
          from. Signed UI apps may instead declare the group in their \
          com.apple.security.application-groups entitlement.
          """
      case .modelsDirectory:
        return """
          Absolute path that replaces the shared models directory outright. \
          Takes precedence over ACERVO_APP_GROUP_ID and over the entitlement, \
          so no App Group is required when it is set. The layout beneath it \
          must match the canonical one: a single <org>_<repo> subdirectory \
          per model. Intended for unentitled processes that the macOS sandbox \
          blocks from reading the real container. Not for production use.
          """
      case .cdnBaseURL:
        return """
          Base URL that every model download and manifest fetch is built \
          from. Must include the path prefix that <slug>/<file> is appended \
          to, and must not end in a slash. UI apps may instead set the \
          \(Acervo.cdnBaseURLInfoPlistKey) Info.plist key.
          """
      case .offline:
        return """
          Set to 1 to forbid all network access; only models already present \
          on disk resolve, and anything else throws rather than reaching the \
          CDN.
          """
      }
    }

    /// The value currently set in the process environment, or `nil` when unset
    /// or empty.
    ///
    /// Empty is treated as unset throughout SwiftAcervo, so this normalizes it.
    public var currentValue: String? {
      guard let value = ProcessInfo.processInfo.environment[rawValue],
        !value.isEmpty
      else { return nil }
      return value
    }
  }

  /// The canonical `ENVIRONMENT` block for a consuming binary's `--help`.
  ///
  /// Every executable in the ecosystem that reaches models through Acervo
  /// interpolates this into its `CommandConfiguration.discussion` rather than
  /// restating the variables itself. That keeps the wording identical across
  /// binaries and means a variable added to ``EnvironmentVariable`` shows up in
  /// all of them on the next dependency bump.
  ///
  /// ```swift
  /// static let configuration = CommandConfiguration(
  ///   commandName: "bruja",
  ///   abstract: "Run local LLM inference.",
  ///   discussion: """
  ///     …tool-specific prose…
  ///
  ///     \(Acervo.environmentHelp())
  ///     """
  /// )
  /// ```
  ///
  /// - Parameters:
  ///   - title: Section heading. Pass `nil` to emit only the variable entries,
  ///     for callers that supply their own heading or merge the block into a
  ///     larger `ENVIRONMENT VARIABLES` section.
  ///   - indent: Leading whitespace applied to each variable entry. Defaults to
  ///     two spaces, matching `swift-argument-parser`'s own help layout.
  ///   - width: Total column budget. Every emitted line is kept at or under
  ///     this so `swift-argument-parser` never re-flows the block and destroys
  ///     the continuation alignment. Defaults to 79 — one under the 80-column
  ///     width `swift-argument-parser` assumes for a non-TTY `--help`, which it
  ///     re-flows at exactly 80.
  /// - Returns: A ready-to-print block with no trailing newline.
  public static func environmentHelp(
    title: String? = "MODEL STORAGE (SwiftAcervo)",
    indent: String = "  ",
    width: Int = 79
  ) -> String {
    // Name column is sized to the longest variable so descriptions align in a
    // single ragged-right column regardless of which variables exist.
    let nameWidth =
      EnvironmentVariable.allCases
      .map(\.rawValue.count)
      .max() ?? 0
    let gutter = "  "
    let continuationPad = indent + String(repeating: " ", count: nameWidth) + gutter
    // Floor the text column so a pathologically small `width` still renders
    // something readable rather than one word per line.
    let textWidth = max(24, width - continuationPad.count)

    var lines: [String] = []
    if let title {
      lines.append(title)
    }
    for variable in EnvironmentVariable.allCases {
      let paddedName = variable.rawValue.padding(
        toLength: nameWidth,
        withPad: " ",
        startingAt: 0
      )
      for (offset, text) in wrap(variable.summary, to: textWidth).enumerated() {
        lines.append(
          offset == 0
            ? indent + paddedName + gutter + text
            : continuationPad + text
        )
      }
    }
    return lines.joined(separator: "\n")
  }

  /// Greedy word-wrap. A single word longer than `width` is emitted on its own
  /// over-long line rather than hyphenated — env var names and URLs must stay
  /// copy-pasteable.
  private static func wrap(_ text: String, to width: Int) -> [String] {
    var lines: [String] = []
    var current = ""
    for word in text.split(separator: " ", omittingEmptySubsequences: true) {
      if current.isEmpty {
        current = String(word)
      } else if current.count + 1 + word.count <= width {
        current += " " + word
      } else {
        lines.append(current)
        current = String(word)
      }
    }
    if !current.isEmpty { lines.append(current) }
    return lines
  }

  /// A non-trapping report of how model storage would resolve right now.
  ///
  /// Unlike ``sharedModelsDirectory`` and ``cdnBaseURL`` — which `fatalError`
  /// on a missing configuration by design — this inspects the environment
  /// without resolving anything, so it is safe to print from a `doctor` /
  /// `--diagnose` command precisely when the configuration is broken and the
  /// user needs to see why.
  ///
  /// - Returns: A multi-line report naming each variable, its current value,
  ///   and the effective source of the shared models directory.
  public static func environmentDiagnostics() -> String {
    var lines: [String] = ["SwiftAcervo \(version) — environment"]

    for variable in EnvironmentVariable.allCases {
      let value = variable.currentValue.map { "= \($0)" } ?? "(unset)"
      lines.append("  \(variable.rawValue) \(value)")
    }

    lines.append("")
    lines.append("Shared models directory resolves from:")
    // Switching on the same resolution the trapping accessor uses is what
    // guarantees this report can never describe a path different from the one
    // `sharedModelsDirectory` would hand out.
    switch modelsDirectoryResolution {
    case .override(let url):
      lines.append("  ACERVO_MODELS_DIR override → \(url.path)")
    case .appGroup(let id, let url, let fromEnvironment):
      let source = fromEnvironment ? "ACERVO_APP_GROUP_ID" : "application-groups entitlement"
      lines.append("  App Group '\(id)' (from \(source))")
      lines.append("  → \(url.path)")
    case .appGroupNotGranted(let id):
      lines.append("  App Group '\(id)' is NOT granted to this process.")
      lines.append("  Add it to com.apple.security.application-groups, or set ACERVO_MODELS_DIR.")
    case .noAppGroupIdentifier:
      lines.append("  NOTHING — set ACERVO_APP_GROUP_ID or ACERVO_MODELS_DIR.")
      lines.append("  Any model path resolution will trap until one is supplied.")
    }

    lines.append("")
    if let cdn = EnvironmentVariable.cdnBaseURL.currentValue {
      lines.append("CDN base URL: \(cdn) (from ACERVO_CDN_BASE_URL)")
    } else if let plist = Bundle.main.object(forInfoDictionaryKey: cdnBaseURLInfoPlistKey)
      as? String, !plist.isEmpty
    {
      lines.append("CDN base URL: \(plist) (from \(cdnBaseURLInfoPlistKey) Info.plist key)")
    } else {
      lines.append("CDN base URL: NOTHING — set ACERVO_CDN_BASE_URL.")
      lines.append("  Any download or manifest fetch will trap until one is supplied.")
    }

    return lines.joined(separator: "\n")
  }
}
