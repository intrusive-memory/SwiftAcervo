// Acervo+CDNConfiguration.swift
// SwiftAcervo
//
// CDN base-URL resolution. The CDN host is a per-consumer configuration value
// with NO hardcoded default — exactly like the App Group identifier resolved in
// `Acervo+PathResolution.swift`. Consumers supply it via an environment variable
// (CLIs / tests / CI) or an Info.plist key (UI apps); a missing or malformed
// value is a configuration error and traps with `fatalError`.
//
// `AcervoDownloader` builds every download/manifest URL from `cdnBaseURL`, and
// `SecureDownloadSession` derives its allowed-redirect host from
// `cdnAllowedHost`. There is no other source of the CDN host in library/CLI code.

import Foundation

extension Acervo {

  /// Environment variable that supplies the CDN base URL to consumers without an
  /// Info.plist (CLI tools, scripts, test runners, CI).
  ///
  /// Set in `~/.zprofile` for interactive shells:
  /// ```sh
  /// export ACERVO_CDN_BASE_URL=https://cdn.intrusive-memory.productions/models
  /// ```
  ///
  /// UI apps may instead declare the value under ``cdnBaseURLInfoPlistKey`` in
  /// their `Info.plist`; SwiftAcervo reads it at runtime via
  /// `Bundle.main.object(forInfoDictionaryKey:)`.
  ///
  /// Resolution order in ``cdnBaseURL``:
  /// 1. `ACERVO_CDN_BASE_URL` environment variable
  /// 2. `AcervoCDNBaseURL` `Info.plist` key (UI apps)
  /// 3. `fatalError` — no silent fallback
  ///
  /// - Important: xcodebuild does NOT propagate shell environment variables to
  ///   the `xctest` runner process, so test targets must declare this in their
  ///   test plan's `environmentVariableEntries` (not just the shell).
  public static let cdnBaseURLEnvironmentVariable = "ACERVO_CDN_BASE_URL"

  /// `Info.plist` key that supplies the CDN base URL to UI apps.
  ///
  /// Add to the app's `Info.plist`:
  /// ```xml
  /// <key>AcervoCDNBaseURL</key>
  /// <string>https://cdn.intrusive-memory.productions/models</string>
  /// ```
  ///
  /// Consulted only when ``cdnBaseURLEnvironmentVariable`` is unset/empty.
  public static let cdnBaseURLInfoPlistKey = "AcervoCDNBaseURL"

  /// The base URL for the CDN model repository, e.g.
  /// `https://cdn.intrusive-memory.productions/models`.
  ///
  /// This value MUST include the path prefix that `<slug>/<file>` is appended to
  /// (the `/models` segment in the example) and MUST NOT have a trailing slash.
  ///
  /// Resolved, in order, from:
  /// 1. ``cdnBaseURLEnvironmentVariable`` (`ACERVO_CDN_BASE_URL`) if non-empty
  /// 2. ``cdnBaseURLInfoPlistKey`` (`AcervoCDNBaseURL` in `Info.plist`) if non-empty
  /// 3. `fatalError` — no per-process fallback
  ///
  /// The resolved string is validated: it must parse via `URL(string:)`, use the
  /// `https` scheme, and carry a non-empty host. Any trailing `/` is stripped. A
  /// malformed value traps with a `fatalError` rather than silently degrading.
  ///
  /// - Important: Acervo refuses to invent a hardcoded CDN default because that
  ///   is exactly the divergence a per-consumer CDN configuration exists to
  ///   prevent. See `Docs/CDN_CONFIGURATION.md`.
  public static var cdnBaseURL: String {
    let resolved: String
    if let envValue = ProcessInfo.processInfo.environment[cdnBaseURLEnvironmentVariable],
      !envValue.isEmpty
    {
      resolved = envValue
    } else if let plistValue = Bundle.main.object(forInfoDictionaryKey: cdnBaseURLInfoPlistKey)
      as? String, !plistValue.isEmpty
    {
      resolved = plistValue
    } else {
      fatalError(
        """
        SwiftAcervo: no CDN base URL configured.

        UI apps (macOS / iOS): add the `AcervoCDNBaseURL` key to your Info.plist:

            <key>AcervoCDNBaseURL</key>
            <string>https://cdn.intrusive-memory.productions/models</string>

        CLI tools / scripts / test runners / CI: export ACERVO_CDN_BASE_URL in \
        your shell environment (typically ~/.zprofile):

            export ACERVO_CDN_BASE_URL=https://cdn.intrusive-memory.productions/models

        The value MUST include the path prefix that <slug>/<file> is appended to \
        (the `/models` segment above) and MUST NOT have a trailing slash.

        See SwiftAcervo's Docs/CDN_CONFIGURATION.md for details.
        """
      )
    }

    // Strip any trailing "/" so URL construction appends cleanly.
    var trimmed = resolved
    while trimmed.hasSuffix("/") {
      trimmed.removeLast()
    }

    guard let url = URL(string: trimmed),
      url.scheme == "https",
      let host = url.host,
      !host.isEmpty
    else {
      fatalError(
        """
        SwiftAcervo: malformed ACERVO_CDN_BASE_URL: \(resolved)

        The CDN base URL must be an absolute https:// URL with a host, e.g. \
        https://cdn.intrusive-memory.productions/models
        """
      )
    }

    return trimmed
  }

  /// The allowed CDN host for all model downloads, derived from ``cdnBaseURL``.
  ///
  /// `SecureDownloadSession` permits HTTP redirects only when they stay within
  /// this host. Guaranteed non-empty because ``cdnBaseURL`` validates the host
  /// before returning.
  public static var cdnAllowedHost: String {
    // `cdnBaseURL` already validated that a non-empty host is present.
    URL(string: cdnBaseURL)!.host!
  }
}
