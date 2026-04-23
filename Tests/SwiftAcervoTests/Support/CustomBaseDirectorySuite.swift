// OPERATION TRIPWIRE GAUNTLET Sortie 2 decision: apply BOTH options — (a) `.serialized`
// parent suite (this file) AND (b) `withIsolatedAcervoState` snapshot/restore helper
// (see ComponentRegistryIsolation.swift).

import Testing

/// Shared parent suite for every test that reads or writes
/// `Acervo.customBaseDirectory`. The `.serialized` trait forces all nested
/// tests (across `@Suite` types declared as extensions on this struct) to run
/// one at a time, eliminating the race documented in TESTING_REQUIREMENTS.md
/// between `AcervoPathTests` (reader), `AcervoFilesystemEdgeCaseTests` (writer),
/// and `ModelDownloadManagerTests` (writer). Mirrors the `MockURLProtocolSuite`
/// pattern used for another piece of process-wide static state.
@Suite("Custom Base Directory", .serialized)
struct CustomBaseDirectorySuite {}
