import base64, hashlib, json, plistlib, subprocess, tempfile, sys
from pathlib import Path
r=Path(sys.argv[1]); logs=[]
original=hashlib.sha256(bytes(range(256))*32768).hexdigest()
changed=hashlib.sha256(bytes(reversed(bytes(range(256))*32768))).hexdigest()
for mode in ['normal','changed','ignore','malformed','no-validator','missing-file','invalid-data','corrupt-record']:
 (r/'mode').write_text('no-validator' if mode=='no-validator' else 'normal')
 saved=r/(mode+'.record');url='http://127.0.0.1:18769/'+mode
 a=subprocess.check_output([str(r/'audit-guarded'),'cancel',url,str(saved)],text=True)
 if mode=='missing-file':
  record=json.loads(saved.read_text());d=plistlib.loads(base64.b64decode(record['data']))
  names=[v for v in d['$objects'] if isinstance(v,str) and v.startswith('CFNetworkDownload_')]
  removed=[]
  for name in names:
   for path in Path(tempfile.gettempdir()).rglob(name):path.unlink();removed.append(name)
  assert len(removed)==1,removed
 if mode=='invalid-data':saved.write_bytes(b'invalid')
 if mode=='corrupt-record':
  d=json.loads(saved.read_text());d['data']=base64.b64encode(b'invalid').decode();saved.write_text(json.dumps(d))
 (r/'mode').write_text(mode)
 b=subprocess.check_output([str(r/'audit-guarded'),'resume',url,str(saved)],text=True)
 if mode=='malformed':assert 'rejected malformed range' in b,b
 else:assert (changed if mode=='changed' else original) in b,b
 logs.append(mode+'\n'+a+b);(r/'guarded-results.txt').write_text('\n'.join(logs))
print('\n'.join(logs))
