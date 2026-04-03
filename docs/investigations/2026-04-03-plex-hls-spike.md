# PMS Music HLS Spike

Date: 2026-04-03

## Summary
- Tested against live PMS using `scripts/plex_hls_spike.sh`.
- Track used: `ratingKey=10494`.
- `decision` succeeded for both `/music/:/transcode/universal/decision` and `/audio/:/transcode/universal/decision` with `protocol=hls`.
- `start.m3u8` returned `400 Bad Request` for both `music` and `audio`.

## Result
- Verdict: `abstain`

## Rationale
- PMS did not provide a usable HLS manifest for the tested music transcode flow.
- The current app's pain points are still better explained by orchestration and ownership issues than by the transport shape alone.
- Introducing an HLS migration now would add a second playback architecture without evidence that it solves the current failures.

## Reproduction
Run:

```bash
bash scripts/plex_hls_spike.sh
```
