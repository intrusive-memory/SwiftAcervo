public protocol AcervoTelemetryReporter: Sendable {
  func capture(_ event: AcervoTelemetryEvent) async
}

public struct NoopAcervoTelemetryReporter: AcervoTelemetryReporter {
  public init() {}
  public func capture(_ event: AcervoTelemetryEvent) async {}
}
