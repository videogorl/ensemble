#!/bin/sh
set -eu

# Xcode Cloud: Set build number after clone, before build.
# Format matches local script: YYYYMMDD.HHMM.CCCC

TZ_REGION="America/Los_Angeles"
DAY="$(TZ="$TZ_REGION" date +"%Y%m%d")"
HHMM="$(TZ="$TZ_REGION" date +"%H%M")"

# Extract digits only from commit hash (remove hex letters a-f), take first 4
COMMIT="$(git rev-parse HEAD 2>/dev/null | tr -d 'a-f' | cut -c1-4 || echo "0000")"

BUILD_NUMBER="${DAY}.${HHMM}.${COMMIT}"

cd "$CI_PRIMARY_REPOSITORY_PATH"
xcrun agvtool new-version -all "$BUILD_NUMBER"

echo "Xcode Cloud: Set build number to $BUILD_NUMBER"
