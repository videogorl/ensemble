#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEARCH_ROOT="$ROOT_DIR/Packages/EnsembleUI/Sources"
RG_FLAGS=(
  --glob '!**/.build/**'
  --glob '!**/EnsembleWatch/**'
)

RAW_PATTERN="\\.font\\(|Font\\.system|\\.fontWeight\\(|\\.weight\\(|\\.foregroundColor\\(|\\.tint\\(|Color\\.accentColor|\\.accentColor|spacing: [0-9]|padding\\([^)]*[0-9]|cornerRadius: [0-9]|\\.cornerRadius\\([0-9]|RoundedRectangle\\(cornerRadius: [0-9]|systemName: \\\"|Image\\(systemName:|Label\\(|minimumSplitWidth|wideLayoutThreshold|compact.*Width|UIDevice\\.current|horizontalSizeClass|GeometryReader|geometry\\.size\\.width|geometry\\.size\\.height|\\.opacity\\([0-9]|\\.shadow\\(|\\.blur\\(|Material|ultraThin|thinMaterial|regularMaterial|LinearGradient|RadialGradient"
TOKEN_PATTERN="EnsembleDesign|EnsembleScaffold|TrackListLayoutMetrics|ArtworkCornerRadius|MediaDetailSurface|MediaActionLabel|ensemble[A-Za-z]*\\(|mediaDetailArtworkShadow\\(|NativeTrackListConfiguration"
TUNED_PATH_PATTERN="/(StageFlow|Aurora|NowPlaying|Screens/NowPlaying)/"

collect() {
  local pattern="$1"
  rg -n "${RG_FLAGS[@]}" "$pattern" "$SEARCH_ROOT" || true
}

count() {
  local label="$1"
  local pattern="$2"
  local value
  value=$(collect "$pattern" | wc -l | tr -d ' ')
  printf "%-28s %s\n" "$label" "$value"
}

count_filtered() {
  local label="$1"
  local pattern="$2"
  local filter="$3"
  local value
  value=$(collect "$pattern" | awk -F: -v filter="$filter" '$1 ~ filter { count++ } END { print count + 0 }')
  printf "%-28s %s\n" "$label" "$value"
}

domain_counts() {
  local title="$1"
  local pattern="$2"

  echo
  echo "$title"
  collect "$pattern" | awk -F: -v root="$SEARCH_ROOT/" '
    {
      path = $1
      sub(root, "", path)
      split(path, parts, "/")
      domain = parts[1]
      if (domain == "Screens" && parts[2] != "") {
        domain = domain "/" parts[2]
      }
      counts[domain]++
    }
    END {
      for (domain in counts) {
        printf "%5d %s\n", counts[domain], domain
      }
    }
  ' | sort -nr
}

hotspots() {
  local title="$1"
  local pattern="$2"

  echo
  echo "$title"
  collect "$pattern" | cut -d: -f1 | sort | uniq -c | sort -nr | head -20
}

echo "Ensemble design token audit"
echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "Scope: Packages/EnsembleUI/Sources"
echo "Excluded: .build, EnsembleWatch"
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
count "Raw literal inventory" "$RAW_PATTERN"
count "Tokenized usage" "$TOKEN_PATTERN"
count_filtered "Tuned literal inventory" "$RAW_PATTERN" "$TUNED_PATH_PATTERN"

domain_counts "Raw literal hits by UI domain:" "$RAW_PATTERN"
domain_counts "Tokenized hits by UI domain:" "$TOKEN_PATTERN"
hotspots "Largest raw literal hotspots:" "$RAW_PATTERN"
