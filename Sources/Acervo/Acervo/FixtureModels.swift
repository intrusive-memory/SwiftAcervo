//
//  FixtureModels.swift
//  Acervo
//
//  Demo fixtures for the SwiftAcervoUI harness. Every slug listed below
//  was verified against the production CDN
//  (https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/<slug>/manifest.json)
//  at the time this file was authored and returned HTTP 200 with a
//  decodable manifest.json. See the mission report for the verify trace.
//
//  Shape (per EXECUTION_PLAN.md / OQ-1):
//    • 2× grouped under FLUX.2 — the only FLUX.2 model currently shipped
//      on the CDN is `black-forest-labs/FLUX.2-klein-4B`, so the second
//      slot is filled by the T5-XXL int4 text encoder that the FLUX.2
//      bundle uses as its text-encoder component (the FLUX-family
//      grouping is "FLUX.2 image stack", not "every row is a FLUX
//      transformer"). This deviation from a strict "2× FLUX checkpoints"
//      reading is documented in the Sortie 2 report.
//    • 1× grouped under PIXART — `pixart-sigma-xl-dit-int4-mlx`.
//    • 1× ungrouped utility — `mlx-community/snac_24khz`, a small audio
//      neural codec (≈79 MB) that exercises the ungrouped path.

import Foundation
import SwiftAcervoUI

enum FixtureModels {

  /// Demo rows passed into the lone `AcervoModelsSection` on the
  /// `ContentView`. Order in this array is the rendering order.
  static let demoFixtures: [AcervoModelRowItem] = [
    AcervoModelRowItem(
      id: "black-forest-labs/FLUX.2-klein-4B",
      displayName: "FLUX.2 klein 4B",
      subtitleLines: [
        "23.7 GB",
        "Requires 24 GB unified memory",
        "~12 s per 1024×1024 image (M2 Ultra)"
      ],
      groupID: "flux2",
      groupDisplayName: "FLUX.2"
    ),
    AcervoModelRowItem(
      id: "intrusive-memory/t5-xxl-int4-mlx",
      displayName: "T5-XXL int4 (text encoder)",
      subtitleLines: [
        "2.94 GB",
        "Requires 4 GB unified memory",
        "Shared text-encoder component"
      ],
      groupID: "flux2",
      groupDisplayName: "FLUX.2"
    ),
    AcervoModelRowItem(
      id: "intrusive-memory/pixart-sigma-xl-dit-int4-mlx",
      displayName: "PixArt-Sigma XL DiT int4",
      subtitleLines: [
        "345 MB",
        "Requires 2 GB unified memory",
        "~5 s per 1024×1024 image"
      ],
      groupID: "pixart",
      groupDisplayName: "PIXART"
    ),
    AcervoModelRowItem(
      id: "mlx-community/snac_24khz",
      displayName: "SNAC 24 kHz neural codec",
      subtitleLines: [
        "79 MB",
        "Requires <1 GB unified memory",
        "Real-time audio tokenizer"
      ],
      groupID: nil,
      groupDisplayName: nil
    )
  ]
}
