const http = require('node:http');

const port = Number(process.env.PORT || 9002);
const serviceId = process.env.AIB_SERVICE_ID || 'mcp-node';

const TOOLS = [
  {
    name: 'calculate',
    description: 'Evaluate a simple arithmetic expression (+, -, *, /, parentheses)',
    inputSchema: { type: 'object', properties: { expression: { type: 'string' } }, required: ['expression'] },
  },
  {
    name: 'current_time',
    description: 'Return the current date and time in the requested format (iso, unix, readable)',
    inputSchema: { type: 'object', properties: { format: { type: 'string', enum: ['iso', 'unix', 'readable'] } } },
  },
  {
    name: 'transform_text',
    description: 'Transform text: uppercase, lowercase, reverse, or word_count',
    inputSchema: {
      type: 'object',
      properties: { text: { type: 'string' }, operation: { type: 'string', enum: ['uppercase', 'lowercase', 'reverse', 'word_count'] } },
      required: ['text', 'operation'],
    },
  },
];

function executeCalculate(params) {
  const expr = String(params.expression || '');
  if (!/^[\d\s+\-*/().]+$/.test(expr)) {
    return { error: 'Invalid expression. Only digits, +, -, *, /, (, ) allowed.' };
  }
  try {
    const result = Function('"use strict"; return (' + expr + ')')();
    return { result: Number(result) };
  } catch (e) {
    return { error: 'Evaluation failed: ' + e.message };
  }
}

function executeCurrentTime(params) {
  const now = new Date();
  const fmt = params.format || 'iso';
  switch (fmt) {
    case 'unix': return { result: Math.floor(now.getTime() / 1000) };
    case 'readable': return { result: now.toLocaleString('en-US', { dateStyle: 'full', timeStyle: 'long' }) };
    default: return { result: now.toISOString() };
  }
}

function executeTransformText(params) {
  const text = String(params.text || '');
  switch (params.operation) {
    case 'uppercase': return { result: text.toUpperCase() };
    case 'lowercase': return { result: text.toLowerCase() };
    case 'reverse': return { result: [...text].reverse().join('') };
    case 'word_count': return { result: text.split(/\s+/).filter(Boolean).length };
    default: return { error: 'Unknown operation: ' + params.operation };
  }
}

const executors = { calculate: executeCalculate, current_time: executeCurrentTime, transform_text: executeTransformText };

function readBody(req) {
  return new Promise((resolve) => {
    let body = '';
    req.setEncoding('utf8');
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => resolve(body));
  });
}

const server = http.createServer(async (req, res) => {
  if (req.url.startsWith('/health/live') || req.url.startsWith('/health/ready')) {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, service: serviceId }));
    return;
  }

  if (req.url.startsWith('/mcp')) {
    if (req.method === 'GET') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ tools: TOOLS, service: serviceId }));
      return;
    }
    if (req.method === 'POST') {
      const raw = await readBody(req);
      let parsed;
      try { parsed = JSON.parse(raw); } catch { parsed = {}; }
      const toolName = parsed.tool;
      const executor = executors[toolName];
      if (!executor) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'Unknown tool: ' + toolName, available: TOOLS.map((t) => t.name) }));
        return;
      }
      const result = executor(parsed.params || {});
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(result));
      return;
    }
  }

  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ service: serviceId, method: req.method, path: req.url }));
});

server.listen(port, '127.0.0.1', () => {
  console.log(`mcp-node listening on ${port}`);
});
