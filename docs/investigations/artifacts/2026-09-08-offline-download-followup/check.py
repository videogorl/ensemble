"""Check the captured comparison; does not contact PMS or modify a device."""
import json
from pathlib import Path

root = Path(__file__).parent
runs = json.loads((root / 'queue-events.json').read_text())
for name in ['four-logs', 'parallel-repeat-run-logs', 'native-queue-logs', 'unique-client-logs']:
    assert any(e['event'] == 'transient_failure' for e in runs[name]['events']), name
for name in ['download-flag-logs', 'fixed-resume-logs']:
    events = runs[name]['events']
    assert not any(e['event'] == 'transient_failure' for e in events), name
    assert {e['track'] for e in events if e['event'] == 'stored'} == {'14899', '8778', '14138', '12507'}, name
assert sum('status=206' in e['event'] and 'completed' in e['event'] for e in runs['fixed-resume-logs']['events']) == 2
files = json.loads((root / 'fixed-integrity.json').read_text())
assert len(files) == 4 and all(f['matchesServer'] for f in files)
print('Captured connection-loss, recovery, and file-integrity checks passed.')
