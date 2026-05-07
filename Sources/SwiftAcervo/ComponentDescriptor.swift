// ComponentDescriptor.swift
// SwiftAcervo
//
// Declarative types describing downloadable model components.
// Model plugins create ComponentDescriptor instances and register
// them with Acervo to declare what components exist in the world.

import Foundation

/// The functional role of a model component within a pipeline.
///
/// Use `.backbone` for the primary neural network in diffusion pipelines (DiT, U-Net).
/// Use `.languageModel` for autoregressive models that do not participate in diffusion
/// (e.g., Qwen3-TTS). Use `.encoder` for text encoders regardless of their underlying
/// architecture (T5, CLIP, Qwen3-as-encoder, Mistral-as-encoder).
public enum ComponentType: String, Sendable, CaseIterable, Codable {
  /// Text encoders (T5, CLIP, Qwen3, Mistral).
  case encoder
  /// Core model (DiT, autoregressive, etc.).
  case backbone
  /// Latent-to-data conversion (VAE, vocoder).
  case decoder
  /// Noise scheduling (weights are rare, but some are learned).
  case scheduler
  /// Tokenizer files (often bundled with encoder, but separable).
  case tokenizer
  /// Anything else (LoRA adapters, config files, etc.).
  case auxiliary
  /// Autoregressive LLMs used for non-diffusion inference (e.g., TTS).
  case languageModel
}

/// A file within a downloadable component, with optional size and integrity metadata.
public struct ComponentFile: Sendable, Equatable {
  /// The file path relative to the component's root directory
  /// (e.g., "model.safetensors" or "speech_tokenizer/config.json").
  public let relativePath: String

  /// Expected file size in bytes, or `nil` if unknown.
  public let expectedSizeBytes: Int64?

  /// Expected SHA-256 hex digest, or `nil` to skip verification.
  public let sha256: String?

  /// Creates a new component file descriptor.
  ///
  /// - Parameters:
  ///   - relativePath: The file path relative to the component root.
  ///   - expectedSizeBytes: Expected size in bytes, or `nil` if unknown.
  ///   - sha256: Expected SHA-256 hex digest, or `nil` to skip verification.
  public init(relativePath: String, expectedSizeBytes: Int64? = nil, sha256: String? = nil) {
    self.relativePath = relativePath
    self.expectedSizeBytes = expectedSizeBytes
    self.sha256 = sha256
  }
}

/// A declarative description of a downloadable model component.
///
/// Model plugins create `ComponentDescriptor` instances and register them with Acervo.
/// Each descriptor uniquely identifies a component by its `id` and declares the
/// CDN repository, required files, size estimates, and arbitrary metadata.
///
/// Two descriptors are considered equal if and only if they share the same `id`.
/// This supports deduplication semantics: registering the same component ID twice
/// updates the existing entry rather than creating a duplicate.
// Internal file storage is `[ComponentFile]?`: `nil` = awaiting manifest hydration,
// non-nil (including `[]`) = declared or hydrated. The public `files` property
// returns `[]` for un-hydrated descriptors; callers should check `isHydrated`.
public struct ComponentDescriptor: Sendable, Identifiable {
  /// Unique identifier for this component (e.g., "t5-xxl-encoder-int4").
  public let id: String

  /// The functional role of this component within a pipeline.
  public let type: ComponentType

  /// Human-readable name for display (e.g., "T5-XXL Text Encoder (int4)").
  public let displayName: String

  /// The CDN repository identifier for this component
  /// (e.g., "intrusive-memory/t5-xxl-int4-mlx").
  public let repoId: String

  /// Backing storage: `nil` means the descriptor awaits CDN-manifest hydration.
  private let _files: [ComponentFile]?

  /// The files that comprise this component. Returns `[]` for un-hydrated
  /// descriptors; check `isHydrated` to distinguish from a genuinely empty list.
  public var files: [ComponentFile] { _files ?? [] }

  /// Backing storage for the estimated size (nil when awaiting hydration).
  private let _estimatedSizeBytes: Int64?

  /// Total expected download size in bytes. Returns `0` for un-hydrated descriptors.
  public var estimatedSizeBytes: Int64 { _estimatedSizeBytes ?? 0 }

  /// Minimum RAM needed to load this component into memory.
  public let minimumMemoryBytes: Int64

  /// Model-specific key-value metadata. Well-known keys include "deprecated",
  /// "quantization", and "architecture". Unknown keys are preserved as-is.
  public let metadata: [String: String]

  /// `true` when the descriptor has a populated file list (declared up front
  /// or fetched from the CDN manifest).
  public var isHydrated: Bool { _files != nil }

  /// Inverse of `isHydrated`. Used by the internal auto-hydrate path.
  public var needsHydration: Bool { _files == nil }

  /// Creates a new component descriptor with a declared file list.
  ///
  /// - Parameters:
  ///   - id: Unique identifier for this component.
  ///   - type: The functional role of this component.
  ///   - displayName: Human-readable name for display.
  ///   - repoId: The CDN repository identifier.
  ///   - files: Required files with optional size and checksum metadata.
  ///   - estimatedSizeBytes: Total expected download size in bytes.
  ///   - minimumMemoryBytes: Minimum RAM needed to load this component.
  ///   - metadata: Model-specific key-value pairs. Defaults to empty.
  ///
  /// **Bundle pattern**: When multiple components share a `repoId` (a single CDN
  /// manifest covering many components), every bundle component MUST be registered
  /// using this initializer with an explicit `files:` array. Bundle descriptors
  /// MUST NOT be left un-hydrated; calling `Acervo.hydrateComponent(_:)` on a
  /// bundle descriptor will overwrite `files` with the full manifest, breaking
  /// the per-component file scope (R1). The un-hydrated initializer
  /// `init(id:type:displayName:repoId:minimumMemoryBytes:metadata:)` is correct
  /// only for single-component manifests where all manifest files belong to
  /// exactly one component.
  public init(
    id: String,
    type: ComponentType,
    displayName: String,
    repoId: String,
    files: [ComponentFile],
    estimatedSizeBytes: Int64,
    minimumMemoryBytes: Int64,
    metadata: [String: String] = [:]
  ) {
    self.id = id
    self.type = type
    self.displayName = displayName
    self.repoId = repoId
    self._files = files
    self._estimatedSizeBytes = estimatedSizeBytes
    self.minimumMemoryBytes = minimumMemoryBytes
    self.metadata = metadata
  }

  /// Creates an un-hydrated component descriptor.
  ///
  /// The file list and estimated size are fetched from the CDN manifest on first use.
  public init(
    id: String,
    type: ComponentType,
    displayName: String,
    repoId: String,
    minimumMemoryBytes: Int64,
    metadata: [String: String] = [:]
  ) {
    self.id = id
    self.type = type
    self.displayName = displayName
    self.repoId = repoId
    self._files = nil
    self._estimatedSizeBytes = nil
    self.minimumMemoryBytes = minimumMemoryBytes
    self.metadata = metadata
  }
}

// MARK: - Equatable

extension ComponentDescriptor: Equatable {
  /// Two descriptors are equal if they share the same `id`.
  /// This supports deduplication: re-registering the same ID updates the entry.
  public static func == (lhs: ComponentDescriptor, rhs: ComponentDescriptor) -> Bool {
    lhs.id == rhs.id
  }
}

// MARK: - Hashable

extension ComponentDescriptor: Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}
