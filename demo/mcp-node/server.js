const http = require('node:http');

const port = Number(process.env.PORT || 9002);
const serviceId = process.env.AIB_SERVICE_ID || 'mcp-node';

const server = http.createServer((req, res) => {
  if (!req.url) {
    res.statusCode = 400;
    res.end('missing url');
    return;
  }

  if (req.url.startsWith('/health/live') || req.url.startsWith('/health/ready')) {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, service: serviceId }));
    return;
  }

  let body = '';
  req.setEncoding('utf8');
  req.on('data', (chunk) => { body += chunk; });
  req.on('end', () => {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ service: serviceId, method: req.method, path: req.url, body }));
  });
});

server.listen(port, '127.0.0.1', () => {
  console.log(`mcp-node listening on ${port}`);
});
