#!/bin/sh
set -eu

[ "$CI_XCODEBUILD_ACTION" = "archive" ] || exit 0
[ "$CI_XCODEBUILD_EXIT_CODE" = "0" ] || exit 0
: "${GITHUB_TOKEN:?Set GITHUB_TOKEN as a secret Xcode Cloud environment variable}"

github_api() {
    curl --fail-with-body --silent --show-error \
        --header "Accept: application/vnd.github+json" \
        --header "Authorization: Bearer $GITHUB_TOKEN" \
        --header "X-GitHub-Api-Version: 2026-03-10" \
        "$@"
}

TAG="build-${CI_BUILD_NUMBER}"
API_URL="https://api.github.com/repos/videogorl/ensemble/git"

if github_api --request POST "$API_URL/refs" \
    --data "{\"ref\":\"refs/tags/$TAG\",\"sha\":\"${CI_COMMIT}\"}" >/dev/null 2>&1; then
    echo "Created GitHub tag $TAG"
    exit 0
fi

EXISTING_SHA="$(github_api "$API_URL/ref/tags/$TAG" | plutil -extract object.sha raw -)"
if [ "$EXISTING_SHA" = "$CI_COMMIT" ]; then
    echo "GitHub tag $TAG already points to $CI_COMMIT"
    exit 0
fi

echo "GitHub tag $TAG points to $EXISTING_SHA, expected $CI_COMMIT" >&2
exit 1
