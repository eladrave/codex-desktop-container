#!/usr/bin/env node
'use strict';

// Run inside a disposable unified container with:
// docker exec -i CONTAINER node - <tests/download-runtime-probe.cjs
// The output is a nonsecret path to verify after a container restart.

const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const http = require('node:http');
const path = require('node:path');
const { downloadDirectory } = require(
  '/opt/codex-desktop/remote-browser/persist-download.cjs');

const endpoint = 'http://127.0.0.1:8443/mcp';
const profile = '/home/codex/.config/remote-browser/chrome-profile';
const credentialFile = '/var/lib/codex-desktop-persistent/remote-browser/credentials.env';
let sessionId;
let nextId = 1;

async function token() {
  const line = (await fs.readFile(credentialFile, 'utf8'))
    .split(/\r?\n/).find(value => value.startsWith('MCP_TOKEN='));
  const value = line?.slice('MCP_TOKEN='.length) || '';
  if (!/^[A-Za-z0-9_-]{32,128}$/.test(value))
    throw new Error('MCP credential unavailable');
  return value;
}

function request(bearer, payload, method = 'POST') {
  return new Promise((resolve, reject) => {
    const body = payload === undefined ? undefined : JSON.stringify(payload);
    const headers = { Accept: 'application/json, text/event-stream',
      Authorization: `Bearer ${bearer}` };
    if (body !== undefined) {
      headers['Content-Type'] = 'application/json';
      headers['Content-Length'] = Buffer.byteLength(body);
    }
    if (sessionId)
      headers['Mcp-Session-Id'] = sessionId;
    const req = http.request(endpoint, { method, headers, timeout: 15000 }, response => {
      const chunks = [];
      let size = 0;
      response.on('data', chunk => {
        size += chunk.length;
        if (size > 4 * 1024 * 1024)
          response.destroy(new Error('MCP response too large'));
        else
          chunks.push(chunk);
      });
      response.on('error', reject);
      response.on('end', () => resolve({
        status: response.statusCode,
        headers: response.headers,
        body: Buffer.concat(chunks).toString('utf8'),
      }));
    });
    req.on('timeout', () => req.destroy(new Error('MCP timeout')));
    req.on('error', reject);
    if (body !== undefined)
      req.write(body);
    req.end();
  });
}

function rpcResult(response, id) {
  if (response.status !== 200)
    throw new Error(`MCP returned HTTP ${response.status}`);
  let messages;
  if (String(response.headers['content-type'] || '').startsWith('text/event-stream')) {
    messages = response.body.split(/\r?\n/)
      .filter(line => line.startsWith('data:'))
      .map(line => JSON.parse(line.slice(5).trim()));
  } else {
    messages = [JSON.parse(response.body)];
  }
  const message = messages.find(item => item.id === id);
  if (!message || message.error)
    throw new Error('MCP tool call failed');
  return message.result;
}

async function call(bearer, method, params) {
  const id = nextId++;
  return rpcResult(await request(bearer, {
    jsonrpc: '2.0', id, method, ...(params ? { params } : {}),
  }), id);
}

async function tool(bearer, name, args) {
  const result = await call(bearer, 'tools/call', { name, arguments: args });
  if (result?.isError)
    throw new Error(`${name} failed`);
  return (result?.content || []).filter(item => item?.type === 'text')
    .map(item => item.text).join('\n');
}

async function main() {
  const bearer = await token();
  const id = nextId++;
  const raw = await request(bearer, {
    jsonrpc: '2.0', id, method: 'initialize',
    params: { protocolVersion: '2025-06-18', capabilities: {},
      clientInfo: { name: 'download-runtime-probe', version: '1' } },
  });
  if (!rpcResult(raw, id)?.serverInfo)
    throw new Error('MCP initialization failed');
  sessionId = String(raw.headers['mcp-session-id'] || '');
  if (!sessionId)
    throw new Error('MCP session missing');
  await request(bearer, { jsonrpc: '2.0', method: 'notifications/initialized' });

  const filename = `codex-download-probe-${crypto.randomUUID()}.txt`;
  const content = `Persistent Chrome download probe ${filename}\n`;
  const href = `data:text/plain;base64,${Buffer.from(content).toString('base64')}`;
  const page = `<!doctype html><title>Download probe</title>` +
    `<a href="${href}" download="${filename}">Save download probe</a>`;
  await tool(bearer, 'browser_tabs', { action: 'new' });
  await tool(bearer, 'browser_navigate', {
    url: `data:text/html,${encodeURIComponent(page)}`,
  });
  const snapshot = await tool(bearer, 'browser_snapshot', {});
  const ref = snapshot.match(/link "Save download probe" \[ref=([^\]]+)\]/)?.[1];
  if (!ref)
    throw new Error('download link not visible');
  await tool(bearer, 'browser_click', {
    element: 'Save download probe', target: ref,
  });

  const directory = await downloadDirectory(profile);
  const expected = path.join(directory, filename);
  let saved = false;
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      if (await fs.readFile(expected, 'utf8') === content) {
        saved = true;
        break;
      }
    } catch (error) {
      if (error.code !== 'ENOENT')
        throw error;
    }
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  if (!saved)
    throw new Error('Chrome download was not saved in the persistent home');
  const deleted = await request(bearer, undefined, 'DELETE');
  if (![200, 202, 204].includes(deleted.status))
    throw new Error('MCP session deletion failed');
  process.stdout.write(`SAVED_PATH=${expected}\n`);
}

main().catch(error => {
  process.stderr.write(`FAIL: ${error.message}\n`);
  process.exitCode = 1;
});
