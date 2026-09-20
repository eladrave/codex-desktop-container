#!/usr/bin/env node
'use strict';

const { spawn } = require('node:child_process');
const crypto = require('node:crypto');
const dns = require('node:dns').promises;
const https = require('node:https');
const tls = require('node:tls');

const BROKER_CLIENT = String.raw`
const net=require('node:net');
const action=process.argv[1];
const socket=net.createConnection({path:'/run/remote-browser/guest-control.sock'});
let body='';
socket.setTimeout(25000,()=>socket.destroy(new Error('timeout')));
socket.on('connect',()=>socket.write(JSON.stringify({action})+'\n'));
socket.on('data',chunk=>body+=chunk);
socket.on('end',()=>process.stdout.write(body));
socket.on('error',()=>process.exit(2));
`;

function usage() {
  return 'Usage: node tests/live-guest-funnel-regression.cjs --container NAME';
}

function parseArgs(argv) {
  if (argv.length !== 2 || argv[0] !== '--container' ||
      !/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/.test(argv[1])) {
    throw new Error('arguments');
  }
  return argv[1];
}

function runDocker(container, args, timeoutMs = 30000) {
  return new Promise((resolve, reject) => {
    const child = spawn('docker', args, {
      stdio: ['ignore', 'pipe', 'ignore'],
      env: { PATH: process.env.PATH || '/usr/local/bin:/usr/bin:/bin' },
    });
    const chunks = [];
    let size = 0;
    const timer = setTimeout(() => child.kill('SIGKILL'), timeoutMs);
    child.stdout.on('data', chunk => {
      size += chunk.length;
      if (size <= 1024 * 1024)
        chunks.push(chunk);
      else
        child.kill('SIGKILL');
    });
    child.on('error', reject);
    child.on('close', code => {
      clearTimeout(timer);
      if (code !== 0 || size > 1024 * 1024) {
        reject(new Error('docker'));
        return;
      }
      resolve(Buffer.concat(chunks).toString('utf8'));
    });
  });
}

async function broker(container, action) {
  const output = await runDocker(container, [
    'exec', '--user', '10001:10001', container,
    'node', '-e', BROKER_CLIENT, action,
  ]);
  return JSON.parse(output);
}

function request(url, address, options = {}, body) {
  return new Promise((resolve, reject) => {
    const request = https.request(url, {
      ...options,
      lookup: (_hostname, lookupOptions, callback) => {
        if (lookupOptions?.all)
          callback(null, [{ address, family: 4 }]);
        else
          callback(null, address, 4);
      },
      timeout: 12000,
    }, response => {
      const chunks = [];
      let size = 0;
      response.on('data', chunk => {
        size += chunk.length;
        if (size <= 4 * 1024 * 1024)
          chunks.push(chunk);
        else
          response.destroy();
      });
      response.on('end', () => resolve({
        status: response.statusCode,
        headers: response.headers,
        body: Buffer.concat(chunks).toString('utf8'),
      }));
      response.on('error', reject);
    });
    request.on('timeout', () => request.destroy(new Error('timeout')));
    request.on('error', reject);
    if (body)
      request.write(body);
    request.end();
  });
}

async function publicAddress(hostname) {
  const resolver = new dns.Resolver();
  resolver.setServers(['8.8.8.8', '1.1.1.1']);
  for (let attempt = 0; attempt < 30; attempt += 1) {
    try {
      const addresses = await resolver.resolve4(hostname);
      if (addresses.length)
        return addresses[0];
    } catch {
      // Funnel DNS can take a short time to become public after first enable.
    }
    await new Promise(resolve => setTimeout(resolve, 1000));
  }
  throw new Error('dns');
}

function websocket(url, address, cookie) {
  return new Promise((resolve, reject) => {
    const socket = tls.connect({
      host: address,
      port: Number(url.port),
      servername: url.hostname,
      rejectUnauthorized: true,
    });
    let response = '';
    socket.setTimeout(12000, () => socket.destroy(new Error('timeout')));
    socket.on('secureConnect', () => {
      socket.write([
        'GET /guest/websockify HTTP/1.1',
        `Host: ${url.host}`,
        'Connection: Upgrade',
        'Upgrade: websocket',
        `Sec-WebSocket-Key: ${crypto.randomBytes(16).toString('base64')}`,
        'Sec-WebSocket-Version: 13',
        'Sec-WebSocket-Protocol: binary',
        `Origin: ${url.origin}`,
        `Cookie: ${cookie}`,
        '', '',
      ].join('\r\n'));
    });
    socket.on('data', chunk => {
      response += chunk.toString('latin1');
      if (!response.includes('\r\n\r\n'))
        return;
      if (!response.startsWith('HTTP/1.1 101')) {
        socket.destroy();
        reject(new Error('upgrade'));
        return;
      }
      socket.setTimeout(0);
      socket.removeAllListeners('data');
      resolve(socket);
    });
    socket.on('error', reject);
  });
}

function waitForClose(socket) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('socket-close')), 8000);
    const done = () => {
      clearTimeout(timer);
      resolve();
    };
    socket.once('close', done);
    socket.once('error', done);
  });
}

async function assertFunnelClosed(container) {
  const output = await runDocker(container, [
    'exec', container, 'tailscale', 'funnel', 'status', '--json',
  ]);
  const status = JSON.parse(output);
  const serialized = JSON.stringify(status);
  if (serialized.includes('8443'))
    throw new Error('cleanup');
}

async function main() {
  const container = parseArgs(process.argv.slice(2));
  let created;
  let stage = 'create';
  try {
    created = await broker(container, 'create');
    if (!created?.ok || created.state !== 'ISSUED')
      throw new Error('create');

    stage = 'validate';
    const guest = new URL(created.guestUrl);
    const token = guest.searchParams.get('token') || '';
    if (guest.protocol !== 'https:' || guest.port !== '8443' ||
        guest.pathname !== '/guest/' ||
        !/^[A-Za-z0-9_-]{43,128}$/.test(token)) {
      throw new Error('validate');
    }
    stage = 'public-dns';
    const address = await publicAddress(guest.hostname);

    stage = 'landing';
    const landing = await request(guest, address);
    if (landing.status !== 200 || !landing.body.includes('/guest/redeem.js') ||
        !landing.body.includes(token)) {
      stage = `landing-${landing.status}-${landing.body.includes('/guest/redeem.js')}-${landing.body.includes(token)}`;
      throw new Error('landing');
    }

    stage = 'redeem';
    const form = `token=${encodeURIComponent(token)}`;
    const redeem = await request(new URL('/guest/redeem', guest), address, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Content-Length': Buffer.byteLength(form),
      },
    }, form);
    if (redeem.status !== 303 ||
        redeem.headers.location !== '/guest/?autoconnect=1&resize=scale&path=guest/websockify') {
      throw new Error('redeem');
    }
    const setCookie = Array.isArray(redeem.headers['set-cookie'])
      ? redeem.headers['set-cookie'][0]
      : redeem.headers['set-cookie'];
    if (!setCookie || !setCookie.includes('HttpOnly') ||
        !setCookie.includes('Secure') || !setCookie.includes('SameSite=Strict')) {
      throw new Error('cookie');
    }
    const cookie = setCookie.split(';', 1)[0];

    stage = 'single-use';
    const reused = await request(new URL('/guest/redeem', guest), address, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Content-Length': Buffer.byteLength(form),
      },
    }, form);
    if (reused.status !== 401)
      throw new Error('single-use');

    stage = 'novnc';
    const page = await request(
      new URL('/guest/?autoconnect=1&resize=scale&path=guest/websockify', guest),
      address,
      { headers: { Cookie: cookie } },
    );
    if (page.status !== 200 || !/noVNC/i.test(page.body))
      throw new Error('novnc');

    stage = 'websocket';
    const socket = await websocket(guest, address, cookie);
    const closed = waitForClose(socket);

    stage = 'revoke';
    const revoked = await broker(container, 'revoke');
    if (!revoked?.ok || revoked.state !== 'CLOSED')
      throw new Error('revoke');
    await closed;

    stage = 'cleanup';
    await assertFunnelClosed(container);
    process.stdout.write(
      'PASS: public guest Funnel, one-use redemption, noVNC, WebSocket, and revocation\n'
    );
  } catch (error) {
    const code = typeof error?.code === 'string' && /^[A-Z0-9_]+$/.test(error.code)
      ? error.code
      : 'ERROR';
    process.stderr.write(`FAIL: public guest regression stage ${stage} (${code})\n`);
    process.exitCode = 1;
  } finally {
    if (created?.ok)
      await broker(container, 'revoke').catch(() => {});
  }
}

void main();
