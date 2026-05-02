#if os(macOS)
  import Testing

  /// Shared parent suite for every test that reads or writes process-wide
  /// environment state (PATH, R2_*, HF_TOKEN, etc.). The `.serialized` trait
  /// forces every nested test to run one at a time across suites, eliminating
  /// the PATH-clobber race between ToolCheckTests and ShipCommandTests.
  /// Mirrors the AppGroupEnvironmentSuite pattern.
  @Suite("Process Environment", .serialized)
  struct ProcessEnvironmentSuite {}
#endif
