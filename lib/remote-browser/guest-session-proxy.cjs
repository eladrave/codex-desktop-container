#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const http = require('node:http');
const { performance } = require('node:perf_hooks');

const PRODUCTION = Object.freeze({
  uid: 10002,
  listenHost: '127.0.0.1',
  listenPort: 8444,
  upstreamHost: '127.0.0.2',
  upstreamPort: 6081,
});
const COOKIE_NAME = 'remote_chrome_guest';
const MAX_CONFIG_BYTES = 4096;
const MAX_REDEEM_BODY_BYTES = 512;
const MAX_TTL_MS = 30 * 60 * 1000;
const TOKEN_RE = /^[A-Za-z0-9_-]{43,128}$/;

function fixedResponse(response, statusCode, body = '') {
  if (response.headersSent) {
    response.destroy();
    return;
  }
  response.writeHead(statusCode, {
    'Cache-Control': 'no-store',
    'Content-Type': 'text/plain; charset=utf-8',
    'Referrer-Policy': 'no-referrer',
    'X-Content-Type-Options': 'nosniff',
  });
  response.end(body);
}

function timingSafeTextEqual(left, right) {
  const leftBuffer = Buffer.from(typeof left === 'string' ? left : '', 'utf8');
  const rightBuffer = Buffer.from(typeof right === 'string' ? right : '', 'utf8');
  if (leftBuffer.length !== rightBuffer.length) return false;
  return crypto.timingSafeEqual(leftBuffer, rightBuffer);
}

function escapeHtmlAttribute(value) {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
}

function rawHeaderCount(request, targetName) {
  let count = 0;
  for (let index = 0; index < request.rawHeaders.length; index += 2) {
    if (request.rawHeaders[index].toLowerCase() === targetName) count += 1;
  }
  return count;
}

function validGuestCookie(request, expectedToken) {
  if (rawHeaderCount(request, 'cookie') !== 1) return false;
  const rawCookie = request.headers.cookie;
  if (typeof rawCookie !== 'string') return false;
  const matches = [];
  for (const part of rawCookie.split(';')) {
    const separator = part.indexOf('=');
    if (separator < 0) continue;
    const name = part.slice(0, separator).trim();
    if (name === COOKIE_NAME) matches.push(part.slice(separator + 1).trim());
  }
  return matches.length === 1 && timingSafeTextEqual(matches[0], expectedToken);
}

function cleanRequestHeaders(request, websocket = false) {
  const blocked = new Set([
    'authorization',
    'cookie',
    'forwarded',
    'host',
    'proxy-authorization',
    'proxy-connection',
    'x-forwarded-for',
    'x-forwarded-host',
    'x-forwarded-port',
    'x-forwarded-proto',
    'x-forwarded-server',
    'x-real-ip',
  ]);
  const connectionTokens = String(request.headers.connection || '')
    .split(',')
    .map((value) => value.trim().toLowerCase())
    .filter(Boolean);
  if (!websocket) {
    blocked.add('content-length');
    blocked.add('connection');
    blocked.add('expect');
    blocked.add('keep-alive');
    blocked.add('te');
    blocked.add('trailer');
    blocked.add('transfer-encoding');
    blocked.add('upgrade');
    for (const token of connectionTokens) blocked.add(token);
  }
  const headers = {};
  for (const [name, value] of Object.entries(request.headers)) {
    if (!blocked.has(name.toLowerCase()) && value !== undefined) headers[name] = value;
  }
  return headers;
}

function cleanResponseHeaders(headers) {
  const blocked = new Set([
    'connection',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'set-cookie',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
  ]);
  const result = {};
  for (const [name, value] of Object.entries(headers)) {
    if (!blocked.has(name.toLowerCase()) && value !== undefined) result[name] = value;
  }
  result['cache-control'] = 'no-store';
  result['referrer-policy'] = 'no-referrer';
  return result;
}

function validateConfig(config, options = {}) {
  if (!config || typeof config !== 'object' || Array.isArray(config)) {
    throw new Error('invalid config');
  }
  const allowedKeys = new Set([
    'expiresAt',
    'linkToken',
    'listenHost',
    'listenPort',
    'publicOrigin',
    'sessionToken',
    'upstreamHost',
    'upstreamPort',
  ]);
  if (Object.keys(config).some((key) => !allowedKeys.has(key))) throw new Error('invalid config');
  if (!TOKEN_RE.test(config.linkToken) || !TOKEN_RE.test(config.sessionToken)) {
    throw new Error('invalid token');
  }
  if (timingSafeTextEqual(config.linkToken, config.sessionToken)) {
    throw new Error('tokens must differ');
  }
  if (!Number.isSafeInteger(config.expiresAt)) throw new Error('invalid expiry');
  const remaining = config.expiresAt - Date.now();
  if (remaining <= 0 || remaining > MAX_TTL_MS) throw new Error('invalid expiry');

  let origin;
  try {
    origin = new URL(config.publicOrigin);
  } catch {
    throw new Error('invalid origin');
  }
  if (
    origin.protocol !== 'https:' ||
    origin.origin !== config.publicOrigin ||
    origin.username ||
    origin.password
  ) {
    throw new Error('invalid origin');
  }

  const endpoint = options.testOnly
    ? {
        listenHost: options.listenHost,
        listenPort: options.listenPort,
        upstreamHost: options.upstreamHost,
        upstreamPort: options.upstreamPort,
      }
    : {
        listenHost: config.listenHost,
        listenPort: config.listenPort,
        upstreamHost: config.upstreamHost,
        upstreamPort: config.upstreamPort,
      };

  const expected = options.testOnly
    ? endpoint
    : {
        listenHost: PRODUCTION.listenHost,
        listenPort: PRODUCTION.listenPort,
        upstreamHost: PRODUCTION.upstreamHost,
        upstreamPort: PRODUCTION.upstreamPort,
      };
  if (
    endpoint.listenHost !== expected.listenHost ||
    endpoint.listenPort !== expected.listenPort ||
    endpoint.upstreamHost !== expected.upstreamHost ||
    endpoint.upstreamPort !== expected.upstreamPort
  ) {
    throw new Error('invalid endpoint');
  }
  if (
    options.testOnly &&
    endpoint.listenHost !== '127.0.0.1' &&
    endpoint.listenHost !== '127.0.0.2' &&
    endpoint.listenHost !== '::1'
  ) {
    throw new Error('invalid endpoint');
  }
  if (
    options.testOnly &&
    endpoint.upstreamHost !== '127.0.0.1' &&
    endpoint.upstreamHost !== '127.0.0.2' &&
    endpoint.upstreamHost !== '::1'
  ) {
    throw new Error('invalid endpoint');
  }
  if (
    typeof endpoint.listenHost !== 'string' ||
    !Number.isInteger(endpoint.listenPort) ||
    endpoint.listenPort < 0 ||
    endpoint.listenPort > 65535 ||
    typeof endpoint.upstreamHost !== 'string' ||
    !Number.isInteger(endpoint.upstreamPort) ||
    endpoint.upstreamPort < 1 ||
    endpoint.upstreamPort > 65535
  ) {
    throw new Error('invalid endpoint');
  }

  return Object.freeze({
    linkToken: config.linkToken,
    sessionToken: config.sessionToken,
    expiresAt: config.expiresAt,
    publicOrigin: config.publicOrigin,
    ...endpoint,
  });
}

function createGuestSessionProxy(inputConfig, options = {}) {
  const config = validateConfig(inputConfig, options);
  const sockets = new Set();
  const upstreamRequests = new Set();
  const startedAtWall = Date.now();
  const startedAtMonotonic = performance.now();
  const lifetimeMs = config.expiresAt - startedAtWall;
  const monotonicDeadline = startedAtMonotonic + lifetimeMs;
  const eventSink = typeof options.eventSink === 'function' ? options.eventSink : () => {};
  const expectedHost = new URL(config.publicOrigin).host;
  let redeemed = false;
  let closed = false;
  let expired = false;
  let expiryTimer;
  let parentStream = options.parentStream;
  let resolveDone;
  const done = new Promise((resolve) => {
    resolveDone = resolve;
  });

  function isLive() {
    return (
      !closed &&
      Date.now() < config.expiresAt &&
      performance.now() < monotonicDeadline
    );
  }

  function trackSocket(socket) {
    sockets.add(socket);
    socket.once('close', () => sockets.delete(socket));
    socket.on('error', () => {});
    return socket;
  }

  function stop(reason) {
    if (closed) return;
    closed = true;
    if (expiryTimer) clearTimeout(expiryTimer);
    for (const request of upstreamRequests) request.destroy();
    for (const socket of sockets) socket.destroy();
    server.close();
    if (reason === 'expiry' && !expired) {
      expired = true;
      eventSink('EXPIRED');
    }
    resolveDone(reason);
  }

  function expireIfNeeded() {
    if (!isLive()) stop('expiry');
  }

  function scheduleExpiry() {
    const delay = Math.max(
      0,
      Math.min(config.expiresAt - Date.now(), monotonicDeadline - performance.now())
    );
    expiryTimer = setTimeout(() => {
      if (isLive()) scheduleExpiry();
      else stop('expiry');
    }, Math.min(delay + 1, 2_147_483_647));
  }

  function landingPage(response) {
    const body = '<!doctype html><meta charset="utf-8"><meta name="referrer" content="no-referrer">' +
      '<title>Remote Chrome guest session</title><h1>Opening Remote Chrome</h1>' +
      '<form id="redeem" method="post" action="/guest/redeem">' +
      `<input type="hidden" name="token" value="${escapeHtmlAttribute(config.linkToken)}">` +
      '<button type="submit">Continue</button></form>' +
      '<script defer src="/guest/redeem.js"></script>';
    response.writeHead(200, {
      'Cache-Control': 'no-store',
      'Content-Security-Policy': "default-src 'none'; script-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
      'Content-Type': 'text/html; charset=utf-8',
      'Referrer-Policy': 'no-referrer',
      'X-Content-Type-Options': 'nosniff',
    });
    response.end(body);
  }

  function redemptionScript(response) {
    const body = '"use strict";(()=>{const f=document.getElementById("redeem");' +
      'const t=new URL(location.href).searchParams.get("token");' +
      'history.replaceState(null,"","/guest/");' +
      'if(f&&typeof t==="string"&&t.length){f.elements.token.value=t;f.requestSubmit();}})();';
    response.writeHead(200, {
      'Cache-Control': 'no-store',
      'Content-Type': 'text/javascript; charset=utf-8',
      'Referrer-Policy': 'no-referrer',
      'X-Content-Type-Options': 'nosniff',
    });
    response.end(body);
  }

  function redeem(request, response) {
    const contentType = String(request.headers['content-type'] || '')
      .split(';', 1)[0]
      .trim()
      .toLowerCase();
    const contentLength = Number(request.headers['content-length']);
    if (contentType !== 'application/x-www-form-urlencoded') {
      fixedResponse(response, 415);
      request.resume();
      return;
    }
    if (
      request.headers['content-length'] !== undefined &&
      (!Number.isSafeInteger(contentLength) || contentLength < 0 || contentLength > MAX_REDEEM_BODY_BYTES)
    ) {
      fixedResponse(response, 413);
      request.resume();
      return;
    }
    let size = 0;
    const chunks = [];
    request.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_REDEEM_BODY_BYTES) {
        chunks.length = 0;
      } else {
        chunks.push(chunk);
      }
    });
    request.on('end', () => {
      if (size > MAX_REDEEM_BODY_BYTES) {
        fixedResponse(response, 413);
        return;
      }
      if (response.writableEnded || !isLive()) {
        if (!response.writableEnded) fixedResponse(response, 410);
        return;
      }
      let token;
      try {
        const params = new URLSearchParams(Buffer.concat(chunks).toString('utf8'));
        if ([...params.keys()].some((key) => key !== 'token') || params.getAll('token').length !== 1) {
          fixedResponse(response, 400);
          return;
        }
        token = params.get('token');
      } catch {
        fixedResponse(response, 400);
        return;
      }
      if (redeemed || !timingSafeTextEqual(token, config.linkToken)) {
        fixedResponse(response, 401);
        return;
      }

      redeemed = true;
      const maxAge = Math.floor(
        Math.min(config.expiresAt - Date.now(), monotonicDeadline - performance.now()) / 1000
      );
      if (maxAge <= 0) {
        stop('expiry');
        if (!response.destroyed) fixedResponse(response, 410);
        return;
      }
      response.writeHead(303, {
        'Cache-Control': 'no-store',
        'Location': '/guest/?autoconnect=1&resize=scale&path=guest/websockify',
        'Referrer-Policy': 'no-referrer',
        'Set-Cookie': `${COOKIE_NAME}=${config.sessionToken}; Path=/guest/; HttpOnly; Secure; SameSite=Strict; Max-Age=${maxAge}`,
        'X-Content-Type-Options': 'nosniff',
      });
      response.end();
      eventSink('REDEEMED');
    });
  }

  function proxyHttp(request, response, parsedUrl) {
    const upstreamPath = parsedUrl.pathname.slice('/guest'.length) + parsedUrl.search;
    const upstreamRequest = http.request(
      {
        host: config.upstreamHost,
        port: config.upstreamPort,
        method: request.method,
        path: upstreamPath,
        headers: {
          ...cleanRequestHeaders(request),
          host: `${config.upstreamHost}:${config.upstreamPort}`,
        },
      },
      (upstreamResponse) => {
        response.writeHead(
          upstreamResponse.statusCode || 502,
          upstreamResponse.statusMessage,
          cleanResponseHeaders(upstreamResponse.headers)
        );
        upstreamResponse.pipe(response);
      }
    );
    upstreamRequests.add(upstreamRequest);
    upstreamRequest.once('close', () => upstreamRequests.delete(upstreamRequest));
    upstreamRequest.on('socket', trackSocket);
    upstreamRequest.on('error', () => fixedResponse(response, 502));
    upstreamRequest.end();
  }

  const server = http.createServer((request, response) => {
    if (!isLive()) {
      fixedResponse(response, 410);
      expireIfNeeded();
      return;
    }
    let parsedUrl;
    try {
      parsedUrl = new URL(request.url, config.publicOrigin);
    } catch {
      fixedResponse(response, 400);
      return;
    }
    if (rawHeaderCount(request, 'host') !== 1 || request.headers.host !== expectedHost) {
      fixedResponse(response, 400);
      return;
    }
    if (!parsedUrl.pathname.startsWith('/guest/')) {
      fixedResponse(response, 404);
      return;
    }
    if (request.method === 'GET' && parsedUrl.pathname === '/guest/redeem.js' && !parsedUrl.search) {
      redemptionScript(response);
      return;
    }
    if (request.method === 'POST' && parsedUrl.pathname === '/guest/redeem' && !parsedUrl.search) {
      redeem(request, response);
      return;
    }
    if (request.method === 'GET' && parsedUrl.pathname === '/guest/' && parsedUrl.searchParams.has('token')) {
      if (
        parsedUrl.searchParams.getAll('token').length === 1 &&
        [...parsedUrl.searchParams.keys()].every((key) => key === 'token') &&
        !redeemed &&
        timingSafeTextEqual(parsedUrl.searchParams.get('token'), config.linkToken)
      ) {
        landingPage(response);
      } else {
        fixedResponse(response, 401);
      }
      return;
    }
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      fixedResponse(response, 405);
      request.resume();
      return;
    }
    if (parsedUrl.pathname === '/guest/websockify') {
      fixedResponse(response, 426);
      return;
    }
    if (!validGuestCookie(request, config.sessionToken)) {
      fixedResponse(response, 401);
      return;
    }
    proxyHttp(request, response, parsedUrl);
  });

  server.on('connection', trackSocket);
  server.on('clientError', (error, socket) => {
    if (socket.writable) socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
    else socket.destroy();
  });
  server.on('upgrade', (request, clientSocket, head) => {
    trackSocket(clientSocket);
    if (!isLive()) {
      clientSocket.end('HTTP/1.1 410 Gone\r\nConnection: close\r\n\r\n');
      expireIfNeeded();
      return;
    }
    let parsedUrl;
    try {
      parsedUrl = new URL(request.url, config.publicOrigin);
    } catch {
      clientSocket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
      return;
    }
    const validOrigin =
      rawHeaderCount(request, 'origin') === 1 &&
      typeof request.headers.origin === 'string' &&
      request.headers.origin === config.publicOrigin;
    if (
      request.method !== 'GET' ||
      rawHeaderCount(request, 'host') !== 1 ||
      request.headers.host !== expectedHost ||
      parsedUrl.pathname !== '/guest/websockify' ||
      parsedUrl.search ||
      !validOrigin ||
      !validGuestCookie(request, config.sessionToken)
    ) {
      clientSocket.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
      return;
    }

    const upstreamRequest = http.request({
      host: config.upstreamHost,
      port: config.upstreamPort,
      method: 'GET',
      path: '/websockify',
      headers: {
        ...cleanRequestHeaders(request, true),
        host: `${config.upstreamHost}:${config.upstreamPort}`,
      },
    });
    upstreamRequests.add(upstreamRequest);
    upstreamRequest.once('close', () => upstreamRequests.delete(upstreamRequest));
    upstreamRequest.on('socket', trackSocket);
    upstreamRequest.on('upgrade', (upstreamResponse, upstreamSocket, upstreamHead) => {
      trackSocket(upstreamSocket);
      let responseHead = `HTTP/1.1 ${upstreamResponse.statusCode} ${upstreamResponse.statusMessage}\r\n`;
      for (const [name, value] of Object.entries(upstreamResponse.headers)) {
        if (value !== undefined && name.toLowerCase() !== 'set-cookie') {
          responseHead += `${name}: ${Array.isArray(value) ? value.join(', ') : value}\r\n`;
        }
      }
      clientSocket.write(`${responseHead}\r\n`);
      if (upstreamHead.length) clientSocket.write(upstreamHead);
      if (head.length) upstreamSocket.write(head);
      clientSocket.pipe(upstreamSocket).pipe(clientSocket);
    });
    upstreamRequest.on('response', (upstreamResponse) => {
      upstreamResponse.resume();
      clientSocket.end('HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n');
    });
    upstreamRequest.on('error', () => {
      if (clientSocket.writable) {
        clientSocket.end('HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n');
      }
    });
    upstreamRequest.end();
  });

  function attachParentStream(stream) {
    if (!stream) return;
    parentStream = stream;
    if (stream.destroyed || stream.readableEnded) {
      stop('parent');
      return;
    }
    stream.on('end', () => stop('parent'));
    stream.on('close', () => stop('parent'));
    stream.on('error', () => stop('parent'));
    stream.on('data', () => stop('parent'));
    stream.resume();
  }

  async function start() {
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(config.listenPort, config.listenHost, () => {
        server.off('error', reject);
        resolve();
      });
    });
    scheduleExpiry();
    attachParentStream(parentStream);
    eventSink('READY');
    return server.address();
  }

  return Object.freeze({
    server,
    start,
    close: () => stop('manual'),
    done,
    isLive,
  });
}

function readOneConfigLine(stream) {
  return new Promise((resolve, reject) => {
    let bytes = 0;
    const chunks = [];
    function cleanup() {
      stream.off('data', onData);
      stream.off('end', onEnd);
      stream.off('error', onError);
    }
    function onError() {
      cleanup();
      reject(new Error('input failure'));
    }
    function onEnd() {
      cleanup();
      reject(new Error('input closed'));
    }
    function onData(chunk) {
      const newline = chunk.indexOf(0x0a);
      const consumed = newline < 0 ? chunk : chunk.subarray(0, newline);
      bytes += consumed.length;
      if (bytes > MAX_CONFIG_BYTES || (newline >= 0 && newline !== chunk.length - 1)) {
        cleanup();
        reject(new Error('invalid input'));
        return;
      }
      chunks.push(consumed);
      if (newline >= 0) {
        stream.pause();
        cleanup();
        try {
          const line = Buffer.concat(chunks).toString('utf8').replace(/\r$/, '');
          resolve(JSON.parse(line));
        } catch {
          reject(new Error('invalid config'));
        }
      }
    }
    stream.on('data', onData);
    stream.once('end', onEnd);
    stream.once('error', onError);
    stream.resume();
  });
}

async function runProduction() {
  if (process.argv.length !== 2 || typeof process.getuid !== 'function' || process.getuid() !== PRODUCTION.uid) {
    throw new Error('invalid process');
  }
  const config = await readOneConfigLine(process.stdin);
  const proxy = createGuestSessionProxy(config, {
    eventSink: (event) => process.stdout.write(`${event}\n`),
    parentStream: process.stdin,
  });
  const shutdown = () => proxy.close();
  process.once('SIGTERM', shutdown);
  process.once('SIGINT', shutdown);
  await proxy.start();
  await proxy.done;
  process.stdin.pause();
}

if (require.main === module) {
  let failed = false;
  const failClosed = () => {
    if (failed) return;
    failed = true;
    process.stderr.write('FAILED\n');
    process.exit(1);
  };
  process.once('uncaughtException', failClosed);
  process.once('unhandledRejection', failClosed);
  runProduction().catch(failClosed);
}

module.exports = {
  COOKIE_NAME,
  PRODUCTION,
  createGuestSessionProxy,
  readOneConfigLine,
};
