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
      Cloudflare R2, and running a 6-step integrity pipeline (CHECKs 1–6).

      COMMON ENVIRONMENT VARIABLES
        HF_TOKEN                 HuggingFace API token (required for private/gated models)
        R2_ACCESS_KEY_ID         Cloudflare R2 access key (required for upload/ship)
        R2_SECRET_ACCESS_KEY     Cloudflare R2 secret key (required for upload/ship)
        R2_BUCKET                R2 bucket name (default: intrusive-memory-models)
        R2_ENDPOINT              R2 S3-compatible endpoint URL
        R2_PUBLIC_URL            Public CDN base URL for CHECK 5/6 verification
        STAGING_DIR              Override default staging root (/tmp/acervo-staging)

      REQUIRED TOOLS
        aws       AWS CLI v2 — used for S3-compatible R2 uploads (brew install awscli)
        hf        HuggingFace CLI — used for model downloads (brew install huggingface-hub)

      TYPICAL WORKFLOW
        # Download and publish a model in one step:
        acervo ship mlx-community/Qwen2.5-7B-Instruct-4bit

        # Or step by step:
        acervo download mlx-community/Qwen2.5-7B-Instruct-4bit
        acervo upload mlx-community/Qwen2.5-7B-Instruct-4bit /tmp/acervo-staging/mlx-community_Qwen2.5-7B-Instruct-4bit
      """,
    version: acervoVersion,
    subcommands: [
      DownloadCommand.self,
      UploadCommand.self,
      ShipCommand.self,
      ManifestCommand.self,
      VerifyCommand.self,
    ]
  )
}
