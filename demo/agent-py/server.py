from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import urllib.request
import urllib.error

PORT = int(os.environ.get('PORT', '9001'))
SERVICE_ID = os.environ.get('AIB_SERVICE_ID', 'agent-py')


def load_mcp_servers():
    connections_file = os.environ.get('AIB_CONNECTIONS_FILE', '')
    if not connections_file:
        return []
    with open(connections_file, 'r') as f:
        data = json.load(f)
    return data.get('mcp_servers', [])


MCP_SERVERS = load_mcp_servers()


def _mcp_get(url, timeout=10):
    resp = urllib.request.urlopen(urllib.request.Request(url), timeout=timeout)
    return json.loads(resp.read().decode())


def _mcp_post(url, payload, timeout=15):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers={'Content-Type': 'application/json'})
    resp = urllib.request.urlopen(req, timeout=timeout)
    return json.loads(resp.read().decode())


def build_tool_index():
    """Fetch tool listings from all MCP servers and build name -> server mapping."""
    index = {}
    all_tools = []
    for server in MCP_SERVERS:
        ref = server.get('service_ref', server.get('resolved_url', ''))
        try:
            listing = _mcp_get(server['resolved_url'])
            for tool in listing.get('tools', []):
                name = tool['name']
                index[name] = server['resolved_url']
                all_tools.append({**tool, 'mcp_server': ref})
        except Exception as e:
            print(f'Warning: failed to list tools from {ref}: {e}')
    return index, all_tools


def call_mcp_tool(tool_name, params):
    if not MCP_SERVERS:
        return {'error': 'No MCP servers configured'}
    index, _ = build_tool_index()
    url = index.get(tool_name)
    if not url:
        return {'error': f'Unknown tool: {tool_name}', 'available': list(index.keys())}
    try:
        return _mcp_post(url, {'tool': tool_name, 'params': params})
    except urllib.error.URLError as e:
        return {'error': f'MCP call failed: {e}'}


def list_all_tools():
    if not MCP_SERVERS:
        return {'tools': [], 'error': 'No MCP servers configured'}
    _, all_tools = build_tool_index()
    return {'tools': all_tools, 'server_count': len(MCP_SERVERS)}


def handle_chat(message):
    msg_lower = message.lower()

    # calculate
    if any(kw in msg_lower for kw in ['calculate', 'calc']) or any(op in message for op in ['+', '*', '/']):
        expression = message
        for prefix in ['calculate ', 'calc ']:
            if msg_lower.startswith(prefix):
                expression = message[len(prefix):]
                break
        result = call_mcp_tool('calculate', {'expression': expression.strip()})
        return {'body': f'Result: {json.dumps(result)}', 'tool_used': 'calculate'}

    # time
    if 'time' in msg_lower and 'fetch' not in msg_lower:
        fmt = 'readable'
        if 'iso' in msg_lower:
            fmt = 'iso'
        elif 'unix' in msg_lower:
            fmt = 'unix'
        result = call_mcp_tool('current_time', {'format': fmt})
        return {'body': f'Current time: {json.dumps(result)}', 'tool_used': 'current_time'}

    # transform
    if any(kw in msg_lower for kw in ['transform', 'upper', 'lower', 'reverse']):
        op = 'uppercase'
        for candidate in ['uppercase', 'lowercase', 'reverse', 'word_count']:
            if candidate in msg_lower or candidate[:5] in msg_lower:
                op = candidate
                break
        text = message
        for prefix in ['transform ' + op + ' ', op + ' ']:
            if msg_lower.startswith(prefix):
                text = message[len(prefix):]
                break
        result = call_mcp_tool('transform_text', {'text': text.strip(), 'operation': op})
        return {'body': f'Transform: {json.dumps(result)}', 'tool_used': 'transform_text'}

    # fetch url
    if any(kw in msg_lower for kw in ['fetch', 'get page', 'read url', 'open url']):
        import re
        urls = re.findall(r'https?://\S+', message)
        if urls:
            result = call_mcp_tool('fetch_url', {'url': urls[0], 'max_length': '3000'})
            return {'body': f'Fetched: {json.dumps(result, ensure_ascii=False)[:2000]}', 'tool_used': 'fetch_url'}
        return {'body': 'Please provide a URL to fetch.'}

    # extract links
    if any(kw in msg_lower for kw in ['links', 'extract links']):
        import re
        urls = re.findall(r'https?://\S+', message)
        if urls:
            result = call_mcp_tool('extract_links', {'url': urls[0]})
            return {'body': f'Links: {json.dumps(result, ensure_ascii=False)[:2000]}', 'tool_used': 'extract_links'}
        return {'body': 'Please provide a URL to extract links from.'}

    # search page
    if 'search' in msg_lower and 'http' in msg_lower:
        import re
        urls = re.findall(r'https?://\S+', message)
        if urls:
            query = msg_lower.replace(urls[0].lower(), '').replace('search', '').strip()
            result = call_mcp_tool('search_page', {'url': urls[0], 'query': query})
            return {'body': f'Search: {json.dumps(result, ensure_ascii=False)[:2000]}', 'tool_used': 'search_page'}

    # default: list tools
    tools = list_all_tools()
    tool_names = [t['name'] for t in tools.get('tools', [])]
    return {
        'body': f'Available tools: {tool_names}. '
        'Try: "calculate 2+3", "time", "uppercase hello", '
        '"fetch https://example.com", "links https://example.com"'
    }


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/health/live') or self.path.startswith('/health/ready'):
            self._json_response(200, {'ok': True, 'service': SERVICE_ID})
            return
        if self.path == '/tools':
            self._json_response(200, list_all_tools())
            return
        self._json_response(200, {'service': SERVICE_ID, 'path': self.path, 'method': 'GET'})

    def do_POST(self):
        length = int(self.headers.get('content-length', '0'))
        raw = self.rfile.read(length) if length else b'{}'
        body = json.loads(raw.decode(errors='replace')) if raw else {}

        if self.path == '/':
            message = body.get('message', '')
            self._json_response(200, handle_chat(message))
            return
        if self.path == '/call':
            tool = body.get('tool', '')
            params = body.get('params', {})
            self._json_response(200, call_mcp_tool(tool, params))
            return
        self._json_response(200, {'service': SERVICE_ID, 'path': self.path, 'method': 'POST', 'body': body})

    def _json_response(self, status, data):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(data, ensure_ascii=False).encode())

    def log_message(self, fmt, *args):
        print(f'py-http {self.address_string()} - ' + (fmt % args))


if __name__ == '__main__':
    print(f'agent-py listening on {PORT} (mcp_servers={len(MCP_SERVERS)})')
    server = HTTPServer(('127.0.0.1', PORT), Handler)
    server.serve_forever()
