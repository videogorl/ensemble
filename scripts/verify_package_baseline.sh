#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

echo "[baseline] Recompiling Core Data model snapshot"
"$SCRIPT_DIR/compile_coredata_model.sh"

declare -a PACKAGES=(
  "Packages/EnsemblePersistence"
  "Packages/EnsembleCore"
  "Packages/EnsembleAPI"
  "Packages/EnsembleUI"
)

declare -a FAILURES=()
LOG_DIR="${TMPDIR:-/tmp}/ensemble-package-baseline"

rm -rf "$LOG_DIR"
mkdir -p "$LOG_DIR"

for package_path in "${PACKAGES[@]}"; do
  echo
  echo "[baseline] swift test --package-path $package_path"
  package_name="$(basename "$package_path")"
  log_path="$LOG_DIR/${package_name}.log"

  if swift test --package-path "$package_path" 2>&1 | tee "$log_path"; then
    continue
  fi

  echo "[baseline] First attempt failed for $package_path; retrying once"
  if swift test --package-path "$package_path" 2>&1 | tee "$log_path"; then
    echo "[baseline] Retry passed for $package_path"
    continue
  fi

  echo "[baseline] Final failure for $package_path; see $log_path"
  FAILURES+=("$package_path")
done

echo
if [[ ${#FAILURES[@]} -eq 0 ]]; then
  echo "[baseline] All package test suites passed"
  exit 0
fi

echo "[baseline] Failing package suites:"
for package_path in "${FAILURES[@]}"; do
  echo "  - $package_path"
done
exit 1
