import Darwin
import Foundation

/// Prompt-on-TTY confirmation helper used by destructive subcommands
/// (`acervo delete --cdn`, `acervo recache` when it will prune orphans).
///
/// Per requirements §8 Q4 / Decision Log #4:
///   * If `yesBypass` is true, returns `true` immediately (no prompt).
///   * If stdin is a TTY, prints `prompt`, reads one line, and returns
///     `true` for `y` / `yes` (case-insensitive) — anything else returns
///     `false` so the caller can short-circuit.
///   * If stdin is NOT a TTY (CI, pipe, etc.), throws a clear error
///     instructing the user to pass `--yes`. We will not prompt without a
///     human at the keyboard, and we will not proceed without confirmation.
enum TTYConfirm {

  /// Returns whether the operation may proceed.
  ///
  /// - Parameters:
  ///   - prompt: The exact prompt string printed to stdout. Should end
  ///     with `" [y/N] "` or similar so the default-no convention is
  ///     visible at a glance.
  ///   - yesBypass: When `true`, skips the prompt and returns `true`.
  ///     Wired to the subcommand's `--yes` flag.
  /// - Throws: `AcervoToolError.confirmationRequired` when stdin is not
  ///   a TTY and `yesBypass` is `false`.
  static func confirm(prompt: String, yesBypass: Bool) throws -> Bool {
    if yesBypass { return true }

    let stdinIsTTY = isatty(STDIN_FILENO) != 0
    guard stdinIsTTY else {
      throw AcervoToolError.confirmationRequired
    }

    FileHandle.standardOutput.write(Data(prompt.utf8))
    guard let line = readLine(strippingNewline: true) else {
      // EOF on TTY — treat as cancellation.
      return false
    }
    let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
    return trimmed == "y" || trimmed == "yes"
  }
}
