"""Minimal mock of GitHub's contents API (GET/PUT with sha concurrency, CORS, bearer auth) for sync tests."""
import json, base64, hashlib, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
TOKEN = 'test-token-0123456789abcdef'; FILES = {}; LOG = []; STATS = {'get200': 0, 'get304': 0, 'put': 0}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def cors(self):
        self.send_header('Access-Control-Allow-Origin', '*'); self.send_header('Access-Control-Allow-Headers', 'Authorization, Accept, Content-Type, X-GitHub-Api-Version')
        self.send_header('Access-Control-Allow-Methods', 'GET, PUT, OPTIONS')
    def reply(self, code, obj, etag=None):
        b = json.dumps(obj).encode(); self.send_response(code); self.cors()
        if etag: self.send_header('ETag', etag)
        self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_OPTIONS(self): self.send_response(204); self.cors(); self.end_headers()
    def path_key(self): return self.path.split('?')[0]
    def authed(self):
        if self.headers.get('Authorization') != 'Bearer ' + TOKEN: self.reply(401, {'message': 'Bad credentials'}); return False
        return True
    def do_GET(self):
        if self.path_key() == '/_dump': return self.reply(200, {'files': {k: base64.b64decode(v['content']).decode() for k, v in FILES.items()}, 'log': LOG, 'stats': STATS})
        if not self.authed(): return
        f = FILES.get(self.path_key())
        if not f: return self.reply(404, {'message': 'Not Found'})
        et = '"' + f['sha'] + '"'
        if self.headers.get('If-None-Match') == et:
            STATS['get304'] += 1; self.send_response(304); self.cors(); self.send_header('ETag', et); self.end_headers(); return
        STATS['get200'] += 1
        c = f['content']; self.reply(200, {'sha': f['sha'], 'content': '\n'.join(c[i:i+60] for i in range(0, len(c), 60)), 'encoding': 'base64'}, et)
    def do_PUT(self):
        if self.path_key() == '/_seed':
            body = json.loads(self.rfile.read(int(self.headers['Content-Length']))); k = body['path']; c = base64.b64encode(body['text'].encode()).decode()
            FILES[k] = {'content': c, 'sha': hashlib.sha1(c.encode()).hexdigest()}; return self.reply(200, {'ok': True})
        if not self.authed(): return
        body = json.loads(self.rfile.read(int(self.headers['Content-Length']))); k = self.path_key(); f = FILES.get(k)
        if f and body.get('sha') != f['sha']: return self.reply(409, {'message': 'sha mismatch'})
        if not f and body.get('sha'): return self.reply(422, {'message': 'sha for missing file'})
        sha = hashlib.sha1(body['content'].encode()).hexdigest(); FILES[k] = {'content': body['content'], 'sha': sha}; LOG.append(body.get('message')); STATS['put'] += 1
        self.reply(201 if not f else 200, {'content': {'sha': sha}})
ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1]) if len(sys.argv) > 1 else 8790), H).serve_forever()
