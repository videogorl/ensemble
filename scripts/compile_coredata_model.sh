#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODEL_SOURCE="$REPO_ROOT/Packages/EnsemblePersistence/Sources/CoreData/Ensemble.xcdatamodeld"
OUTPUT_DIR="$REPO_ROOT/Packages/EnsemblePersistence/Sources/CoreData/Compiled"
OUTPUT_MODEL="$OUTPUT_DIR/Ensemble.momd"

if [[ ! -d "$MODEL_SOURCE" ]]; then
  echo "CoreData model source not found: $MODEL_SOURCE" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_MODEL"

xcrun momc "$MODEL_SOURCE" "$OUTPUT_MODEL"

echo "Compiled CoreData model written to: $OUTPUT_MODEL"
