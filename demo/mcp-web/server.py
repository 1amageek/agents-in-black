from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import re
import urllib.request
import urllib.error
from html.parser import HTMLParser

PORT = int(os.environ.get('PORT', '9004'))
SERVICE_ID = os.environ.get('AIB_SERVICE_ID', 'mcp-web')

TOOLS = [
    {
        'name': 'fetch_url',
        'description': 'Fetch a URL and return its text content (HTML tags stripped)',
        'inputSchema': {
            'type': 'object',
            'properties': {
                'url': {'type': 'string', 'description': 'The URL to fetch'},
                'max_length': {'type': 'integer', 'description': 'Max characters to return (default 5000)'},
            },
            'required': ['url'],
        },
    },
    {
        'name': 'extract_links',
        'description': 'Fetch a URL and extract all hyperlinks from the page',
        'inputSchema': {
            'type': 'object',
            'properties': {
                'url': {'type': 'string', 'description': 'The URL to fetch'},
                'max_links': {'type': 'integer', 'description': 'Max number of links to return (default 50)'},
            },
            'required': ['url'],
        },
    },
    {
        'name': 'search_page',
        'description': 'Fetch a URL and search for a keyword, returning matching lines',
        'inputSchema': {
            'type': 'object',
            'properties': {
                'url': {'type': 'string', 'description': 'The URL to fetch'},
                'query': {'type': 'string', 'description': 'The keyword or phrase to search for'},
            },
            'required': ['url', 'query'],
        },
    },
]

USER_AGENT = 'AIB-MCP-Web/0.1'


class TextExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self._text = []
        self._skip = False

    def handle_starttag(self, tag, attrs):
        if tag in ('script', 'style', 'noscript'):
            self._skip = True

    def handle_endtag(self, tag):
        if tag in ('script', 'style', 'noscript'):
            self._skip = False
        if tag in ('p', 'br', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'tr'):
            self._text.append('\n')

    def handle_data(self, data):
        if not self._skip:
            self._text.append(data)

    def get_text(self):
        return ''.join(self._text).strip()


class LinkExtractor(HTMLParser):
    def __init__(self, base_url):
        super().__init__()
        self.links = []
        self._base = base_url

    def handle_starttag(self, tag, attrs):
        if tag == 'a':
            for name, value in attrs:
                if name == 'href' and value:
                    if value.startswith('http://') or value.startswith('https://'):
                        self.links.append(value)
                    elif value.startswith('/'):
                        from urllib.parse import urljoin
                        self.links.append(urljoin(self._base, value))


def fetch_html(url):
    req = urllib.request.Request(url, headers={'User-Agent': USER_AGENT})
    resp = urllib.request.urlopen(req, timeout=15)
    charset = resp.headers.get_content_charset() or 'utf-8'
    return resp.read().decode(charset, errors='replace')


def execute_fetch_url(params):
    url = params.get('url', '')
    max_length = int(params.get('max_length', 5000))
    if not url:
        return {'error': 'url is required'}
    html = fetch_html(url)
    extractor = TextExtractor()
    extractor.feed(html)
    text = extractor.get_text()
    truncated = len(text) > max_length
    return {'text': text[:max_length], 'length': len(text), 'truncated': truncated, 'url': url}


def execute_extract_links(params):
    url = params.get('url', '')
    max_links = int(params.get('max_links', 50))
    if not url:
        return {'error': 'url is required'}
    html = fetch_html(url)
    extractor = LinkExtractor(url)
    extractor.feed(html)
    unique = list(dict.fromkeys(extractor.links))
    return {'links': unique[:max_links], 'total': len(unique), 'url': url}


def execute_search_page(params):
    url = params.get('url', '')
    query = params.get('query', '')
    if not url or not query:
        return {'error': 'url and query are required'}
    html = fetch_html(url)
    extractor = TextExtractor()
    extractor.feed(html)
    text = extractor.get_text()
    lines = text.splitlines()
    matches = [line.strip() for line in lines if query.lower() in line.lower()]
    return {'matches': matches[:30], 'match_count': len(matches), 'query': query, 'url': url}


EXECUTORS = {
    'fetch_url': execute_fetch_url,
    'extract_links': execute_extract_links,
    'search_page': execute_search_page,
}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/health/live') or self.path.startswith('/health/ready'):
            self._json_response(200, {'ok': True, 'service': SERVICE_ID})
            return
        if self.path.startswith('/mcp'):
            self._json_response(200, {'tools': TOOLS, 'service': SERVICE_ID})
            return
        self._json_response(200, {'service': SERVICE_ID, 'path': self.path, 'method': 'GET'})

    def do_POST(self):
        length = int(self.headers.get('content-length', '0'))
        raw = self.rfile.read(length) if length else b'{}'
        body = json.loads(raw.decode(errors='replace')) if raw else {}

        if self.path.startswith('/mcp'):
            tool_name = body.get('tool', '')
            executor = EXECUTORS.get(tool_name)
            if not executor:
                self._json_response(400, {
                    'error': f'Unknown tool: {tool_name}',
                    'available': [t['name'] for t in TOOLS],
                })
                return
            try:
                result = executor(body.get('params', {}))
                self._json_response(200, result)
            except urllib.error.URLError as e:
                self._json_response(502, {'error': f'Fetch failed: {e}'})
            except Exception as e:
                self._json_response(500, {'error': str(e)})
            return

        self._json_response(200, {'service': SERVICE_ID, 'path': self.path, 'method': 'POST', 'body': body})

    def _json_response(self, status, data):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(data, ensure_ascii=False).encode())

    def log_message(self, fmt, *args):
        msg = fmt % args
        if '/health/live' in msg or '/health/ready' in msg:
            return
        print(f'mcp-web {self.address_string()} - ' + msg)


if __name__ == '__main__':
    print(f'mcp-web listening on {PORT}')
    server = ThreadingHTTPServer(('127.0.0.1', PORT), Handler)
    server.serve_forever()
