"""Check a raw instrumented session; exits nonzero for missing PCM or recovery."""
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
assert 'NETWORK_AUDIT begin' in text and 'NETWORK_AUDIT end' in text, 'Incomplete run'
window = text.split('NETWORK_AUDIT begin', 1)[1].split('NETWORK_AUDIT end', 1)[0]
missing = [int(value) for value in re.findall(r'renderMissingFrames=(\d+)', window)]
assert missing, 'No PCM counters; cannot judge streaming quality'
assert max(missing) == 0, f'Starvation reproduced: {max(missing)} missing frames'
assert 'PCM underrun' not in window, 'Underrun reproduced'
assert 'ENGINE: stream interrupted' not in window, 'Stream restart reproduced'
print('PASS: no missing PCM frames or stream recovery in the observed window')
