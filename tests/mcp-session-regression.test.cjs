'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const {
  parseArgs,
  readBearerToken,
  runRegression,
  validateEndpoint,
} = require('./mcp-session-regression.cjs');

const TOKEN = 'regression-bearer-that-must-never-be-logged';
const SESSION = 'fixture-session-id';
const MARKER = 'CODEX_UNIFIED_MCP_READY';

function rpc(id, result) {
  return { jsonrpc: '2.0', id, result };
}

function sendJson(response, status, value, headers = {}) {
  response.writeHead(status, { 'Content-Type': 'application/json', ...headers });
  response.end(JSON.stringify(value));
}

function sendSse(response, value, headers = {}) {
  response.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    ...headers,
  });
  response.end(`event: message\ndata: ${JSON.stringify(value)}\n\n`);
}

async function readJson(request) {
  const chunks = [];
  for await (const chunk of request)
    chunks.push(chunk);
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

async function listen(server) {
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return server.address().port;
}

async function close(server) {
  await new Promise((resolve, reject) => {
    server.close(error => error ? reject(error) : resolve());
  });
}

test('keeps one stock MCP session across browser calls, wait, and deletion', async () => {
  const requests = [];
  let deleted = false;
  const tools = [
    {
      name: 'browser_navigate',
      inputSchema: { type: 'object', properties: { url: { type: 'string' } } },
    },
    {
      name: 'browser_snapshot',
      inputSchema: { type: 'object', properties: {} },
    },
    {
      name: 'remote_chrome_request_human_intervention',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    },
    {
      name: 'get_novnc_link',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    },
    {
      name: 'create_temporary_novnc_link',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    },
    {
      name: 'revoke_temporary_novnc_link',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    },
  ];

  const server = http.createServer(async (request, response) => {
    try {
      assert.equal(request.url, '/mcp');
      assert.equal(request.headers.authorization, `Bearer ${TOKEN}`);
      const session = request.headers['mcp-session-id'];
      const payload = request.method === 'POST' ? await readJson(request) : undefined;
      requests.push({ method: request.method, session, rpcMethod: payload?.method });

      if (request.method === 'DELETE') {
        assert.equal(session, SESSION);
        deleted = true;
        response.writeHead(200);
        response.end();
        return;
      }
      if (deleted) {
        response.writeHead(404);
        response.end();
        return;
      }
      if (payload.method === 'initialize') {
        sendSse(response, rpc(payload.id, {
          protocolVersion: '2025-06-18',
          capabilities: {},
          serverInfo: { name: 'stock-playwright-mcp', version: '0.0.82' },
        }), { 'Mcp-Session-Id': SESSION });
        return;
      }
      assert.equal(session, SESSION);
      if (payload.method === 'notifications/initialized') {
        response.writeHead(202);
        response.end();
        return;
      }
      if (payload.method === 'tools/list') {
        sendSse(response, rpc(payload.id, { tools }));
        return;
      }
      assert.equal(payload.method, 'tools/call');
      if (payload.params.name === 'browser_navigate') {
        assert.match(payload.params.arguments.url, /^data:text\/html/);
        assert.equal(payload.params.arguments.url.includes(TOKEN), false);
        sendJson(response, 200, rpc(payload.id, {
          content: [{ type: 'text', text: 'navigated' }],
        }));
        return;
      }
      assert.equal(payload.params.name, 'browser_snapshot');
      sendSse(response, rpc(payload.id, {
        content: [{ type: 'text', text: `- main: ${MARKER}` }],
      }));
    } catch (error) {
      response.destroy(error);
    }
  });

  const port = await listen(server);
  try {
    const result = await runRegression({
      endpoint: `http://127.0.0.1:${port}/mcp`,
      bearerToken: TOKEN,
      waitMs: 5,
      timeoutMs: 1000,
    });
    assert.deepEqual(result, {
      browserCalls: 3,
      deletionVerified: true,
      waitMs: 5,
      snapshotOnly: false,
    });
    assert.deepEqual(
      requests.map(({ method, rpcMethod }) => [method, rpcMethod]),
      [
        ['POST', 'initialize'],
        ['POST', 'notifications/initialized'],
        ['POST', 'tools/list'],
        ['POST', 'tools/call'],
        ['POST', 'tools/call'],
        ['POST', 'tools/call'],
        ['DELETE', undefined],
        ['POST', 'tools/list'],
      ],
    );
    for (const entry of requests.slice(1))
      assert.equal(entry.session, SESSION);
  } finally {
    await close(server);
  }
});

test('snapshot-only canary never navigates or mutates the page', async () => {
  const methods = [];
  let deleted = false;
  const tools = [
    { name: 'browser_navigate', inputSchema: { type: 'object', properties: {} } },
    { name: 'browser_snapshot', inputSchema: { type: 'object', properties: {} } },
    { name: 'remote_chrome_request_human_intervention', inputSchema: { type: 'object', properties: {} } },
    { name: 'get_novnc_link', inputSchema: { type: 'object', properties: {} } },
    { name: 'create_temporary_novnc_link', inputSchema: { type: 'object', properties: {} } },
    { name: 'revoke_temporary_novnc_link', inputSchema: { type: 'object', properties: {} } },
  ];
  const server = http.createServer(async (request, response) => {
    const payload = request.method === 'POST' ? await readJson(request) : undefined;
    methods.push(payload?.method || request.method);
    if (request.method === 'DELETE') {
      deleted = true;
      response.writeHead(200);
      response.end();
      return;
    }
    if (deleted) {
      response.writeHead(404);
      response.end();
      return;
    }
    if (payload.method === 'initialize') {
      sendSse(response, rpc(payload.id, {
        protocolVersion: '2025-06-18', capabilities: {},
        serverInfo: { name: 'fixture', version: '1' },
      }), { 'Mcp-Session-Id': SESSION });
    } else if (payload.method === 'notifications/initialized') {
      response.writeHead(202);
      response.end();
    } else if (payload.method === 'tools/list') {
      sendSse(response, rpc(payload.id, { tools }));
    } else {
      assert.equal(payload.method, 'tools/call');
      assert.equal(payload.params.name, 'browser_snapshot');
      sendJson(response, 200, rpc(payload.id, {
        content: [{ type: 'text', text: 'current page snapshot' }],
      }));
    }
  });
  const port = await listen(server);
  try {
    const result = await runRegression({
      endpoint: `http://127.0.0.1:${port}/mcp`,
      bearerToken: TOKEN,
      timeoutMs: 1000,
      snapshotOnly: true,
    });
    assert.deepEqual(result, {
      browserCalls: 1,
      deletionVerified: true,
      waitMs: 0,
      snapshotOnly: true,
    });
    assert.equal(methods.includes('browser_navigate'), false);
    assert.deepEqual(methods, [
      'initialize',
      'notifications/initialized',
      'tools/list',
      'tools/call',
      'DELETE',
      'tools/list',
    ]);
  } finally {
    await close(server);
  }
});

test('accepts canonical and token-path endpoints without exposing credentials', () => {
  const parsed = parseArgs([
    '--endpoint', 'https://desktop.example.test/compatibility-token/mcp',
    '--bearer-token-file', '/private/token',
    '--wait-seconds', '0.125',
    '--timeout-seconds', '3',
    '--snapshot-only',
  ]);
  assert.equal(parsed.waitMs, 125);
  assert.equal(parsed.timeoutMs, 3000);
  assert.equal(parsed.bearerTokenFile, '/private/token');
  assert.equal(parsed.snapshotOnly, true);
  assert.equal(
    validateEndpoint(parsed.endpoint).pathname,
    '/compatibility-token/mcp',
  );
  assert.throws(
    () => validateEndpoint('http://desktop.example.test/mcp'),
    /must use HTTPS/,
  );
  assert.throws(
    () => validateEndpoint('https://desktop.example.test/not-mcp'),
    /must end in \/mcp/,
  );
});

test('requires private bearer-token files', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'mcp-regression-'));
  try {
    const tokenFile = path.join(directory, 'token');
    fs.writeFileSync(tokenFile, `${TOKEN}\n`, { mode: 0o600 });
    assert.equal(readBearerToken(tokenFile), TOKEN);
    fs.chmodSync(tokenFile, 0o644);
    assert.throws(() => readBearerToken(tokenFile), /group or other/);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
