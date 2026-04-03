#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_ENV="$REPO_ROOT/.env"
FALLBACK_ENV="/Users/felicity/Developer/projects/ensemble/.env"

usage() {
  cat <<'EOF'
Usage: scripts/plex_hls_spike.sh [rating_key]

Attempts a bounded PMS HLS viability check for music universal transcode by:
1. discovering a music-library track when no rating key is provided
2. calling decision for `music` and `audio` transcode types with `protocol=hls`
3. requesting `start.m3u8` and checking for an HLS manifest

Requires PLEX_SERVER_URL and PLEX_ACCESS_TOKEN via env or a .env file.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "${PLEX_SERVER_URL:-}" || -z "${PLEX_ACCESS_TOKEN:-}" ]]; then
  if [[ -f "$DEFAULT_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$DEFAULT_ENV"
  elif [[ -f "$FALLBACK_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$FALLBACK_ENV"
  fi
fi

: "${PLEX_SERVER_URL:?PLEX_SERVER_URL is required}"
: "${PLEX_ACCESS_TOKEN:?PLEX_ACCESS_TOKEN is required}"

CLIENT_ID="ensemble-hls-spike"
SESSION_ID="ensemble-hls-$(date +%s)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

request_json() {
  local path="$1"
  curl -sS -k -G "${PLEX_SERVER_URL}${path}" \
    --data-urlencode "X-Plex-Token=${PLEX_ACCESS_TOKEN}" \
    -H "Accept: application/json"
}

discover_rating_key() {
  local sections_json section_key
  sections_json="$(request_json "/library/sections/all")"
  section_key="$(
    python3 - "$sections_json" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
directories = payload.get("MediaContainer", {}).get("Directory", [])
for directory in directories:
    if directory.get("type") == "artist" and directory.get("hidden", 0) == 0:
        print(f"/library/sections/{directory['key']}")
        break
PY
  )"
  if [[ -z "$section_key" ]]; then
    echo "Could not find a music library section" >&2
    exit 1
  fi

  local track_json
  track_json="$(
    curl -sS -k -G "${PLEX_SERVER_URL}${section_key}/all" \
      --data "type=10" \
      --data "X-Plex-Container-Start=0" \
      --data "X-Plex-Container-Size=1" \
      --data-urlencode "X-Plex-Token=${PLEX_ACCESS_TOKEN}" \
      -H "Accept: application/json"
  )"
  python3 - "$track_json" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
metadata = payload.get("MediaContainer", {}).get("Metadata", [])
if not metadata:
    raise SystemExit("Could not find a track rating key in the selected music library")
print(metadata[0]["ratingKey"])
PY
}

RATING_KEY="${1:-}"
if [[ -z "$RATING_KEY" ]]; then
  RATING_KEY="$(discover_rating_key)"
fi

PROFILE_EXTRA="add-transcode-target-codec(type=musicProfile&context=streaming&protocol=hls&audioCodec=mp3)+add-direct-play-codec(type=musicProfile&context=streaming&audioCodec=aac)+add-direct-play-codec(type=musicProfile&context=streaming&audioCodec=mp3)+add-direct-play-codec(type=musicProfile&context=streaming&audioCodec=flac)+add-direct-play-codec(type=musicProfile&context=streaming&audioCodec=alac)"

check_endpoint() {
  local transcode_type="$1"
  local decision_code start_code manifest_file headers_file

  manifest_file="$TMP_DIR/${transcode_type}.m3u8"
  headers_file="$TMP_DIR/${transcode_type}.headers"

  decision_code="$(
    curl -sS -k -G -o /dev/null -w "%{http_code}" \
      "${PLEX_SERVER_URL}/${transcode_type}/:/transcode/universal/decision" \
      --data-urlencode "path=/library/metadata/${RATING_KEY}" \
      --data "protocol=hls" \
      --data "mediaIndex=0" \
      --data "partIndex=0" \
      --data "directPlay=0" \
      --data "directStream=1" \
      --data "directStreamAudio=1" \
      --data "hasMDE=1" \
      --data "musicBitrate=128" \
      --data "audioBitrate=128" \
      --data-urlencode "session=${SESSION_ID}" \
      --data-urlencode "transcodeSessionId=${SESSION_ID}" \
      --data-urlencode "X-Plex-Token=${PLEX_ACCESS_TOKEN}" \
      --data-urlencode "X-Plex-Client-Identifier=${CLIENT_ID}" \
      --data-urlencode "X-Plex-Session-Identifier=${SESSION_ID}" \
      --data-urlencode "X-Plex-Product=Ensemble" \
      --data-urlencode "X-Plex-Platform=iOS" \
      -H "Accept: application/json" \
      -H "X-Plex-Client-Profile-Extra: ${PROFILE_EXTRA}"
  )"
  start_code="$(
    curl -sS -k -G -D "$headers_file" -o "$manifest_file" -w "%{http_code}" \
      "${PLEX_SERVER_URL}/${transcode_type}/:/transcode/universal/start.m3u8" \
      --data-urlencode "path=/library/metadata/${RATING_KEY}" \
      --data "protocol=hls" \
      --data "mediaIndex=0" \
      --data "partIndex=0" \
      --data "directPlay=0" \
      --data "directStream=1" \
      --data "directStreamAudio=1" \
      --data "hasMDE=1" \
      --data "musicBitrate=128" \
      --data "audioBitrate=128" \
      --data-urlencode "session=${SESSION_ID}" \
      --data-urlencode "transcodeSessionId=${SESSION_ID}" \
      --data-urlencode "X-Plex-Token=${PLEX_ACCESS_TOKEN}" \
      --data-urlencode "X-Plex-Client-Identifier=${CLIENT_ID}" \
      --data-urlencode "X-Plex-Session-Identifier=${SESSION_ID}" \
      --data-urlencode "X-Plex-Product=Ensemble" \
      --data-urlencode "X-Plex-Platform=iOS" \
      -H "Accept: application/vnd.apple.mpegurl" \
      -H "X-Plex-Client-Profile-Extra: ${PROFILE_EXTRA}"
  )"

  echo
  echo "[$transcode_type] decision=$decision_code start=$start_code"
  sed -n '1,8p' "$headers_file"
  echo "[$transcode_type] first lines:"
  sed -n '1,8p' "$manifest_file"

  if [[ "$decision_code" == "200" ]] && [[ "$start_code" == "200" ]] && rg -q '^#EXTM3U' "$manifest_file"; then
    return 0
  fi
  return 1
}

echo "Testing PMS music HLS viability with ratingKey=$RATING_KEY"

music_ok=false
audio_ok=false

if check_endpoint "music"; then
  music_ok=true
fi

if check_endpoint "audio"; then
  audio_ok=true
fi

echo
if [[ "$music_ok" == true || "$audio_ok" == true ]]; then
  echo "VERDICT: adopt in later dedicated phase"
else
  echo "VERDICT: abstain"
fi
