#!/bin/sh
set -eu

# Writes CFBundleVersion for the current built product Info.plist.
# Format: YYYYMMDD-HHMM-<shortCommit>-<dailyCount>
#
# When both the app and Siri extension are built in one invocation, the
# extension allocates the daily counter and the app reuses the same value
# so both bundles stay aligned.

TZ_REGION="America/Los_Angeles"
DAY="$(TZ="$TZ_REGION" date +"%Y%m%d")"
HHMM="$(TZ="$TZ_REGION" date +"%H%M")"
COMMIT="$(git -C "$SRCROOT" rev-parse --short=6 HEAD 2>/dev/null || echo "nogit00")"

PLIST_PATH="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [ ! -f "$PLIST_PATH" ]; then
  exit 0
fi

STATE_DIR="${BUILD_DIR}/EnsembleBuildNumberState"
COUNTER_FILE="${STATE_DIR}/${DAY}.count"
CURRENT_FILE="${STATE_DIR}/current.txt"
LOCK_DIR="${STATE_DIR}/lock"

mkdir -p "$STATE_DIR"

acquire_lock() {
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    sleep 0.05
  done
  trap 'rmdir "$LOCK_DIR"' EXIT INT TERM
}

allocate_build_number() {
  count=0
  if [ -f "$COUNTER_FILE" ]; then
    count="$(cat "$COUNTER_FILE")"
  fi
  count=$((count + 1))
  printf "%s\n" "$count" > "$COUNTER_FILE"

  BUILD_NUMBER="${DAY}-${HHMM}-${COMMIT}-${count}"
  printf "%s|%s|%s\n" "$DAY" "$COMMIT" "$BUILD_NUMBER" > "$CURRENT_FILE"
}

reuse_or_allocate_build_number() {
  if [ -f "$CURRENT_FILE" ]; then
    IFS='|' read -r stored_day stored_commit stored_number < "$CURRENT_FILE"
    if [ "$stored_day" = "$DAY" ] && [ "$stored_commit" = "$COMMIT" ] && [ -n "$stored_number" ]; then
      BUILD_NUMBER="$stored_number"
      return
    fi
  fi

  allocate_build_number
}

acquire_lock

if [ "$TARGET_NAME" = "EnsembleSiriIntentsExtension" ]; then
  allocate_build_number
else
  reuse_or_allocate_build_number
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST_PATH"
echo "Set CFBundleVersion=$BUILD_NUMBER for target $TARGET_NAME"
