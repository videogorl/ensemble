import json, statistics, sys, xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path
root=Path(sys.argv[1])
results=json.loads((root/'results.json').read_text())
start=datetime.fromisoformat(ET.parse(root/'toc2.xml').findtext('.//start-date')).timestamp()
tree=ET.parse(root/'power.xml'); ids={e.get('id'):e for e in tree.iter() if e.get('id')}
values=set()
for row in tree.findall('.//row'):
 r=[ids[e.get('ref')] if e.get('ref') else e for e in row]
 if r[2].get('fmt','').startswith('Ensemble (') and r[4].tag!='sentinel':
  values.add((float(r[0].text)/1e9,float(r[1].text)/1e9,float(r[4].text)))
output={}
for variant in ['custom','native']:
 phases=[]
 for round in range(3):
  rows=[r for r in results if r.get('variant')==variant and r.get('round')==str(round)]
  a=float(rows[0]['start'])-start; duration=max(float(r['seconds']) for r in rows);b=a+duration
  energy=coverage=0
  for t,d,v in values:
   overlap=max(0,min(t+d,b)-max(t,a));energy+=v*overlap;coverage+=overlap
  phases.append(dict(seconds=duration,cpu_impact_mean=energy/coverage if coverage else None,cpu_impact_integral=energy,coverage_seconds=coverage))
 output[variant]={'phases':phases,'median_seconds':statistics.median(p['seconds'] for p in phases)}
print(json.dumps(output,indent=2));(root/'summary.json').write_text(json.dumps(output,indent=2)+'\n')
