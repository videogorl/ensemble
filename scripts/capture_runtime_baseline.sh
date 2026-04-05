#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TRACE_ANALYZER="$REPO_ROOT/.claude/skills/trace-analysis/scripts/analyze_trace.py"

usage() {
  cat <<'EOF'
Usage: scripts/capture_runtime_baseline.sh [--trace /path/to/run.trace] [--log /path/to/session.log]

Summarizes a trace via the bundled trace-analysis helper and prints high-signal log lines
for startup, failover, playback, and download-worker activity.
EOF
}

TRACE_PATH=""
LOG_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --trace)
      TRACE_PATH="${2:-}"
      shift 2
      ;;
    --log)
      LOG_PATH="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -n "$TRACE_PATH" ]]; then
  if [[ ! -f "$TRACE_PATH" ]]; then
    echo "Trace not found: $TRACE_PATH" >&2
    exit 1
  fi
  echo "[runtime] Trace summary: $TRACE_PATH"
  python3 "$TRACE_ANALYZER" "$TRACE_PATH" --run latest
fi

if [[ -n "$LOG_PATH" ]]; then
  if [[ ! -f "$LOG_PATH" ]]; then
    echo "Log not found: $LOG_PATH" >&2
    exit 1
  fi
  echo
  echo "[runtime] Log summary: $LOG_PATH"
  rg -n "Startup sync|health check|foreground|Registry|endpoint changed|ConnectionFailover|downloadsDidChange|Worker exit|PlaybackService|ProgressiveStreamLoader" "$LOG_PATH" | sed -n '1,160p'
fi
