// Minimal pwnstamp scenario app. Node core modules only.
//
//   GET /            info page (plain HTML, no JS, no external resources)
//   GET /static/...  files from ./public, read-only
//   GET /api/echo    the parsed URL and query, as JSON
'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { X509Certificate } = require('node:crypto');

const PORT = Number(process.env.PORT || 3000);
const PUBLIC_DIR = path.join(__dirname, 'public');
const PWNSTAMP_DIR = '/run/pwnstamp';

const TYPES = { '.html': 'text/html', '.txt': 'text/plain', '.css': 'text/css', '.json': 'application/json' };

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
}

function osRelease() {
  try {
    const m = fs.readFileSync('/etc/os-release', 'utf8').match(/^PRETTY_NAME="?([^"\n]*)"?$/m);
    return m ? m[1] : 'unknown';
  } catch {
    return 'unknown';
  }
}

// Leaf then intermediate (SPEC §7). Missing outside the platform: the page says so.
function chain(level) {
  try {
    const pem = fs.readFileSync(path.join(PWNSTAMP_DIR, `${level}.chain.pem`), 'utf8');
    const certs = pem.match(/-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/g) || [];
    const [leaf, intermediate] = certs.map((c) => new X509Certificate(c));
    return { leaf, intermediate };
  } catch {
    return null;
  }
}

// The intermediate's CN is `<scenario id>/<epoch>` (SPEC §4).
function scenario(intermediate) {
  if (!intermediate) return 'not on the platform (no /run/pwnstamp)';
  const cn = (intermediate.subject.match(/^CN=(.*)$/m) || [])[1] || intermediate.subject;
  const slash = cn.lastIndexOf('/');
  return slash < 0 ? cn : `${cn.slice(0, slash)} (epoch ${cn.slice(slash + 1)})`;
}

function infoPage() {
  const c = chain('user');
  const rows = [
    ['Scenario', scenario(c && c.intermediate)],
    ['Instance expiry', c && c.leaf ? c.leaf.validTo : '-'],
    ['Runtime', `Node.js ${process.versions.node}`],
    ['OS', osRelease()],
    ['Running as', `uid ${process.getuid()}, gid ${process.getgid()}`],
    ['Levels', `user = uid ${process.getuid()}, root = root of this container; ` +
      'sign with /run/pwnstamp/bin/pwnstamp sign &lt;pseudo&gt;'],
  ];
  const body = rows
    .map(([k, v]) => `<tr><th>${k}</th><td>${k === 'Levels' ? v : escapeHtml(v)}</td></tr>`)
    .join('\n');
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>pwnstamp target</title></head>
<body>
<h1>pwnstamp target</h1>
<table>
${body}
</table>
<p>Reproduce: see the scenario page (image digests, run definition, compose.yaml).<br>
Rules: scope, no egress, shared machine, abuse contact.</p>
</body></html>
`;
}

function send(res, status, type, body) {
  res.writeHead(status, { 'content-type': `${type}; charset=utf-8` });
  res.end(body);
}

function serveStatic(res, pathname) {
  const file = path.join(PUBLIC_DIR, path.normalize(decodeURIComponent(pathname.slice('/static/'.length))));
  if (!file.startsWith(PUBLIC_DIR + path.sep)) return send(res, 404, 'text/plain', 'not found\n');
  fs.readFile(file, (err, data) => {
    if (err) return send(res, 404, 'text/plain', 'not found\n');
    send(res, 200, TYPES[path.extname(file)] || 'application/octet-stream', data);
  });
}

const server = http.createServer((req, res) => {
  let url;
  try {
    url = new URL(req.url, 'http://localhost');
  } catch {
    return send(res, 400, 'text/plain', 'bad request\n');
  }
  if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, 'text/plain', 'method not allowed\n');
  if (url.pathname === '/') return send(res, 200, 'text/html', infoPage());
  if (url.pathname.startsWith('/static/')) {
    try {
      return serveStatic(res, url.pathname);
    } catch {
      return send(res, 400, 'text/plain', 'bad request\n');
    }
  }
  if (url.pathname === '/api/echo') {
    const query = {};
    for (const [k, v] of url.searchParams) (query[k] ||= []).push(v);
    return send(res, 200, 'application/json', JSON.stringify({ path: url.pathname, query }) + '\n');
  }
  send(res, 404, 'text/plain', 'not found\n');
});

server.listen(PORT, () => console.log(`listening on ${PORT}`));
process.on('SIGTERM', () => server.close(() => process.exit(0)));
