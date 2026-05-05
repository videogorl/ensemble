#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

WORKSPACE="$REPO_ROOT/Ensemble.xcworkspace"
SCHEME="Ensemble"
CONFIGURATION="Release"
BUNDLE_ID="com.videogorl.ensemble"
APP_NAME="Ensemble"
OUTPUT_DIR="${TMPDIR:-/tmp}/ensemble-performance-gate-$(date +%Y%m%d-%H%M%S)"
DERIVED_DATA_PATH=""
DESTINATION="platform=iOS Simulator,name=iPhone 17 Pro"
DEVICE_SELECTOR="iPhone 17 Pro"
PLATFORM="simulator"
SIMULATOR_UDID="booted"
ATTACH_NAME="Ensemble"
FLOW_ARG="root,detail,now-playing,artists,playlists,mini-player,feed-launch,feed-refresh,downloads-queue"
TEMPLATE_ARG="Time Profiler,SwiftUI"
DURATION_OVERRIDE=""
BUILD_APP=1
INSTALL_APP=0
LAUNCH_APP=1
INTERACTIVE=1

TABLE_SCHEMAS=(
  "life-cycle-period"
  "process-info"
  "device-thermal-state-intervals"
  "hang-risks"
  "potential-hangs"
  "runloop-events"
  "gcd-perf-event"
  "region-of-interest"
  "os-signpost"
  "os-log"
  "hitches"
  "hitches-frame-lifetimes"
  "hitches-framewait"
  "hitches-gpu"
  "hitches-renders"
  "hitches-updates"
  "swiftui-updates"
  "swiftui-full-causes"
  "swiftui-causes"
  "swiftui-changes"
  "swiftui-update-groups"
  "SwiftUIFilteredUpdates"
  "time-profile"
  "time-sample"
)

usage() {
  cat <<'EOF'
Usage:
  scripts/capture_performance_gate.sh [options]

Captures the repeatable performance gate flows used by the platform/performance
audit. Each flow writes:
  - traces/<flow>-<template>.trace
  - exports/<flow>-<template>/*.xml
  - metrics/<flow>-<template>.json

Default flows:
  root, detail, now-playing, artists, playlists, mini-player,
  feed-launch, feed-refresh, downloads-queue

Options:
  --output-dir PATH          Output directory. Defaults to /tmp/ensemble-performance-gate-<timestamp>.
  --flows LIST               Comma-separated flow IDs, or "all".
  --templates LIST           Comma-separated xctrace templates. Defaults to "Time Profiler,SwiftUI".
  --duration SECONDS         Override every flow duration.
  --device NAME_OR_UDID      xctrace device selector. Defaults to iPhone 17 Pro simulator.
  --platform simulator|device
                             Select launch/install commands. Defaults to simulator.
  --simulator-udid UDID      simctl target when --platform simulator. Defaults to booted.
  --destination DEST         xcodebuild destination. Defaults to iPhone 17 Pro simulator.
  --bundle-id BUNDLE_ID      App bundle identifier. Defaults to com.videogorl.ensemble.
  --attach NAME_OR_PID       Process name or PID for non-launch flows. Defaults to Ensemble.
  --derived-data PATH        DerivedData path. Defaults to <output>/DerivedData.
  --configuration NAME       Xcode configuration. Defaults to Release.
  --no-build                 Do not build before capture.
  --install                  Install the built app before capture.
  --no-launch                Do not launch/terminate the app from the script.
  --non-interactive          Do not pause for manual flow setup.
  -h, --help                 Show this help.

Examples:
  scripts/capture_performance_gate.sh --platform device \
    --device "Felicity’s iPhone 16 Pro" \
    --destination "id=00008140-00023030117B001C" \
    --flows root,detail,now-playing --templates "Time Profiler,SwiftUI"

  scripts/capture_performance_gate.sh --platform simulator \
    --simulator-udid booted --device "iPhone 17 Pro" --flows feed-launch

Notes:
  - The script records all processes for feed-launch so launch work is not missed.
  - Other flows attach to the app process. Keep the app foregrounded and drive the
    printed steps while the time-limited recording runs.
  - Table exports are best effort because Instruments schemas vary by template,
    OS version, and device. Missing tables are recorded in export-errors.log.
EOF
}

log() {
  echo "[perf-gate] $*"
}

die() {
  echo "[perf-gate] $*" >&2
  exit 1
}

slugify() {
  echo "$1" | tr '[:upper:] ' '[:lower:]-' | tr -cd '[:alnum:]-'
}

flow_duration() {
  if [[ -n "$DURATION_OVERRIDE" ]]; then
    echo "$DURATION_OVERRIDE"
    return
  fi

  case "$1" in
    feed-launch) echo "35" ;;
    downloads-queue) echo "75" ;;
    now-playing|artists|playlists|feed-refresh) echo "55" ;;
    *) echo "45" ;;
  esac
}

flow_steps() {
  case "$1" in
    root)
      echo "Launch to the root shell, switch tabs once, open/close root chrome, and leave playback idle."
      ;;
    detail)
      echo "Open an album or playlist detail, scroll the track list, open the row menu, then navigate back."
      ;;
    now-playing)
      echo "Open Now Playing, switch cards, scrub/seek if possible, toggle lyrics/queue panels, then dismiss."
      ;;
    artists)
      echo "Open Artists, scroll through a large section, open one artist, then return to the list."
      ;;
    playlists)
      echo "Open Playlists, scroll, open a playlist, open row actions, then return."
      ;;
    mini-player)
      echo "Exercise mini-player play/pause, swipe/expand/dismiss, and menu actions while staying in the root shell."
      ;;
    feed-launch)
      echo "The script records all processes and launches the app. Let Feed render from cache, then lightly scroll."
      ;;
    feed-refresh)
      echo "Start on Feed, trigger refresh, keep existing content visible, then scroll while reconciliation runs."
      ;;
    downloads-queue)
      echo "Open Downloads, start or resume queued work if available, background/foreground once, then observe progress."
      ;;
    *)
      echo "Drive the requested app flow while the recording runs."
      ;;
  esac
}

normalize_flows() {
  if [[ "$FLOW_ARG" == "all" ]]; then
    FLOW_ARG="root,detail,now-playing,artists,playlists,mini-player,feed-launch,feed-refresh,downloads-queue"
  fi
}

ensure_tools() {
  command -v xcrun >/dev/null 2>&1 || die "xcrun is required"
  command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild is required"
  command -v python3 >/dev/null 2>&1 || die "python3 is required for JSON metrics"
}

build_app() {
  if [[ "$BUILD_APP" -eq 0 ]]; then
    log "Skipping build"
    return
  fi

  mkdir -p "$DERIVED_DATA_PATH"
  log "Building $SCHEME ($CONFIGURATION) with matching dSYMs"
  xcodebuild \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    DEBUG_INFORMATION_FORMAT=dwarf-with-dsym \
    GCC_GENERATE_DEBUGGING_SYMBOLS=YES \
    build | tee "$OUTPUT_DIR/build.log"
}

find_built_app() {
  find "$DERIVED_DATA_PATH/Build/Products" \
    -name "${APP_NAME}.app" \
    -type d \
    -print 2>/dev/null | sort | tail -n 1 || true
}

find_built_dsym() {
  find "$DERIVED_DATA_PATH/Build/Products" \
    -name "${APP_NAME}.app.dSYM" \
    -type d \
    -print 2>/dev/null | sort | tail -n 1 || true
}

write_symbol_manifest() {
  local app_path="$1"
  local dsym_path="$2"
  local symbols_dir="$OUTPUT_DIR/symbols"
  mkdir -p "$symbols_dir"

  {
    echo "workspace=$WORKSPACE"
    echo "scheme=$SCHEME"
    echo "configuration=$CONFIGURATION"
    echo "destination=$DESTINATION"
    echo "app_path=${app_path:-unavailable}"
    echo "dsym_path=${dsym_path:-unavailable}"
    echo "git_sha=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unavailable)"
    echo "xcode=$(xcodebuild -version 2>/dev/null | tr '\n' ';' || echo unavailable)"
  } >"$symbols_dir/build-metadata.txt"

  if [[ -n "$app_path" && -d "$app_path" ]]; then
    local executable="$app_path/$APP_NAME"
    if [[ -x "$executable" ]]; then
      xcrun dwarfdump --uuid "$executable" >"$symbols_dir/app-uuids.txt" 2>"$symbols_dir/app-uuids.err" || true
    fi
  fi

  if [[ -n "$dsym_path" && -d "$dsym_path" ]]; then
    cp -R "$dsym_path" "$symbols_dir/" 2>/dev/null || true
    xcrun dwarfdump --uuid "$dsym_path" >"$symbols_dir/dsym-uuids.txt" 2>"$symbols_dir/dsym-uuids.err" || true
  else
    cat >"$symbols_dir/symbolication-notes.md" <<EOF
# Symbolication Notes

No matching ${APP_NAME}.app.dSYM was found under:

${DERIVED_DATA_PATH}/Build/Products

Run this script without --no-build, or pass --derived-data pointing at the
profiling build's DerivedData, so xctrace can resolve app symbols against the
same UUIDs captured in the trace.
EOF
  fi
}

install_app_if_requested() {
  local app_path="$1"
  if [[ "$INSTALL_APP" -eq 0 ]]; then
    return
  fi
  [[ -n "$app_path" && -d "$app_path" ]] || die "--install requires a built app"

  case "$PLATFORM" in
    simulator)
      log "Installing app on simulator $SIMULATOR_UDID"
      xcrun simctl install "$SIMULATOR_UDID" "$app_path"
      ;;
    device)
      log "Installing app on device $DEVICE_SELECTOR"
      xcrun devicectl device install app --device "$DEVICE_SELECTOR" "$app_path"
      ;;
    *)
      die "Unsupported platform for install: $PLATFORM"
      ;;
  esac
}

launch_app_for_flow() {
  local flow="$1"
  [[ "$LAUNCH_APP" -eq 1 ]] || return 0

  case "$PLATFORM" in
    simulator)
      if [[ "$flow" == "feed-launch" ]]; then
        xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
      fi
      xcrun simctl launch "$SIMULATOR_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
      ;;
    device)
      if [[ "$flow" == "feed-launch" ]]; then
        xcrun devicectl device process launch --device "$DEVICE_SELECTOR" --terminate-existing "$BUNDLE_ID" >/dev/null 2>&1 || true
      else
        xcrun devicectl device process launch --device "$DEVICE_SELECTOR" "$BUNDLE_ID" >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

latest_run_number() {
  local toc_path="$1"
  local run_number
  run_number="$(grep -o '<run number="[0-9][0-9]*"' "$toc_path" | sed -E 's/.*"([0-9]+)"/\1/' | tail -n 1 || true)"
  if [[ -z "$run_number" ]]; then
    echo "1"
  else
    echo "$run_number"
  fi
}

schema_exists() {
  local toc_path="$1"
  local schema="$2"
  grep -q "schema=\"$schema\"" "$toc_path"
}

export_trace_tables() {
  local trace_path="$1"
  local export_dir="$2"
  local errors_path="$export_dir/export-errors.log"
  mkdir -p "$export_dir"
  : >"$errors_path"

  local toc_path="$export_dir/trace-toc.xml"
  if ! xcrun xctrace export --input "$trace_path" --toc --output "$toc_path" >>"$errors_path" 2>&1; then
    log "TOC export failed for $trace_path; see $errors_path"
    return 0
  fi

  local run_number
  run_number="$(latest_run_number "$toc_path")"
  echo "$run_number" >"$export_dir/run-number.txt"

  local schema
  for schema in "${TABLE_SCHEMAS[@]}"; do
    if ! schema_exists "$toc_path" "$schema"; then
      echo "missing: $schema" >>"$errors_path"
      continue
    fi

    local output_path="$export_dir/${schema}.xml"
    local xpath="/trace-toc/run[@number=\"$run_number\"]/data/table[@schema=\"$schema\"]"
    if xcrun xctrace export --input "$trace_path" --xpath "$xpath" --output "$output_path" >>"$errors_path" 2>&1; then
      continue
    fi

    if [[ -s "$output_path" ]]; then
      echo "kept partial export after non-zero exit: $schema" >>"$errors_path"
    else
      rm -f "$output_path"
      echo "failed: $schema" >>"$errors_path"
    fi
  done
}

write_flow_metrics() {
  local flow="$1"
  local template="$2"
  local trace_path="$3"
  local export_dir="$4"
  local metrics_path="$5"

  python3 - "$flow" "$template" "$trace_path" "$export_dir" "$metrics_path" <<'PY'
import json
import re
import sys
from collections import Counter
from pathlib import Path

flow, template, trace_path, export_dir, metrics_path = sys.argv[1:6]
export_path = Path(export_dir)

row_counts = {}
thermal_states = []
swiftui_hotspots = {}
top_symbol_hits = Counter()
memory_tables = {}

hotspot_patterns = [
    "RootView",
    "MainTabView",
    "TabView",
    "MiniPlayer",
    "MiniPlayerVerticalSwipeModifier",
    "GeometryReader&lt;ModifiedContent&gt;.Child",
    "GeometryReader<ModifiedContent>.Child",
    "MergedEnvironment",
    "ChildEnvironment&lt;( NowPlayingViewModel) -&gt; Void&gt;",
    "ChildEnvironment<( NowPlayingViewModel) -> Void>",
]

symbol_patterns = [
    "RootView",
    "HomeViewModel",
    "HomeHubLoader",
    "HubRepository",
    "BackgroundRefreshCoordinator",
    "NowPlayingViewModel",
    "MiniPlayer",
    "OfflineDownloadService",
    "DownloadQueueCoordinator",
    "DownloadTransferExecutor",
    "PlaylistDropResolver",
    "NativeTrackTable",
    "TrackRow",
]

for xml_path in sorted(export_path.glob("*.xml")):
    try:
        text = xml_path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        continue

    row_counts[xml_path.stem] = text.count("<row>")

    if xml_path.stem == "device-thermal-state-intervals":
        thermal_states.extend(re.findall(r'<thermal-state[^>]*fmt="([^"]+)"', text))

    if "memory" in xml_path.stem.lower() or "allocation" in xml_path.stem.lower():
        memory_tables[xml_path.stem] = row_counts[xml_path.stem]

    if xml_path.stem.startswith("swiftui") or xml_path.stem == "SwiftUIFilteredUpdates":
        for pattern in hotspot_patterns:
            swiftui_hotspots[pattern] = swiftui_hotspots.get(pattern, 0) + text.count(pattern)

    if xml_path.stem in {"time-profile", "time-sample", "gcd-perf-event", "os-signpost", "swiftui-updates", "swiftui-full-causes"}:
        for pattern in symbol_patterns:
            count = text.count(pattern)
            if count:
                top_symbol_hits[pattern] += count

result = {
    "flow": flow,
    "template": template,
    "tracePath": trace_path,
    "exportDirectory": str(export_path),
    "rowCounts": row_counts,
    "thermalStates": sorted(set(thermal_states)),
    "memoryTables": memory_tables,
    "swiftUIHotspots": dict(sorted(swiftui_hotspots.items())),
    "topAppSymbolMentions": [
        {"symbol": symbol, "mentions": count}
        for symbol, count in top_symbol_hits.most_common(20)
    ],
}

Path(metrics_path).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

record_flow_template() {
  local flow="$1"
  local template="$2"
  local duration="$3"
  local template_slug
  template_slug="$(slugify "$template")"
  local trace_path="$OUTPUT_DIR/traces/${flow}-${template_slug}.trace"
  local export_dir="$OUTPUT_DIR/exports/${flow}-${template_slug}"
  local metrics_path="$OUTPUT_DIR/metrics/${flow}-${template_slug}.json"
  local record_log="$OUTPUT_DIR/logs/${flow}-${template_slug}.log"

  log "Recording flow=$flow template='$template' duration=${duration}s"
  echo "[perf-gate] Steps: $(flow_steps "$flow")"

  if [[ "$INTERACTIVE" -eq 1 ]]; then
    read -r -p "[perf-gate] Prepare '$flow', then press Return to start recording." _
  fi

  if [[ "$flow" == "feed-launch" ]]; then
    if [[ "$PLATFORM" == "simulator" && "$LAUNCH_APP" -eq 1 ]]; then
      xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    fi

    xcrun xctrace record \
      --template "$template" \
      --device "$DEVICE_SELECTOR" \
      --time-limit "${duration}s" \
      --output "$trace_path" \
      --all-processes \
      --no-prompt >"$record_log" 2>&1 &
    local record_pid=$!
    sleep 3
    launch_app_for_flow "$flow"
    wait "$record_pid" || {
      log "Recording returned non-zero for $flow/$template; see $record_log"
    }
  else
    launch_app_for_flow "$flow"
    sleep 2
    xcrun xctrace record \
      --template "$template" \
      --device "$DEVICE_SELECTOR" \
      --time-limit "${duration}s" \
      --output "$trace_path" \
      --attach "$ATTACH_NAME" \
      --no-prompt >"$record_log" 2>&1 || {
        log "Recording returned non-zero for $flow/$template; see $record_log"
      }
  fi

  if [[ ! -d "$trace_path" && ! -f "$trace_path" ]]; then
    log "Trace missing for $flow/$template; skipping exports"
    return 0
  fi

  export_trace_tables "$trace_path" "$export_dir"
  write_flow_metrics "$flow" "$template" "$trace_path" "$export_dir" "$metrics_path"
  log "Metrics: $metrics_path"
}

write_manifest() {
  local app_path="$1"
  local dsym_path="$2"
  local manifest="$OUTPUT_DIR/manifest.json"
  python3 - "$manifest" "$REPO_ROOT" "$WORKSPACE" "$SCHEME" "$CONFIGURATION" "$DESTINATION" "$DEVICE_SELECTOR" "$PLATFORM" "$BUNDLE_ID" "$app_path" "$dsym_path" "$FLOW_ARG" "$TEMPLATE_ARG" <<'PY'
import json
import subprocess
import sys
from datetime import datetime, timezone

(
    manifest_path,
    repo_root,
    workspace,
    scheme,
    configuration,
    destination,
    device_selector,
    platform,
    bundle_id,
    app_path,
    dsym_path,
    flows,
    templates,
) = sys.argv[1:14]

def run(args):
    try:
        return subprocess.check_output(args, cwd=repo_root, text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return "unavailable"

payload = {
    "createdAt": datetime.now(timezone.utc).isoformat(),
    "repoRoot": repo_root,
    "gitSha": run(["git", "rev-parse", "HEAD"]),
    "workspace": workspace,
    "scheme": scheme,
    "configuration": configuration,
    "destination": destination,
    "deviceSelector": device_selector,
    "platform": platform,
    "bundleID": bundle_id,
    "appPath": app_path or "unavailable",
    "dsymPath": dsym_path or "unavailable",
    "flows": [item for item in flows.split(",") if item],
    "templates": [item for item in templates.split(",") if item],
    "xcode": run(["xcodebuild", "-version"]),
    "xctraceVersion": run(["xcrun", "xctrace", "version"]),
}

with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --flows)
      FLOW_ARG="${2:-}"
      shift 2
      ;;
    --templates)
      TEMPLATE_ARG="${2:-}"
      shift 2
      ;;
    --duration)
      DURATION_OVERRIDE="${2:-}"
      shift 2
      ;;
    --device)
      DEVICE_SELECTOR="${2:-}"
      shift 2
      ;;
    --platform)
      PLATFORM="${2:-}"
      shift 2
      ;;
    --simulator-udid)
      SIMULATOR_UDID="${2:-}"
      shift 2
      ;;
    --destination)
      DESTINATION="${2:-}"
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"
      shift 2
      ;;
    --attach)
      ATTACH_NAME="${2:-}"
      shift 2
      ;;
    --derived-data)
      DERIVED_DATA_PATH="${2:-}"
      shift 2
      ;;
    --configuration)
      CONFIGURATION="${2:-}"
      shift 2
      ;;
    --no-build)
      BUILD_APP=0
      shift
      ;;
    --install)
      INSTALL_APP=1
      shift
      ;;
    --no-launch)
      LAUNCH_APP=0
      shift
      ;;
    --non-interactive)
      INTERACTIVE=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

case "$PLATFORM" in
  simulator|device) ;;
  *) die "--platform must be simulator or device" ;;
esac

normalize_flows
ensure_tools

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$OUTPUT_DIR/DerivedData}"
mkdir -p "$OUTPUT_DIR/traces" "$OUTPUT_DIR/exports" "$OUTPUT_DIR/metrics" "$OUTPUT_DIR/logs"

log "Output: $OUTPUT_DIR"
build_app

APP_PATH="$(find_built_app)"
DSYM_PATH="$(find_built_dsym)"
write_symbol_manifest "$APP_PATH" "$DSYM_PATH"
install_app_if_requested "$APP_PATH"
write_manifest "$APP_PATH" "$DSYM_PATH"

IFS=',' read -r -a FLOWS <<< "$FLOW_ARG"
IFS=',' read -r -a TEMPLATES <<< "$TEMPLATE_ARG"

for flow in "${FLOWS[@]}"; do
  [[ -n "$flow" ]] || continue
  duration="$(flow_duration "$flow")"
  for template in "${TEMPLATES[@]}"; do
    [[ -n "$template" ]] || continue
    record_flow_template "$flow" "$template" "$duration"
  done
done

log "Complete. Manifest: $OUTPUT_DIR/manifest.json"
