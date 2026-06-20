import ArgumentParser
import Foundation

@main
struct AcervoCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "acervo",
    abstract: "Download, verify, and mirror AI models to the intrusive-memory CDN.",
    discussion: """
      acervo manages the full lifecycle of AI models for the intrusive-memory CDN:
      downloading from HuggingFace, generating SHA-256 manifests, uploading to
      Cloudflare R2 via the native publish pipeline in SwiftAcervo, and running a
      6-step integrity pipeline (CHECKs 1–6).

      ENVIRONMENT VARIABLES
        HuggingFace
          HF_TOKEN                HuggingFace API token for private/gated models
                                  (or pass --token). Exported to the `hf` CLI.
        Cloudflare R2 / CDN (required for list, upload, ship, recache, delete --cdn)
          R2_ACCESS_KEY_ID        R2 access key id. Required.
          R2_SECRET_ACCESS_KEY    R2 secret access key. Required.
          R2_ENDPOINT             R2 S3-compatible API endpoint (signed writes
                                  and listing). Required.
          R2_PUBLIC_URL           Public CDN base URL (readback CHECK 5/6).
                                  Required.
          R2_BUCKET               Bucket name. Optional; default
                                  intrusive-memory-models.
          R2_REGION               Region literal. Optional; default auto.
        Local paths
          STAGING_DIR             Staging root for download/recache. Optional;
                                  default /tmp/acervo-staging.
          ACERVO_APP_GROUP_ID     App Group id that locates the shared models
                                  directory for cache-scoped operations.
          ACERVO_MODELS_DIR       Absolute override for the shared models
                                  directory (takes precedence over the App Group).
          ACERVO_OFFLINE          When set (e.g. =1), forbid all network access;
                                  serve only what is already on disk.

      REQUIRED TOOLS
        hf        HuggingFace CLI — used for model downloads (brew install huggingface-hub)

      TYPICAL WORKFLOW
        # See what is already on the CDN:
        acervo list

        # Download and publish a model in one step:
        acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit

        # Or step by step:
        acervo download mlx-community/Qwen2.5-7B-Instruct-4bit
        acervo upload mlx-community/Qwen2.5-7B-Instruct-4bit /tmp/acervo-staging/mlx-community_Qwen2.5-7B-Instruct-4bit

        # Re-pull a model from HF and atomically republish (prunes orphans):
        acervo recache mlx-community/Qwen2.5-7B-Instruct-4bit

        # Wipe a model from local cache, staging, and CDN:
        acervo delete mlx-community/Qwen2.5-7B-Instruct-4bit --local --cdn --yes
      """,
    version: acervoVersion,
    subcommands: [
      DownloadCommand.self,
      UploadCommand.self,
      ShipCommand.self,
      ListCommand.self,
      ManifestCommand.self,
      VerifyCommand.self,
      DeleteCommand.self,
      RecacheCommand.self,
    ]
  )
}
