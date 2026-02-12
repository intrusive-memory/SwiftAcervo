// Acervo.swift
// SwiftAcervo
//
// Static API namespace for shared AI model discovery and management.
//
// Acervo ("collection" / "repository" in Portuguese) provides a single
// canonical location for HuggingFace AI models across the intrusive-memory
// ecosystem. All model path resolution, availability checks, discovery,
// download, and migration operations are accessed through static methods
// on this enum.
//
// Usage:
//
//     import SwiftAcervo
//
//     let dir = Acervo.sharedModelsDirectory
//     let available = Acervo.isModelAvailable("mlx-community/Qwen2.5-7B-Instruct-4bit")
//

import Foundation

/// Static API namespace for shared AI model discovery and management.
///
/// `Acervo` is a caseless enum used purely as a namespace. All functionality
/// is provided through static properties and methods. For thread-safe
/// operations with per-model locking, see `AcervoManager`.
public enum Acervo {}
