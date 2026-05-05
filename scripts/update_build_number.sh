#!/bin/sh
set -eu

# Writes CFBundleVersion for the current built product Info.plist.
# Format: YYYYMMDD.HHMM.CCCC (18 characters max for Xcode)
# CCCC = first 4 digits extracted from commit hash
#
# Uses a stamp file so all targets in the same build get the same number,
# preventing the "CFBundleVersion must match" mismatch warning.

STAMP_FILE="${BUILD_DIR}/.ensemble_build_number"
STAMP_MAX_AGE_SECONDS="${ENSEMBLE_BUILD_NUMBER_STAMP_MAX_AGE_SECONDS:-1800}"

STAMP_IS_FRESH=0
if [ -f "$STAMP_FILE" ]; then
  NOW_SECONDS="$(date +%s)"
  STAMP_SECONDS="$(stat -f %m "$STAMP_FILE" 2>/dev/null || echo 0)"
  STAMP_AGE_SECONDS=$((NOW_SECONDS - STAMP_SECONDS))
  if [ "$STAMP_AGE_SECONDS" -le "$STAMP_MAX_AGE_SECONDS" ]; then
    STAMP_IS_FRESH=1
  fi
fi

if [ "$STAMP_IS_FRESH" -eq 1 ]; then
  BUILD_NUMBER="$(cat "$STAMP_FILE")"
else
  TZ_REGION="America/Los_Angeles"
  DAY="$(TZ="$TZ_REGION" date +"%Y%m%d")"
  HHMM="$(TZ="$TZ_REGION" date +"%H%M")"

  # Extract digits only from commit hash (remove hex letters a-f), take first 4
  COMMIT="$(git -C "$SRCROOT" rev-parse HEAD 2>/dev/null | tr -d 'a-f' | cut -c1-4 || echo "0000")"

  BUILD_NUMBER="${DAY}${HHMM}.${COMMIT}"
  echo "$BUILD_NUMBER" > "$STAMP_FILE"
fi

PLIST_PATH="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
[ -f "$PLIST_PATH" ] || exit 0

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST_PATH"
[ -z "${SCRIPT_OUTPUT_FILE_0:-}" ] || touch "$SCRIPT_OUTPUT_FILE_0"
echo "Set CFBundleVersion=$BUILD_NUMBER for target $TARGET_NAME"
