#!/bin/bash
# upload-model.sh
#
# Downloads a model from HuggingFace, generates a manifest, and uploads
# everything to the Cloudflare R2 CDN.
#
# Usage:
#   ./Tools/upload-model.sh <model-id> [file1 file2 ...]
#
# Examples:
#   # Upload all files for a model:
#   ./Tools/upload-model.sh "mlx-community/Qwen2.5-7B-Instruct-4bit"
#
#   # Upload specific files only:
#   ./Tools/upload-model.sh "mlx-community/Qwen2.5-7B-Instruct-4bit" config.json tokenizer.json model.safetensors
#
# Environment:
#   RCLONE_REMOTE  - rclone remote name (default: "r2")
#   R2_BUCKET      - R2 bucket name (default: "pub-8e049ed02be340cbb18f921765fd24f3")
#   HF_TOKEN       - HuggingFace token for gated models (optional)
#   STAGING_DIR    - Local staging directory (default: /tmp/acervo-staging)
#
# Requirements:
#   - rclone (configured with Cloudflare R2)
#   - huggingface-cli (pip install huggingface-hub)
#   - python3, shasum

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <model-id> [file1 file2 ...]"
    echo ""
    echo "Downloads a model from HuggingFace and uploads it to the CDN."
    echo ""
    echo "Environment variables:"
    echo "  RCLONE_REMOTE  rclone remote name (default: r2)"
    echo "  R2_BUCKET      R2 bucket name"
    echo "  HF_TOKEN       HuggingFace token for gated models"
    echo "  STAGING_DIR    Local staging directory (default: /tmp/acervo-staging)"
    exit 1
fi

MODEL_ID="$1"
shift
SPECIFIC_FILES=("$@")

# Validate model ID
if [[ ! "$MODEL_ID" =~ ^[^/]+/[^/]+$ ]]; then
    echo "Error: model-id must be in org/repo format (got: $MODEL_ID)"
    exit 1
fi

# Configuration
RCLONE_REMOTE="${RCLONE_REMOTE:-r2}"
R2_BUCKET="${R2_BUCKET:-pub-8e049ed02be340cbb18f921765fd24f3}"
STAGING_DIR="${STAGING_DIR:-/tmp/acervo-staging}"
SLUG="${MODEL_ID//\//_}"
MODEL_STAGING="$STAGING_DIR/$SLUG"

echo "=== Acervo CDN Upload ==="
echo "  Model:   $MODEL_ID"
echo "  Slug:    $SLUG"
echo "  Remote:  $RCLONE_REMOTE:$R2_BUCKET/models/$SLUG/"
echo "  Staging: $MODEL_STAGING"
echo ""

# Step 1: Create staging directory
mkdir -p "$MODEL_STAGING"

# Step 2: Download from HuggingFace
echo "--- Step 1: Downloading from HuggingFace ---"

HF_ARGS=""
if [ -n "${HF_TOKEN:-}" ]; then
    HF_ARGS="--token $HF_TOKEN"
fi

if [ ${#SPECIFIC_FILES[@]} -gt 0 ]; then
    # Download specific files
    for file in "${SPECIFIC_FILES[@]}"; do
        echo "  Downloading: $file"
        huggingface-cli download "$MODEL_ID" "$file" \
            --local-dir "$MODEL_STAGING" \
            --local-dir-use-symlinks False \
            $HF_ARGS
    done
else
    # Download all files
    echo "  Downloading all files..."
    huggingface-cli download "$MODEL_ID" \
        --local-dir "$MODEL_STAGING" \
        --local-dir-use-symlinks False \
        $HF_ARGS
fi

# Remove HuggingFace metadata files that we don't need on CDN
rm -rf "$MODEL_STAGING/.cache" "$MODEL_STAGING/.huggingface"

echo ""
echo "--- Step 2: Generating manifest ---"
"$SCRIPT_DIR/generate-manifest.sh" "$MODEL_ID" "$MODEL_STAGING"

echo ""
echo "--- Step 3: Uploading to R2 CDN ---"

# Upload to R2
rclone copy "$MODEL_STAGING" "$RCLONE_REMOTE:$R2_BUCKET/models/$SLUG/" \
    --progress \
    --transfers 4 \
    --checkers 8

echo ""
echo "--- Step 4: Verifying upload ---"

# Verify manifest is accessible
MANIFEST_URL="https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/$SLUG/manifest.json"
echo "  Checking: $MANIFEST_URL"

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$MANIFEST_URL")
if [ "$HTTP_STATUS" = "200" ]; then
    echo "  Manifest accessible (HTTP 200)"
else
    echo "  WARNING: Manifest returned HTTP $HTTP_STATUS"
    echo "  The upload may not have completed. Check rclone configuration."
fi

echo ""
echo "=== Upload complete ==="
echo ""
echo "CDN base: https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/$SLUG/"
echo "Manifest: $MANIFEST_URL"
echo ""
echo "To clean up staging: rm -rf $MODEL_STAGING"
