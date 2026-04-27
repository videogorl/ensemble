#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEARCH_PATHS=(
  "$ROOT_DIR/Packages/EnsembleUI/Sources"
  "$ROOT_DIR/EnsembleWatch/Views"
)

count() {
  local label="$1"
  local pattern="$2"
  local value
  value=$(rg -n "$pattern" "${SEARCH_PATHS[@]}" | wc -l | tr -d ' ')
  printf "%-28s %s\n" "$label" "$value"
}

echo "Ensemble design token audit"
echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo
count "Font calls" "\\.font\\(|Font\\.system"
count "Font weight calls" "\\.fontWeight\\(|\\.weight\\("
count "Foreground/tint calls" "\\.foregroundColor\\(|\\.tint\\("
count "Accent references" "Color\\.accentColor|\\.accentColor"
count "Numeric spacing" "spacing: [0-9]"
count "Numeric padding" "padding\\([^)]*[0-9]"
count "Explicit corner radius" "cornerRadius: [0-9]|\\.cornerRadius\\([0-9]|RoundedRectangle\\(cornerRadius: [0-9]"
count "SF Symbol references" "systemName: \\\"|Image\\(systemName:|Label\\("
count "Geometry/breakpoints" "minimumSplitWidth|wideLayoutThreshold|compact.*Width|UIDevice\\.current|horizontalSizeClass|GeometryReader|geometry\\.size\\.width|geometry\\.size\\.height"
count "Effects/materials" "\\.opacity\\([0-9]|\\.shadow\\(|\\.blur\\(|Material|ultraThin|thinMaterial|regularMaterial|LinearGradient|RadialGradient"

echo
echo "Largest screen hotspots:"
rg -n "\\.font\\(|\\.fontWeight\\(|\\.foregroundColor\\(|\\.tint\\(|spacing: [0-9]|padding\\([^)]*[0-9]|cornerRadius: [0-9]|\\.cornerRadius\\([0-9]|RoundedRectangle\\(cornerRadius: [0-9]|systemName: \\\"|Image\\(systemName:|Label\\(|geometry\\.size\\.width|geometry\\.size\\.height|horizontalSizeClass|UIDevice\\.current" \
  "$ROOT_DIR/Packages/EnsembleUI/Sources/Screens" \
  | cut -d: -f1 | sort | uniq -c | sort -nr | head -20

echo
echo "Largest component hotspots:"
rg -n "\\.font\\(|\\.fontWeight\\(|\\.foregroundColor\\(|\\.tint\\(|spacing: [0-9]|padding\\([^)]*[0-9]|cornerRadius: [0-9]|\\.cornerRadius\\([0-9]|RoundedRectangle\\(cornerRadius: [0-9]|systemName: \\\"|Image\\(systemName:|Label\\(|geometry\\.size\\.width|geometry\\.size\\.height|horizontalSizeClass|UIDevice\\.current" \
  "$ROOT_DIR/Packages/EnsembleUI/Sources/Components" \
  | cut -d: -f1 | sort | uniq -c | sort -nr | head -20
