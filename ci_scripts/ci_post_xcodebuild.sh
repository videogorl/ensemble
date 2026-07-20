#!/bin/sh
set -eu

[ "$CI_XCODEBUILD_ACTION" = "archive" ] || exit 0
[ "$CI_XCODEBUILD_EXIT_CODE" = "0" ] || exit 0
: "${GITHUB_TOKEN:?Set GITHUB_TOKEN as a secret Xcode Cloud environment variable}"

curl --fail-with-body \
    --request POST \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer $GITHUB_TOKEN" \
    --header "X-GitHub-Api-Version: 2026-03-10" \
    "https://api.github.com/repos/videogorl/ensemble/git/refs" \
    --data "{\"ref\":\"refs/tags/build-${CI_BUILD_NUMBER}\",\"sha\":\"${CI_COMMIT}\"}"
