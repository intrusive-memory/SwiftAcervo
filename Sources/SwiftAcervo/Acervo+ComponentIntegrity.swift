// Acervo+ComponentIntegrity.swift
// SwiftAcervo
//
// Component integrity verification: SHA-256 validation post-download.
// All verification concerns are consolidated here: callers always reach these via `Acervo.<symbol>`.

import Foundation

extension Acervo {

  /// Verifies the integrity of a downloaded component's files.
  ///
  /// For each file with a declared SHA-256 checksum, computes the actual
  /// hash and compares it to the expected value. Files without declared
  /// checksums are skipped.
  ///
  /// - Parameter componentId: The ID of the component to verify.
  /// - Returns: `true` if all checksums pass (or if no checksums are declared).
  /// - Throws: `AcervoError.componentNotRegistered` if the ID is not in the registry.
  /// - Throws: `AcervoError.componentNotDownloaded` if any required files are missing.
  public static func verifyComponent(_ componentId: String) throws -> Bool {
    try verifyComponent(componentId, in: sharedModelsDirectory)
  }

  /// Verifies the integrity of a downloaded component's files,
  /// using a custom base directory.
  ///
  /// This internal overload enables testing with temporary directories.
  ///
  /// - Parameters:
  ///   - componentId: The ID of the component to verify.
  ///   - baseDirectory: The base directory to resolve component paths against.
  /// - Returns: `true` if all checksums pass (or if no checksums are declared).
  /// - Throws: `AcervoError.componentNotRegistered` if the ID is not in the registry.
  /// - Throws: `AcervoError.componentNotDownloaded` if any required files are missing.
  static func verifyComponent(_ componentId: String, in baseDirectory: URL) throws -> Bool {
    guard let descriptor = ComponentRegistry.shared.component(componentId) else {
      throw AcervoError.componentNotRegistered(componentId)
    }

    // Verification requires a file list; throw rather than silently masking configuration errors.
    guard descriptor.isHydrated else {
      throw AcervoError.componentNotHydrated(id: componentId)
    }

    let componentDir = baseDirectory.appendingPathComponent(slugify(descriptor.repoId))

    // Check that all files exist first
    let fm = FileManager.default
    for file in descriptor.files {
      let filePath = componentDir.appendingPathComponent(file.relativePath).path
      guard fm.fileExists(atPath: filePath) else {
        throw AcervoError.componentNotDownloaded(componentId)
      }
    }

    // Verify checksums
    for file in descriptor.files {
      let result = try IntegrityVerification.verify(file: file, in: componentDir)
      if !result {
        return false
      }
    }

    return true
  }

  /// Verifies all downloaded components and returns the IDs of any that fail.
  ///
  /// Iterates over all registered components. Components that are not downloaded
  /// are skipped (they are not failures -- they are simply not yet available).
  /// Only components whose files are present but fail checksum verification
  /// are included in the returned array.
  ///
  /// - Returns: An array of component IDs that failed integrity verification.
  ///   Empty if all pass (or if no components are registered/downloaded).
  /// - Throws: Errors from file I/O during hash computation.
  public static func verifyAllComponents() throws -> [String] {
    try verifyAllComponents(in: sharedModelsDirectory)
  }

  /// Verifies all downloaded components using a custom base directory.
  ///
  /// This internal overload enables testing with temporary directories.
  ///
  /// - Parameter baseDirectory: The base directory to resolve component paths against.
  /// - Returns: An array of component IDs that failed integrity verification.
  /// - Throws: Errors from file I/O during hash computation.
  static func verifyAllComponents(in baseDirectory: URL) throws -> [String] {
    var failures: [String] = []

    for descriptor in registeredComponents() {
      // Skip components that are not downloaded
      guard isComponentReady(descriptor.id, in: baseDirectory) else {
        continue
      }

      // Verify this downloaded component
      let passed = try verifyComponent(descriptor.id, in: baseDirectory)
      if !passed {
        failures.append(descriptor.id)
      }
    }

    return failures
  }
}
