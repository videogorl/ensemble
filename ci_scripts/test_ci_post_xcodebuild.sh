#!/bin/sh
set -eu

curl() {
    case " $* " in
        *" --request POST "*) return 22 ;;
        *) printf '{"object":{"sha":"%s"}}' "$CI_COMMIT" ;;
    esac
}

CI_XCODEBUILD_ACTION=archive
CI_XCODEBUILD_EXIT_CODE=0
CI_BUILD_NUMBER=42
CI_COMMIT=0123456789abcdef0123456789abcdef01234567
GITHUB_TOKEN=test
export CI_XCODEBUILD_ACTION CI_XCODEBUILD_EXIT_CODE CI_BUILD_NUMBER CI_COMMIT GITHUB_TOKEN

. "$(dirname "$0")/ci_post_xcodebuild.sh"
