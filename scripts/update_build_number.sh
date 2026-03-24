#!/bin/sh
set -eu

# Writes CFBundleVersion for the current built product Info.plist.
# Format: YYYYMMDD.HHMM.CCCC (18 characters max for Xcode)
# CCCC = first 4 digits extracted from commit hash
#
# Uses a stamp file so all targets in the same build get the same number,
# preventing the "CFBundleVersion must match" mismatch warning.

STAMP_FILE="${BUILD_DIR}/.ensemble_build_number"

if [ -f "$STAMP_FILE" ]; then
  BUILD_NUMBER="$(cat "$STAMP_FILE")"
else
  TZ_REGION="America/Los_Angeles"
  DAY="$(TZ="$TZ_REGION" date +"%Y%m%d")"
  HHMM="$(TZ="$TZ_REGION" date +"%H%M")"

  # Extract digits only from commit hash (remove hex letters a-f), take first 4
  COMMIT="$(git -C "$SRCROOT" rev-parse HEAD 2>/dev/null | tr -d 'a-f' | cut -c1-4 || echo "0000")"

  BUILD_NUMBER="${DAY}.${HHMM}.${COMMIT}"
  echo "$BUILD_NUMBER" > "$STAMP_FILE"
fi

PLIST_PATH="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
[ -f "$PLIST_PATH" ] || exit 0

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST_PATH"

# Touch the output marker so Xcode knows the script ran
touch "${PLIST_PATH}.buildnumber"

echo "Set CFBundleVersion=$BUILD_NUMBER for target $TARGET_NAME"
