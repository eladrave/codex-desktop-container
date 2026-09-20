#!/usr/bin/env node
'use strict';

const http = require('node:http');
const fs = require('node:fs');

const PROTOCOL_VERSION = '2025-06-18';
const endpoint = new URL(
  process.env.REMOTE_BROWSER_INTERNAL_MCP_URL || 'http://127.0.0.2:8932/mcp',
);
const intervalMs = Number(process.env.REMOTE_BROWSER_KEEPER_INTERVAL_MS || 1000);
const retryMs = Number(process.env.REMOTE_BROWSER_KEEPER_RETRY_MS || 2000);
const requestTimeoutMs = Number(
  process.env.REMOTE_BROWSER_KEEPER_REQUEST_TIMEOUT_MS || 30000,
);
const maxResponseBytes = 4 * 1024 * 1024;
const readyFile = process.env.REMOTE_BROWSER_KEEPER_READY_FILE ||
  '/run/remote-browser/browser/keeper.ready';

if (endpoint.protocol !== 'http:' || endpoint.hostname !== '127.0.0.2' ||
    endpoint.pathname !== '/mcp' || endpoint.username || endpoint.password ||
    endpoint.hash) {
  throw new Error('keeper endpoint must be the unauthenticated loopback MCP route');
}
for (const [name, value, minimum] of [
  ['interval', intervalMs, 500],
  ['retry', retryMs, 250],
  ['request timeout', requestTimeoutMs, 1000],
]) {
  if (!Number.isSafeInteger(value) || value < minimum)
    throw new Error(`keeper ${name} is invalid`);
}

let stopping = false;
let activeSession;
let nextId = 1;

async function markReady() {
  const temporary = `${readyFile}.${process.pid}.tmp`;
  await fs.promises.writeFile(temporary, 'ready\n', { mode: 0o600 });
  await fs.promises.chmod(temporary, 0o600);
  await fs.promises.rename(temporary, readyFile);
}

async function clearReady() {
  await fs.promises.rm(readyFile, { force: true });
}

function delay(duration) {
  return new Promise(resolve => setTimeout(resolve, duration));
}

function request(payload, sessionId, method = 'POST') {
  const body = payload === undefined ? undefined : JSON.stringify(payload);
  const headers = { Accept: 'application/json, text/event-stream' };
  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    headers['Content-Length'] = Buffer.byteLength(body);
  }
  if (sessionId)
    headers['Mcp-Session-Id'] = sessionId;

  return new Promise((resolve, reject) => {
    const req = http.request(endpoint, { method, headers }, response => {
      const chunks = [];
      let size = 0;
      response.on('data', chunk => {
        size += chunk.length;
        if (size > maxResponseBytes) {
          response.destroy(new Error('keeper response exceeded size limit'));
          return;
        }
        chunks.push(chunk);
      });
      response.on('error', reject);
      response.on('end', () => resolve({
        status: response.statusCode,
        headers: response.headers,
        body: Buffer.concat(chunks).toString('utf8'),
      }));
    });
    req.setTimeout(requestTimeoutMs, () => req.destroy(new Error('keeper request timed out')));
    req.on('error', reject);
    if (body !== undefined)
      req.write(body);
    req.end();
  });
}

function messages(response) {
  const contentType = String(response.headers['content-type'] || '').toLowerCase();
  if (contentType.startsWith('text/event-stream')) {
    return response.body.split(/\r?\n\r?\n/).flatMap(block => {
      const data = block.split(/\r?\n/)
        .filter(line => line.startsWith('data:'))
        .map(line => line.slice(5).trimStart())
        .join('\n');
      return data && data !== '[DONE]' ? [JSON.parse(data)] : [];
    });
  }
  const parsed = JSON.parse(response.body);
  return Array.isArray(parsed) ? parsed : [parsed];
}

function resultFor(response, id, operation) {
  if (response.status !== 200)
    throw new Error(`${operation} returned HTTP ${response.status}`);
  const message = messages(response).find(item => String(item?.id) === String(id));
  if (!message)
    throw new Error(`${operation} omitted its JSON-RPC response`);
  if (message.error)
    throw new Error(`${operation} returned an MCP error`);
  return message.result;
}

async function call(sessionId, method, params) {
  const id = nextId++;
  const response = await request({
    jsonrpc: '2.0',
    id,
    method,
    ...(params === undefined ? {} : { params }),
  }, sessionId);
  return resultFor(response, id, method);
}

async function openSession() {
  const id = nextId++;
  const initialized = await request({
    jsonrpc: '2.0',
    id,
    method: 'initialize',
    params: {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: { name: 'codex-desktop-browser-keeper', version: '1' },
    },
  });
  resultFor(initialized, id, 'initialize');
  const sessionId = String(initialized.headers['mcp-session-id'] || '').trim();
  if (!sessionId)
    throw new Error('initialize omitted the MCP session id');

  const notification = await request({
    jsonrpc: '2.0',
    method: 'notifications/initialized',
  }, sessionId);
  if (![200, 202, 204].includes(notification.status))
    throw new Error(`initialized notification returned HTTP ${notification.status}`);

  const listed = await call(sessionId, 'tools/list');
  const tools = Array.isArray(listed?.tools) ? listed.tools : [];
  if (!tools.some(tool => tool?.name === 'browser_tabs'))
    throw new Error('tools/list omitted browser_tabs');

  // A real browser tool call is required to establish the shared backend.
  // Listing tabs is intentionally nonmutating and does not inspect page data.
  const tabs = await call(sessionId, 'tools/call', {
    name: 'browser_tabs',
    arguments: { action: 'list' },
  });
  if (tabs?.isError)
    throw new Error('browser_tabs returned an error');
  return sessionId;
}

async function closeSession(sessionId) {
  if (!sessionId)
    return;
  await request(undefined, sessionId, 'DELETE').catch(() => {});
}

async function keepSession(sessionId) {
  const result = await call(sessionId, 'tools/call', {
    name: 'browser_tabs',
    arguments: { action: 'list' },
  });
  if (result?.isError)
    throw new Error('browser_tabs returned an error');
}

async function main() {
  await clearReady();
  while (!stopping) {
    try {
      activeSession = await openSession();
      await markReady();
      while (!stopping) {
        await delay(intervalMs);
        if (!stopping)
          await keepSession(activeSession);
      }
    } catch (error) {
      if (!stopping)
        process.stderr.write('Browser keeper lost its session; reconnecting.\n');
    } finally {
      await clearReady();
      const session = activeSession;
      activeSession = undefined;
      await closeSession(session);
    }
    if (!stopping)
      await delay(retryMs);
  }
}

const stop = () => {
  stopping = true;
};
process.once('SIGTERM', stop);
process.once('SIGINT', stop);
process.once('SIGHUP', stop);

main().catch(() => {
  process.stderr.write('Browser keeper stopped after an unexpected error.\n');
  process.exitCode = 1;
});
