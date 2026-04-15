#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TRACE_ANALYZER="$REPO_ROOT/.claude/skills/trace-analysis/scripts/analyze_trace.py"

usage() {
  cat <<'EOF'
Usage:
  scripts/capture_runtime_baseline.sh [--trace /path/to/run.trace] [--log /path/to/session.log]
  scripts/capture_runtime_baseline.sh --capture-startup [--bundle-id com.videogorl.ensemble] [--udid booted] [--wait-seconds 15] [--output-dir /tmp/ensemble-runtime-baseline]

Modes:
  --trace / --log
      Summarize an existing trace and/or log file.

  --capture-startup
      Cold-launch the installed simulator app, capture an OS log stream, copy the latest
      PersistentLogService session log when available, then print a high-signal summary.

Notes:
  - --capture-startup assumes the app is already installed in the target simulator.
  - Use MCP tools or simctl to install/build first; this script focuses on repeatable capture.
EOF
}

TRACE_PATH=""
LOG_PATH=""
CAPTURE_STARTUP=0
BUNDLE_ID="com.videogorl.ensemble"
UDID="booted"
WAIT_SECONDS=15
OUTPUT_DIR="/tmp/ensemble-runtime-baseline"
LOG_PID=""

cleanup() {
  if [[ -n "$LOG_PID" ]]; then
    kill "$LOG_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

print_log_summary() {
  local label="$1"
  local path="$2"

  [[ -f "$path" ]] || return 0

  echo
  echo "[runtime] ${label}: $path"
  rg -n \
    "Startup sync|health check|foreground|Registry|endpoint changed|ConnectionFailover|downloadsDidChange|Worker exit|PlaybackService|ProgressiveStreamLoader|PersistentLogService|ServerHealthChecker|NowPlayingViewModel|SyncCoordinator" \
    "$path" | sed -n '1,200p' || true
}

capture_startup() {
  mkdir -p "$OUTPUT_DIR"

  local os_log_path="$OUTPUT_DIR/os-log.txt"
  local launch_path="$OUTPUT_DIR/launch.txt"
  local data_container=""
  local logs_dir=""
  local persistent_log_path=""

  echo "[runtime] Capturing simulator startup baseline"
  echo "[runtime] bundle_id=$BUNDLE_ID udid=$UDID wait=${WAIT_SECONDS}s output_dir=$OUTPUT_DIR"

  if ! xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data >/dev/null 2>&1; then
    echo "App is not installed in simulator '$UDID': $BUNDLE_ID" >&2
    exit 1
  fi

  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

  xcrun simctl spawn "$UDID" log stream \
    --level debug \
    --predicate 'processImagePath CONTAINS "Ensemble" AND NOT processImagePath CONTAINS "Extension"' \
    --style compact >"$os_log_path" 2>&1 &
  LOG_PID=$!

  sleep 1
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >"$launch_path" 2>&1
  sleep "$WAIT_SECONDS"

  kill "$LOG_PID" 2>/dev/null || true
  LOG_PID=""

  data_container="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null || true)"
  logs_dir="$data_container/Library/Application Support/Ensemble/Logs"

  if [[ -d "$logs_dir" ]]; then
    persistent_log_path="$(find "$logs_dir" -maxdepth 1 -name 'session-*.log' -print | sort | tail -n 1 || true)"
    if [[ -n "$persistent_log_path" && -f "$persistent_log_path" ]]; then
      cp "$persistent_log_path" "$OUTPUT_DIR/persistent-session.log"
      persistent_log_path="$OUTPUT_DIR/persistent-session.log"
      echo "[runtime] Copied persistent session log to $persistent_log_path"
    fi
  fi

  LOG_PATH="$os_log_path"
  print_log_summary "OS log summary" "$os_log_path"
  if [[ -n "$persistent_log_path" ]]; then
    print_log_summary "Persistent session log summary" "$persistent_log_path"
  else
    echo
    echo "[runtime] No persistent session log found under simulator data container."
  fi
}

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
    --capture-startup)
      CAPTURE_STARTUP=1
      shift
      ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"
      shift 2
      ;;
    --udid)
      UDID="${2:-}"
      shift 2
      ;;
    --wait-seconds)
      WAIT_SECONDS="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
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

if [[ "$CAPTURE_STARTUP" -eq 1 ]]; then
  capture_startup
fi

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
  print_log_summary "Log summary" "$LOG_PATH"
fi
