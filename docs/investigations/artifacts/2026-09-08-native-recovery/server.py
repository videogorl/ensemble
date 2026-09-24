from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
import time, hashlib, sys
root=Path(sys.argv[1])
data=bytes(range(256))*32768
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  mode=(root/'mode').read_text().strip()
  offset=int(self.headers.get('Range','bytes=0-').split('=')[1].split('-')[0])
  body=bytes(reversed(data)) if mode=='changed' else data
  resumed=offset>0 and mode not in ['changed','ignore']
  actual=offset+128 if resumed and mode=='malformed' else offset if resumed else 0
  self.send_response(206 if resumed else 200)
  if mode!='no-validator': self.send_header('ETag','"new"' if mode=='changed' else '"original"')
  self.send_header('Accept-Ranges','bytes');self.send_header('Content-Length',str(len(body)-actual))
  if resumed:self.send_header('Content-Range',f'bytes {actual}-{len(body)-1}/{len(body)}')
  self.end_headers()
  print('request',mode,'requested',offset,'sent',actual,flush=True)
  try:
   for start in range(actual,len(body),65536):
    self.wfile.write(body[start:start+65536]); self.wfile.flush(); time.sleep(.01)
  except (BrokenPipeError,ConnectionResetError):pass
print('original',hashlib.sha256(data).hexdigest(),'changed',hashlib.sha256(bytes(reversed(data))).hexdigest(),flush=True)
ThreadingHTTPServer(('127.0.0.1',18769),Handler).serve_forever()
