'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const http = require('node:http');
const net = require('node:net');
const { PassThrough } = require('node:stream');
const test = require('node:test');

const {
  COOKIE_NAME,
  createGuestSessionProxy,
  readOneConfigLine,
} = require('../lib/remote-browser/guest-session-proxy.cjs');

const ORIGIN = 'https://guest.example.test';

function token() {
  return crypto.randomBytes(32).toString('base64url');
}

async function listen(server) {
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return server.address().port;
}

async function closeServer(server) {
  if (!server.listening) return;
  await new Promise((resolve) => server.close(resolve));
}

function request(port, path, options = {}) {
  return new Promise((resolve, reject) => {
    const body = options.body || '';
    const headers = { Host: new URL(ORIGIN).host, ...(options.headers || {}) };
    if (body && headers['Content-Length'] === undefined) headers['Content-Length'] = Buffer.byteLength(body);
    const req = http.request(
      { host: '127.0.0.1', port, path, method: options.method || 'GET', headers },
      (response) => {
        const chunks = [];
        response.on('data', (chunk) => chunks.push(chunk));
        response.on('end', () => resolve({
          status: response.statusCode,
          headers: response.headers,
          body: Buffer.concat(chunks).toString('utf8'),
        }));
      }
    );
    req.on('error', reject);
    req.end(body);
  });
}

function websocketHandshake(port, cookie, origin = ORIGIN) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, '127.0.0.1');
    let data = '';
    socket.once('error', reject);
    socket.on('data', (chunk) => {
      data += chunk.toString('latin1');
      if (data.includes('\r\n\r\n')) resolve({ socket, response: data });
    });
    socket.once('connect', () => {
      socket.write(
        'GET /guest/websockify HTTP/1.1\r\n' +
        'Host: guest.example.test\r\n' +
        'Connection: Upgrade\r\n' +
        'Upgrade: websocket\r\n' +
        'Sec-WebSocket-Version: 13\r\n' +
        `Sec-WebSocket-Key: ${Buffer.alloc(16, 7).toString('base64')}\r\n` +
        `Origin: ${origin}\r\n` +
        (cookie ? `Cookie: ${cookie}\r\n` : '') +
        '\r\n'
      );
    });
  });
}

async function fixture(t, ttlMs = 5_000) {
  const seen = [];
  const upstreamSockets = new Set();
  const upstream = http.createServer((req, res) => {
    seen.push({ url: req.url, headers: req.headers });
    res.writeHead(200, { 'Content-Type': 'text/plain', 'Set-Cookie': 'upstream=bad' });
    res.end(`asset:${req.url}`);
  });
  upstream.on('connection', (socket) => {
    upstreamSockets.add(socket);
    socket.once('close', () => upstreamSockets.delete(socket));
  });
  upstream.on('upgrade', (req, socket) => {
    seen.push({ url: req.url, headers: req.headers, upgrade: true });
    socket.write(
      'HTTP/1.1 101 Switching Protocols\r\n' +
      'Connection: Upgrade\r\n' +
      'Upgrade: websocket\r\n\r\n'
    );
  });
  const upstreamPort = await listen(upstream);
  const linkToken = token();
  const sessionToken = token();
  const events = [];
  const parent = new PassThrough();
  const proxy = createGuestSessionProxy(
    {
      linkToken,
      sessionToken,
      expiresAt: Date.now() + ttlMs,
      publicOrigin: ORIGIN,
      listenHost: '127.0.0.1',
      listenPort: 8444,
      upstreamHost: '127.0.0.2',
      upstreamPort: 6081,
    },
    {
      testOnly: true,
      listenHost: '127.0.0.1',
      listenPort: 0,
      upstreamHost: '127.0.0.1',
      upstreamPort,
      parentStream: parent,
      eventSink: (event) => events.push(event),
    }
  );
  const address = await proxy.start();
  t.after(async () => {
    proxy.close();
    parent.destroy();
    for (const socket of upstreamSockets) socket.destroy();
    await closeServer(upstream);
  });
  return { proxy, port: address.port, linkToken, sessionToken, seen, events, parent };
}

async function redeem(port, linkToken) {
  return request(port, '/guest/redeem', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ token: linkToken }).toString(),
  });
}

test('one concurrent redemption wins without leaking the session secret or token in redirects', async (t) => {
  const f = await fixture(t);
  const landing = await request(f.port, `/guest/?token=${f.linkToken}`);
  assert.equal(landing.status, 200);
  assert.equal(landing.headers['cache-control'], 'no-store');
  assert.equal(landing.headers['referrer-policy'], 'no-referrer');
  assert.match(landing.body, /src="\/guest\/redeem\.js"/);
  assert.match(landing.body, new RegExp(`name="token" value="${f.linkToken}"`));
  assert.doesNotMatch(landing.body, new RegExp(f.sessionToken));

  const [first, second] = await Promise.all([redeem(f.port, f.linkToken), redeem(f.port, f.linkToken)]);
  const results = [first, second];
  assert.equal(results.filter((result) => result.status === 303).length, 1);
  assert.equal(results.filter((result) => result.status === 401).length, 1);
  const winner = results.find((result) => result.status === 303);
  assert.equal(winner.headers.location, '/guest/?autoconnect=1&resize=scale&path=guest/websockify');
  assert.doesNotMatch(winner.headers.location, new RegExp(f.linkToken));
  assert.doesNotMatch(winner.headers.location, new RegExp(f.sessionToken));
  assert.match(winner.headers['set-cookie'][0], new RegExp(`^${COOKIE_NAME}=`));
  assert.match(winner.headers['set-cookie'][0], /Path=\/guest\/; HttpOnly; Secure; SameSite=Strict; Max-Age=/);
  assert.deepEqual(f.events, ['READY', 'REDEEMED']);
  assert.ok(f.events.every((event) => !event.includes(f.linkToken) && !event.includes(f.sessionToken)));

  const reused = await request(f.port, `/guest/?token=${f.linkToken}`);
  assert.equal(reused.status, 401);
});

test('authenticated assets proxy with credentials stripped and ambiguous cookies rejected', async (t) => {
  const f = await fixture(t);
  const redeemed = await redeem(f.port, f.linkToken);
  const cookie = redeemed.headers['set-cookie'][0].split(';', 1)[0];

  const asset = await request(f.port, '/guest/app.js?version=1', {
    headers: {
      Cookie: cookie,
      Authorization: 'Bearer must-not-pass',
      Forwarded: 'for=192.0.2.1',
      'X-Forwarded-For': '192.0.2.1',
    },
  });
  assert.equal(asset.status, 200);
  assert.equal(asset.body, 'asset:/app.js?version=1');
  assert.equal(asset.headers['set-cookie'], undefined);
  assert.equal(f.seen[0].headers.cookie, undefined);
  assert.equal(f.seen[0].headers.authorization, undefined);
  assert.equal(f.seen[0].headers.forwarded, undefined);
  assert.equal(f.seen[0].headers['x-forwarded-for'], undefined);

  assert.equal((await request(f.port, '/guest/app.js')).status, 401);
  assert.equal((await request(f.port, '/guest/app.js', { headers: { Cookie: `${COOKIE_NAME}=forged` } })).status, 401);
  assert.equal((await request(f.port, '/guest/app.js', { headers: { Cookie: `${cookie}; ${cookie}` } })).status, 401);
  assert.equal((await request(f.port, '/guest/app.js', { headers: { Host: 'forged.example.test', Cookie: cookie } })).status, 400);
  assert.equal((await request(f.port, '/mcp', { headers: { Cookie: cookie } })).status, 404);
  assert.equal((await request(f.port, '/login/', { headers: { Cookie: cookie } })).status, 404);
  assert.equal((await request(f.port, '/guest/websockify', { headers: { Cookie: cookie } })).status, 426);
});

test('websocket requires the guest cookie and exact public Origin', async (t) => {
  const f = await fixture(t);
  const redeemed = await redeem(f.port, f.linkToken);
  const cookie = redeemed.headers['set-cookie'][0].split(';', 1)[0];

  const accepted = await websocketHandshake(f.port, cookie);
  assert.match(accepted.response, /^HTTP\/1\.1 101 /);
  accepted.socket.destroy();
  assert.equal(f.seen.at(-1).url, '/websockify');
  assert.equal(f.seen.at(-1).headers.cookie, undefined);

  const wrongOrigin = await websocketHandshake(f.port, cookie, 'https://wrong.example.test');
  assert.match(wrongOrigin.response, /^HTTP\/1\.1 401 /);
  wrongOrigin.socket.destroy();

  const anonymous = await websocketHandshake(f.port, '');
  assert.match(anonymous.response, /^HTTP\/1\.1 401 /);
  anonymous.socket.destroy();
});

test('fixed expiry destroys an already-upgraded socket', async (t) => {
  const f = await fixture(t, 1_200);
  const redeemed = await redeem(f.port, f.linkToken);
  const cookie = redeemed.headers['set-cookie'][0].split(';', 1)[0];
  const upgraded = await websocketHandshake(f.port, cookie);
  assert.match(upgraded.response, /^HTTP\/1\.1 101 /);
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('socket stayed open past expiry')), 2_500);
    upgraded.socket.once('close', () => {
      clearTimeout(timeout);
      resolve();
    });
  });
  assert.deepEqual(f.events, ['READY', 'REDEEMED', 'EXPIRED']);
});

test('closing the parent control pipe shuts down the listener and open sockets', async (t) => {
  const f = await fixture(t);
  const redeemed = await redeem(f.port, f.linkToken);
  const cookie = redeemed.headers['set-cookie'][0].split(';', 1)[0];
  const upgraded = await websocketHandshake(f.port, cookie);

  const closed = new Promise((resolve) => upgraded.socket.once('close', resolve));
  f.parent.end();
  await closed;
  assert.equal(f.proxy.server.listening, false);
  assert.deepEqual(f.events, ['READY', 'REDEEMED']);
});

test('oversize redemption and unsupported methods are rejected', async (t) => {
  const f = await fixture(t);
  const oversized = await request(f.port, '/guest/redeem', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `token=${'a'.repeat(600)}`,
  });
  assert.equal(oversized.status, 413);
  assert.equal((await request(f.port, '/guest/file', { method: 'POST' })).status, 405);
});

test('stdin accepts one bounded config line without consuming the parent control pipe', async () => {
  const input = new PassThrough();
  const parsed = readOneConfigLine(input);
  input.write('{"valid":true}\n');
  assert.deepEqual(await parsed, { valid: true });
  assert.equal(input.readableEnded, false);
  assert.equal(input.readableFlowing, false);
  input.destroy();

  const multiple = new PassThrough();
  const rejected = assert.rejects(readOneConfigLine(multiple), /invalid input/);
  multiple.write('{}\n{}\n');
  await rejected;
  multiple.destroy();

  const oversized = new PassThrough();
  const tooLarge = assert.rejects(readOneConfigLine(oversized), /invalid input/);
  oversized.write('x'.repeat(4_097));
  await tooLarge;
  oversized.destroy();
});

test('production endpoints stay fixed and test overrides remain loopback-only', () => {
  const config = {
    linkToken: token(),
    sessionToken: token(),
    expiresAt: Date.now() + 5_000,
    publicOrigin: ORIGIN,
    listenHost: '127.0.0.1',
    listenPort: 8445,
    upstreamHost: '127.0.0.2',
    upstreamPort: 6081,
  };
  assert.throws(() => createGuestSessionProxy(config), /invalid endpoint/);
  assert.throws(
    () => createGuestSessionProxy(config, {
      testOnly: true,
      listenHost: '0.0.0.0',
      listenPort: 0,
      upstreamHost: '127.0.0.1',
      upstreamPort: 6081,
    }),
    /invalid endpoint/
  );
});
