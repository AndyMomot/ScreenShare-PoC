// Local stand-in for the backend: serves the support page and issues LiveKit access tokens.
// The keys match `livekit-server --dev` (devkey / secret). Never use them outside a local PoC.
import http from 'node:http';
import { readFile, appendFile, mkdir } from 'node:fs/promises';
import crypto from 'node:crypto';

const API_KEY = 'devkey';
const API_SECRET = 'secret';
const PORT = 8080;

// Diagnostics: the app and the page POST their log lines here; one file for the whole test run.
const LOG_FILE = new URL('../logs/poc.log', import.meta.url);
await mkdir(new URL('../logs/', import.meta.url), { recursive: true });
let logChain = Promise.resolve();
function writeLog(source, lines) {
  const text = lines.map((line) => `${new Date().toISOString()} [${source}] ${line}\n`).join('');
  logChain = logChain.then(() => appendFile(LOG_FILE, text)).catch(() => {});
}

const b64url = (value) => Buffer.from(value).toString('base64url');

function accessToken({ identity, name, room }) {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const payload = b64url(JSON.stringify({
    iss: API_KEY,
    sub: identity,
    name,
    nbf: now - 10,
    exp: now + 6 * 3600,
    video: { room, roomJoin: true, canPublish: true, canSubscribe: true, canPublishData: true },
  }));
  const signature = crypto.createHmac('sha256', API_SECRET).update(`${header}.${payload}`).digest('base64url');
  return `${header}.${payload}.${signature}`;
}

http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (req.method === 'OPTIONS') {
    res.writeHead(204, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'Content-Type' }).end();
    return;
  }
  if (url.pathname === '/log' && req.method === 'POST') {
    let body = '';
    for await (const chunk of req) body += chunk;
    try {
      const { source, lines } = JSON.parse(body);
      if (Array.isArray(lines)) writeLog(String(source ?? '?'), lines.map(String));
    } catch { /* ignore malformed batches */ }
    res.writeHead(204, { 'Access-Control-Allow-Origin': '*' }).end();
    return;
  }
  if (url.pathname === '/token') {
    const token = accessToken({
      identity: url.searchParams.get('identity') ?? 'guest',
      name: url.searchParams.get('name') ?? 'Guest',
      room: url.searchParams.get('room') ?? 'demo',
    });
    console.log(`token issued: ${url.searchParams.get('identity')}`);
    writeLog('server', [`token issued: ${url.searchParams.get('identity')} from ${req.socket.remoteAddress}`]);
    res.writeHead(200, { 'Content-Type': 'text/plain', 'Access-Control-Allow-Origin': '*' });
    res.end(token);
    return;
  }
  if (url.pathname === '/' || url.pathname === '/index.html') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(await readFile(new URL('./index.html', import.meta.url)));
    return;
  }
  res.writeHead(404).end();
}).listen(PORT, '0.0.0.0', () => console.log(`support page: http://localhost:${PORT}`));
