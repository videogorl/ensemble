#!/bin/sh
set -eu

# Xcode Cloud: Set build number as a plain integer (no dots).
# Format: YYYYMMDDHHMM (e.g. 202603240734)

TZ_REGION="America/Los_Angeles"
BUILD_NUMBER="$(TZ="$TZ_REGION" date +"%Y%m%d%H%M")"

cd "$CI_PRIMARY_REPOSITORY_PATH"
xcrun agvtool new-version -all "$BUILD_NUMBER"

echo "Xcode Cloud: Set build number to $BUILD_NUMBER"
