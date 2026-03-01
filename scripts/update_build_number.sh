#!/bin/sh
set -eu

# Writes CFBundleVersion for the current built product Info.plist.
# Format: YYYYMMDD.HHMM.CCCC (18 characters max for Xcode)
# CCCC = first 4 digits extracted from commit hash

TZ_REGION="America/Los_Angeles"
DAY="$(TZ="$TZ_REGION" date +"%Y%m%d")"
HHMM="$(TZ="$TZ_REGION" date +"%H%M")"

# Extract digits only from commit hash (remove hex letters a-f), take first 4
COMMIT="$(git -C "$SRCROOT" rev-parse HEAD 2>/dev/null | tr -d 'a-f' | cut -c1-4 || echo "0000")"

PLIST_PATH="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [ ! -f "$PLIST_PATH" ]; then
  exit 0
fi

BUILD_NUMBER="${DAY}.${HHMM}.${COMMIT}"

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST_PATH"
echo "Set CFBundleVersion=$BUILD_NUMBER for target $TARGET_NAME"
