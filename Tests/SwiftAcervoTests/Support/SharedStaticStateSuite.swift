import Testing

/// Single `.serialized` grandparent for every test that touches a piece of
/// process-wide static state in the SwiftAcervo source tree. Two distinct
/// globals are at play:
///
///   - `Acervo.customBaseDirectory` — the model storage root override.
///   - `MockURLProtocol`'s static `responder` / `requestCount` —
///     the URLProtocol stub used by tests that intercept HTTPS calls.
///
/// Before this grandparent existed, those globals had separate `.serialized`
/// parents (`CustomBaseDirectorySuite` and `MockURLProtocolSuite`). The
/// `.serialized` trait only orders tests *within* a parent, so the two
/// parents executed in parallel — which let an `EnsureAvailableEmptyFilesTests`
/// run (under `MockURLProtocolSuite`, mutating `customBaseDirectory` to a
/// tmp dir) clobber an `AcervoPathTests` read of the default
/// `customBaseDirectory` (under `CustomBaseDirectorySuite`). That race is
/// the documented chronic CI flake from the v0.8.0 mission and recurred
/// through v0.8.1.
///
/// By nesting both child suites under this grandparent, every test that
/// reads or writes either global serializes against every other such test.
/// Tests that touch neither global are unaffected and continue to run in
/// parallel at the top level.
@Suite("Shared Static State", .serialized)
struct SharedStaticStateSuite {

  /// Parent for all tests that mutate `MockURLProtocol`'s static responder
  /// or request counter. Nested under `SharedStaticStateSuite` so it cannot
  /// race with `CustomBaseDirectorySuite` writers.
  @Suite("MockURLProtocol")
  struct MockURLProtocolSuite {}

  /// Parent for all tests that read or write `Acervo.customBaseDirectory`.
  /// Nested under `SharedStaticStateSuite` so it cannot race with
  /// `MockURLProtocolSuite` tests that also mutate the global (e.g.
  /// `EnsureAvailableEmptyFilesTests`, `DownloadComponentAutoHydrationTests`).
  ///
  /// Companion helper `withIsolatedAcervoState` (in
  /// `ComponentRegistryIsolation.swift`) provides snapshot/restore semantics
  /// inside individual tests so a body that throws cannot leak state to
  /// the next serialized test.
  @Suite("Custom Base Directory")
  struct CustomBaseDirectorySuite {}
}
