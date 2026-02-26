from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os

PORT = int(os.environ.get('PORT', '9001'))
SERVICE_ID = os.environ.get('AIB_SERVICE_ID', 'agent-py')

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/health/live') or self.path.startswith('/health/ready'):
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'ok': True, 'service': SERVICE_ID}).encode())
            return
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        body = {'service': SERVICE_ID, 'path': self.path, 'method': 'GET'}
        self.wfile.write(json.dumps(body).encode())

    def do_POST(self):
        length = int(self.headers.get('content-length', '0'))
        payload = self.rfile.read(length) if length else b''
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        body = {'service': SERVICE_ID, 'path': self.path, 'method': 'POST', 'body': payload.decode(errors='replace')}
        self.wfile.write(json.dumps(body).encode())

    def log_message(self, fmt, *args):
        print(f'py-http {self.address_string()} - ' + (fmt % args))

if __name__ == '__main__':
    server = HTTPServer(('127.0.0.1', PORT), Handler)
    print(f'agent-py listening on {PORT}')
    server.serve_forever()
