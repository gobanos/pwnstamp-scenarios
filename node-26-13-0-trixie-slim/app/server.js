// Minimal pwnstamp scenario app. Node core modules only.
//
//   GET /            info page (info.html, no JS, no external resources)
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

const TYPES = {
  '.html': 'text/html', '.txt': 'text/plain', '.css': 'text/css', '.json': 'application/json',
  '.woff2': 'font/woff2',
};

// The info page template, the same in every scenario app (see info.html).
const INFO_TEMPLATE = fs.readFileSync(path.join(__dirname, 'info.html'), 'utf8');

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

// The intermediate's CN is `<scenario id>/<epoch>`, and the id is `<name>@<hash>` (SPEC §4).
function scenario(intermediate) {
  if (!intermediate) return null;
  const cn = (intermediate.subject.match(/^CN=(.*)$/m) || [])[1] || intermediate.subject;
  const slash = cn.lastIndexOf('/');
  const id = slash < 0 ? cn : cn.slice(0, slash);
  const at = id.lastIndexOf('@');
  return { id, name: at < 0 ? id : id.slice(0, at), epoch: slash < 0 ? '-' : cn.slice(slash + 1) };
}

// Scenario pages are published per id by pwnstamp-scenarios (GitHub Pages), next to /rules (an id
// always contains `@`, so it never collides with /rules). The URL is pinned in
// every scenario through this file, so it never changes. `:` and `@` are valid in a path as is.
const SCENARIOS_SITE = 'https://scenarios.pwnstamp.org/';
const SCENARIO_ID = /^[A-Za-z0-9][A-Za-z0-9._\/:-]{0,254}@[A-Za-z0-9_-]{8}$/; // SPEC §2 and §4

function scenarioUrl(s) {
  return s && SCENARIO_ID.test(s.id) ? `${SCENARIOS_SITE}${s.id}/` : SCENARIOS_SITE;
}

function infoPage() {
  const c = chain('user');
  const s = scenario(c && c.intermediate);
  const expiry = c && c.leaf ? new Date(c.leaf.validTo) : null;
  const iso = expiry && !Number.isNaN(expiry.getTime()) ? expiry.toISOString() : null;
  const values = {
    name: s ? s.name : 'not on the platform',
    id: s ? s.id : 'no /run/pwnstamp',
    epoch: s ? s.epoch : '-',
    expiry_time: iso ? iso.slice(11, 16) : '-',
    expiry_date: iso ? iso.slice(0, 10) : '',
    expiry: c && c.leaf ? c.leaf.validTo : '-',
    runtime: `Node.js ${process.versions.node}`,
    os: osRelease(),
    running_as: `uid ${process.getuid()}, gid ${process.getgid()}`,
    uid: String(process.getuid()),
    scenario_url: scenarioUrl(s),
  };
  return INFO_TEMPLATE.replace(/\{\{(\w+)\}\}/g, (_, key) => {
    if (!(key in values)) throw new Error(`info.html: unknown placeholder ${key}`);
    return escapeHtml(values[key]);
  });
}

function send(res, status, type, body) {
  const textual = type.startsWith('text/') || type === 'application/json';
  res.writeHead(status, { 'content-type': textual ? `${type}; charset=utf-8` : type });
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

infoPage(); // a template error fails at startup, not on a request

server.listen(PORT, () => console.log(`listening on ${PORT}`));
process.on('SIGTERM', () => server.close(() => process.exit(0)));
