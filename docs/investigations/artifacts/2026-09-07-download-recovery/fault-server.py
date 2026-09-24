import http.server,urllib.request,urllib.parse,threading,json,time,hashlib,socket
from pathlib import Path
R=Path('/tmp/ensemble-network-audit/download-server');R.mkdir(exist_ok=True)
lock=threading.Lock(); first=None
def event(**kw):
 with lock:
  with (R/'events.jsonl').open('a') as f:f.write(json.dumps({'time':time.time(),**kw})+'\n')
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a):
  with (R/"requests.log").open("a") as f:f.write(str(a)+"\n")
 def do_GET(self):
  global first
  url=urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)['url'][0]
  (R/'last-url.txt').write_text(url)
  key=hashlib.sha256(url.encode()).hexdigest()[:12];p=R/key
  if not p.exists():
   with urllib.request.urlopen(url,timeout=30) as r:
    p.write_bytes(r.read())
  data=p.read_bytes();offset=int(self.headers.get('Range','bytes=0-')[6:-1]);etag='"'+hashlib.sha256(data).hexdigest()+'"'
  with lock:
   fail=first is None
   if fail:first=key
  self.send_response(206 if offset else 200);self.send_header('Content-Length',str(len(data)-offset));self.send_header('ETag',etag);self.send_header('Content-Type','audio/flac')
  if offset:self.send_header('Content-Range',f'bytes {offset}-{len(data)-1}/{len(data)}')
  self.end_headers();sent=0
  try:
   for i in range(offset,len(data),65536):
    b=data[i:i+65536];self.wfile.write(b);self.wfile.flush();sent+=len(b)
    if fail and sent>=262144:
     self.connection.shutdown(socket.SHUT_RDWR);self.connection.close();break
    time.sleep(.015)
  except (BrokenPipeError,ConnectionResetError):pass
  event(key=key,offset=offset,bytes=sent,total=len(data),interrupted=fail,complete=sent==len(data)-offset)
http.server.ThreadingHTTPServer(('127.0.0.1',18768),Handler).serve_forever()
