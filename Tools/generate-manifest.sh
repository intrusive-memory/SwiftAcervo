#!/bin/bash
# generate-manifest.sh
#
# Generates a manifest.json for a model directory.
#
# Usage:
#   ./Tools/generate-manifest.sh <model-id> <directory>
#
# Example:
#   ./Tools/generate-manifest.sh "mlx-community/Qwen2.5-7B-Instruct-4bit" ./models/mlx-community_Qwen2.5-7B-Instruct-4bit
#
# Output:
#   Writes manifest.json to the model directory.
#
# Requirements:
#   - macOS (uses shasum, python3 for JSON)
#   - All model files must already be present in the directory

set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: $0 <model-id> <directory>"
    echo "  model-id:  org/repo format (e.g., mlx-community/Qwen2.5-7B-Instruct-4bit)"
    echo "  directory:  path to the model files"
    exit 1
fi

MODEL_ID="$1"
MODEL_DIR="$2"

# Validate model ID format
if [[ ! "$MODEL_ID" =~ ^[^/]+/[^/]+$ ]]; then
    echo "Error: model-id must be in org/repo format (got: $MODEL_ID)"
    exit 1
fi

# Validate directory exists
if [ ! -d "$MODEL_DIR" ]; then
    echo "Error: directory does not exist: $MODEL_DIR"
    exit 1
fi

# Compute slug
SLUG="${MODEL_ID//\//_}"

# Compute current timestamp
UPDATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "Generating manifest for: $MODEL_ID"
echo "  Slug: $SLUG"
echo "  Directory: $MODEL_DIR"
echo ""

# Collect file entries (exclude manifest.json itself and hidden files)
FILE_ENTRIES=""
ALL_CHECKSUMS=""

while IFS= read -r -d '' filepath; do
    # Get relative path
    relpath="${filepath#$MODEL_DIR/}"

    # Skip manifest.json and hidden files
    if [ "$relpath" = "manifest.json" ] || [[ "$relpath" == .* ]]; then
        continue
    fi

    # Compute SHA-256
    sha256=$(shasum -a 256 "$filepath" | awk '{print $1}')

    # Get file size
    size_bytes=$(stat -f%z "$filepath")

    echo "  $relpath: $sha256 ($size_bytes bytes)"

    # Build JSON entry
    if [ -n "$FILE_ENTRIES" ]; then
        FILE_ENTRIES="$FILE_ENTRIES,"
    fi
    FILE_ENTRIES="$FILE_ENTRIES
    {\"path\": \"$relpath\", \"sha256\": \"$sha256\", \"sizeBytes\": $size_bytes}"

    # Collect checksums for manifest checksum computation
    if [ -n "$ALL_CHECKSUMS" ]; then
        ALL_CHECKSUMS="$ALL_CHECKSUMS\n$sha256"
    else
        ALL_CHECKSUMS="$sha256"
    fi
done < <(find "$MODEL_DIR" -type f -print0 | sort -z)

# Compute manifest checksum: sort checksums, concatenate, SHA-256
MANIFEST_CHECKSUM=$(echo -e "$ALL_CHECKSUMS" | sort | tr -d '\n' | shasum -a 256 | awk '{print $1}')

echo ""
echo "  Manifest checksum: $MANIFEST_CHECKSUM"

# Write manifest.json using python3 for proper JSON formatting
python3 -c "
import json, sys

manifest = {
    'manifestVersion': 1,
    'modelId': '$MODEL_ID',
    'slug': '$SLUG',
    'updatedAt': '$UPDATED_AT',
    'files': json.loads('[$FILE_ENTRIES]'),
    'manifestChecksum': '$MANIFEST_CHECKSUM'
}

with open('$MODEL_DIR/manifest.json', 'w') as f:
    json.dump(manifest, f, indent=2)
    f.write('\n')

print(f'  Wrote: $MODEL_DIR/manifest.json')
print(f'  Files: {len(manifest[\"files\"])}')
"

echo ""
echo "Done. Upload with:"
echo "  rclone copy $MODEL_DIR r2:your-bucket/models/$SLUG/ --progress"
