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

for package_path in "${PACKAGES[@]}"; do
  echo
  echo "[baseline] swift test --package-path $package_path"
  if ! swift test --package-path "$package_path"; then
    FAILURES+=("$package_path")
  fi
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
