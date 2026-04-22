#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_PATH="$REPO_ROOT/Packages/EnsembleCore"
WARNING_BUDGET="${ENSEMBLE_CORE_WARNING_BUDGET:-0}"
LOG_PATH="${TMPDIR:-/tmp}/ensemble-core-warning-budget.log"

cd "$REPO_ROOT"

echo "[warnings] swift build --package-path $PACKAGE_PATH"
swift build --package-path "$PACKAGE_PATH" 2>&1 | tee "$LOG_PATH"

WARNING_COUNT="$(python3 - "$LOG_PATH" <<'PY'
from pathlib import Path
import sys

log_path = Path(sys.argv[1])
text = log_path.read_text() if log_path.exists() else ""
warnings = [line for line in text.splitlines() if "warning:" in line]
print(len(warnings))
PY
)"

echo "[warnings] Core package warnings: $WARNING_COUNT (budget: $WARNING_BUDGET)"

if [[ "$WARNING_COUNT" -gt "$WARNING_BUDGET" ]]; then
  echo "[warnings] Core warning budget exceeded; see $LOG_PATH" >&2
  exit 1
fi

echo "[warnings] Core warning budget check passed"
