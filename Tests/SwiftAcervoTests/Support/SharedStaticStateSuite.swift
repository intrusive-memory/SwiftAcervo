import Testing

/// Single `.serialized` grandparent for every test that touches a piece of
/// process-wide static state in the SwiftAcervo source tree. Two distinct
/// globals are at play:
///
///   - `ACERVO_APP_GROUP_ID` — the environment variable that supplies the
///     App Group identifier to non-app-bundle consumers (CLIs, scripts,
///     test runners). `Acervo.sharedModelsDirectory` reads this on every
///     access, so concurrent writers race.
///   - `MockURLProtocol`'s static `responder` / `requestCount` —
///     the URLProtocol stub used by tests that intercept HTTPS calls.
///
/// Before this grandparent existed, those globals had separate `.serialized`
/// parents. The `.serialized` trait only orders tests *within* a parent, so
/// the two parents executed in parallel — which let tests under one parent
/// clobber state owned by the other. By nesting both child suites under this
/// grandparent, every test that reads or writes either global serializes
/// against every other such test. Tests that touch neither global are
/// unaffected and continue to run in parallel at the top level.
@Suite("Shared Static State", .serialized)
struct SharedStaticStateSuite {

  /// Parent for all tests that mutate `MockURLProtocol`'s static responder
  /// or request counter. Nested under `SharedStaticStateSuite` so it cannot
  /// race with `AppGroupEnvironmentSuite` writers.
  @Suite("MockURLProtocol")
  struct MockURLProtocolSuite {}

  /// Parent for all tests that read or write `ACERVO_APP_GROUP_ID` (which
  /// `Acervo.sharedModelsDirectory` reads on every access). Nested under
  /// `SharedStaticStateSuite` so it cannot race with `MockURLProtocolSuite`
  /// tests that may also mutate the env var via `withIsolatedAcervoState`.
  ///
  /// Companion helper `withIsolatedAcervoState` (in
  /// `ComponentRegistryIsolation.swift`) provides snapshot/restore semantics
  /// inside individual tests so a body that throws cannot leak state to
  /// the next serialized test.
  @Suite("App Group Environment")
  struct AppGroupEnvironmentSuite {}
}
