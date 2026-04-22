import ArgumentParser
import Darwin
import Foundation
import Progress

/// Shared `--quiet` flag surface for every acervo subcommand.
///
/// `@OptionGroup var progressOptions: ProgressOptions` in a subcommand adds
/// a `--quiet` / `-q` flag. Default behaviour is "show progress"; the flag
/// suppresses both the Swift TUI progress bar and the live passthrough of
/// subprocess stdio (hf / aws).
struct ProgressOptions: ParsableArguments {
  @Flag(
    name: [.short, .customLong("quiet")],
    help:
      "Suppress the download/upload progress bar and subprocess output. Errors still print."
  )
  var quiet: Bool = false
}

/// Thin wrapper around `Progress.swift`'s `ProgressBar` that respects the
/// `--quiet` flag and is safe to pass into actor-isolated methods.
///
/// The underlying `ProgressBar` is not `Sendable`; this class is declared
/// `@unchecked Sendable` on the basis that callers drive it sequentially
/// from a single task. The hashing loops in acervo always advance the bar
/// in a simple `for` loop, so this invariant holds in practice.
///
/// When `quiet` is true, when the total is zero, or when stdout is not a
/// TTY (so we don't spam CI logs with ANSI escapes), no bar is constructed
/// and `advance()` becomes a no-op.
final class ProgressReporter: @unchecked Sendable {
  private var bar: ProgressBar?

  init(label: String, total: Int, quiet: Bool) {
    guard !quiet, total > 0, isatty(fileno(stdout)) != 0 else {
      self.bar = nil
      return
    }
    let elements: [ProgressElementType] = [
      ProgressString(string: label),
      ProgressIndex(),
      ProgressBarLine(),
      ProgressPercent(),
      ProgressTimeEstimates(),
    ]
    self.bar = ProgressBar(count: total, configuration: elements)
  }

  /// Advance the bar by one unit. No-op when quiet.
  func advance() {
    bar?.next()
  }
}
