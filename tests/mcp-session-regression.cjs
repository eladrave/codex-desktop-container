#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const http = require('node:http');
const https = require('node:https');

const PROTOCOL_VERSION = '2025-06-18';
const MAX_RESPONSE_BYTES = 4 * 1024 * 1024;
const READY_MARKER = 'CODEX_UNIFIED_MCP_READY';
const CLICKED_MARKER = 'CODEX_UNIFIED_MCP_CLICKED';
const BUTTON_NAME = 'Activate unified MCP probe';

class RegressionError extends Error {
  constructor(message) {
    super(message);
    this.name = 'RegressionError';
  }
}

function usage() {
  return [
    'Usage:',
    '  node tests/mcp-session-regression.cjs --endpoint URL [options]',
    '',
    'Options:',
    '  --bearer-token-file PATH  Read the bearer credential from a mode-0600 file',
    '  --wait-seconds NUMBER     Idle wait inside the same MCP session (default: 35)',
    '  --timeout-seconds NUMBER  Per-request timeout (default: 60)',
    '  --snapshot-only           Run a read-only snapshot canary instead of navigation',
    '  --exercise-handoff        Invoke and validate both permanent noVNC handoff tools',
    '  --exercise-guest          Create, validate, and immediately revoke temporary guest access',
    '  --insecure                Disable TLS verification for loopback only',
    '  --help                    Show this help',
    '',
    'The endpoint, credentials, response bodies, cookies, and page content are never logged.',
  ].join('\n');
}

function parseNumber(value, option, allowZero = true) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 0 || (!allowZero && parsed === 0))
    throw new RegressionError(`${option} has an invalid numeric value`);
  return parsed;
}

function parseArgs(argv) {
  const result = {
    waitMs: 35000,
    timeoutMs: 60000,
    insecure: false,
    snapshotOnly: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    if (option === '--help' || option === '-h')
      return { help: true };
    if (option === '--insecure') {
      result.insecure = true;
      continue;
    }
    if (option === '--snapshot-only') {
      result.snapshotOnly = true;
      continue;
    }
    if (option === '--exercise-handoff') {
      result.exerciseHandoff = true;
      continue;
    }
    if (option === '--exercise-guest') {
      result.exerciseHandoff = true;
      result.exerciseGuest = true;
      continue;
    }
    const value = argv[index + 1];
    if (value === undefined)
      throw new RegressionError(`${option} requires a value`);
    index += 1;
    if (option === '--endpoint')
      result.endpoint = value;
    else if (option === '--bearer-token-file')
      result.bearerTokenFile = value;
    else if (option === '--wait-seconds')
      result.waitMs = parseNumber(value, option) * 1000;
    else if (option === '--timeout-seconds')
      result.timeoutMs = parseNumber(value, option, false) * 1000;
    else
      throw new RegressionError('unknown command-line argument');
  }
  if (!result.endpoint)
    throw new RegressionError('--endpoint is required');
  return result;
}

function validateEndpoint(value, insecure = false) {
  let endpoint;
  try {
    endpoint = new URL(value);
  } catch {
    throw new RegressionError('endpoint is not a valid URL');
  }
  if (endpoint.username || endpoint.password || endpoint.hash)
    throw new RegressionError('endpoint must not contain user information or a fragment');
  const loopback = new Set(['localhost', '127.0.0.1', '::1']);
  if (endpoint.protocol !== 'https:' &&
      !(endpoint.protocol === 'http:' && loopback.has(endpoint.hostname))) {
    throw new RegressionError('endpoint must use HTTPS (HTTP is loopback-only)');
  }
  if (insecure && !loopback.has(endpoint.hostname))
    throw new RegressionError('--insecure is allowed only for loopback endpoints');
  if (!endpoint.pathname.endsWith('/mcp'))
    throw new RegressionError('endpoint path must end in /mcp');
  return endpoint;
}

function readBearerToken(file) {
  if (!file)
    return undefined;
  const stat = fs.statSync(file);
  if (!stat.isFile())
    throw new RegressionError('bearer token path is not a regular file');
  if ((stat.mode & 0o077) !== 0)
    throw new RegressionError('bearer token file must not be accessible by group or other');
  const value = fs.readFileSync(file, 'utf8').trim();
  if (!value)
    throw new RegressionError('bearer token file is empty');
  return value;
}

function request(endpoint, options = {}) {
  const method = options.method || 'POST';
  const body = options.payload === undefined ? undefined : JSON.stringify(options.payload);
  const headers = { Accept: 'application/json, text/event-stream' };
  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    headers['Content-Length'] = Buffer.byteLength(body);
  }
  if (options.sessionId)
    headers['Mcp-Session-Id'] = options.sessionId;
  if (options.bearerToken)
    headers.Authorization = `Bearer ${options.bearerToken}`;
  const transport = endpoint.protocol === 'https:' ? https : http;

  return new Promise((resolve, reject) => {
    const req = transport.request(endpoint, {
      method,
      headers,
      rejectUnauthorized: !options.insecure,
    });
    const chunks = [];
    let size = 0;
    req.setTimeout(options.timeoutMs || 60000, () => {
      req.destroy(new RegressionError(`${method} request timed out`));
    });
    req.on('error', reject);
    req.on('response', response => {
      response.on('data', chunk => {
        size += chunk.length;
        if (size > MAX_RESPONSE_BYTES) {
          response.destroy(new RegressionError('MCP response exceeded the size limit'));
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
    if (body !== undefined)
      req.write(body);
    req.end();
  });
}

function parseMessages(response) {
  const contentType = String(response.headers['content-type'] || '').toLowerCase();
  if (contentType.startsWith('text/event-stream')) {
    const messages = [];
    for (const block of response.body.split(/\r?\n\r?\n/)) {
      const data = block.split(/\r?\n/)
        .filter(line => line.startsWith('data:'))
        .map(line => line.slice(5).trimStart())
        .join('\n');
      if (data && data !== '[DONE]')
        messages.push(JSON.parse(data));
    }
    return messages;
  }
  const parsed = JSON.parse(response.body);
  return Array.isArray(parsed) ? parsed : [parsed];
}

function responseResult(response, id) {
  const message = parseMessages(response)
    .find(candidate => candidate && String(candidate.id) === String(id));
  if (!message)
    throw new RegressionError(`response omitted JSON-RPC id ${id}`);
  if (message.error)
    throw new RegressionError(`JSON-RPC id ${id} returned an error`);
  return message.result;
}

function resultText(result, toolName) {
  if (!result || result.isError)
    throw new RegressionError(`${toolName} returned an error`);
  return (result.content || [])
    .filter(item => item && item.type === 'text' && typeof item.text === 'string')
    .map(item => item.text)
    .join('\n');
}

function urlsInText(text) {
  return String(text).split(/\s+/).flatMap(candidate => {
    if (!candidate.startsWith('https://'))
      return [];
    try {
      return [new URL(candidate)];
    } catch {
      return [];
    }
  });
}

function validateTokenUrl(url, expectedPath, expectedPort = '') {
  const keys = [...url.searchParams.keys()];
  const token = url.searchParams.get('token') || '';
  if (url.protocol !== 'https:' || !url.hostname || url.port !== expectedPort ||
      url.pathname !== expectedPath || url.username || url.password || url.hash ||
      keys.length !== 1 || keys[0] !== 'token' ||
      !/^[A-Za-z0-9_-]{32,128}$/.test(token)) {
    throw new RegressionError('handoff tool returned an invalid protected URL');
  }
  return url.href;
}

function stableHandoffUrl(text) {
  const candidate = urlsInText(text)
    .find(url => url.pathname === '/login/' && url.port === '');
  if (!candidate)
    throw new RegressionError('handoff tool omitted the permanent noVNC URL');
  return validateTokenUrl(candidate, '/login/');
}

function guestHandoffUrl(text, stableUrl) {
  const stable = new URL(stableUrl);
  const candidate = urlsInText(text)
    .find(url => url.pathname === '/guest/' && url.port === '10000');
  if (!candidate || candidate.hostname !== stable.hostname)
    throw new RegressionError('temporary handoff tool omitted the matching guest URL');
  return validateTokenUrl(candidate, '/guest/', '10000');
}

async function runRegression(configuration) {
  const endpoint = validateEndpoint(configuration.endpoint, configuration.insecure);
  const bearerToken = configuration.bearerToken ||
    readBearerToken(configuration.bearerTokenFile);
  const options = {
    bearerToken,
    insecure: configuration.insecure || false,
    timeoutMs: configuration.timeoutMs || 60000,
  };
  let id = 1;
  let sessionId;
  let deleted = false;
  const call = async (method, params) => {
    const currentId = id++;
    const response = await request(endpoint, {
      ...options,
      sessionId,
      payload: {
        jsonrpc: '2.0',
        id: currentId,
        method,
        ...(params === undefined ? {} : { params }),
      },
    });
    if (response.status !== 200)
      throw new RegressionError(`${method} returned HTTP ${response.status}`);
    return responseResult(response, currentId);
  };

  try {
    const initializeId = id++;
    const initialize = await request(endpoint, {
      ...options,
      payload: {
        jsonrpc: '2.0',
        id: initializeId,
        method: 'initialize',
        params: {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: {},
          clientInfo: { name: 'codex-unified-regression', version: '1' },
        },
      },
    });
    if (initialize.status !== 200)
      throw new RegressionError(`initialize returned HTTP ${initialize.status}`);
    responseResult(initialize, initializeId);
    sessionId = String(initialize.headers['mcp-session-id'] || '').trim();
    if (!sessionId)
      throw new RegressionError('initialize omitted Mcp-Session-Id');

    const initialized = await request(endpoint, {
      ...options,
      sessionId,
      payload: { jsonrpc: '2.0', method: 'notifications/initialized' },
    });
    if (![200, 202, 204].includes(initialized.status))
      throw new RegressionError(`initialized notification returned HTTP ${initialized.status}`);

    const listed = await call('tools/list');
    const tools = Array.isArray(listed.tools) ? listed.tools : [];
    const byName = new Map(tools.map(tool => [tool.name, tool]));
    for (const required of [
      'browser_navigate',
      'browser_snapshot',
      'browser_click',
      'remote_chrome_request_human_intervention',
      'get_novnc_link',
      'create_temporary_novnc_link',
      'revoke_temporary_novnc_link',
    ]) {
      if (!byName.has(required))
        throw new RegressionError(`tools/list omitted ${required}`);
    }
    for (const handoff of [
      'remote_chrome_request_human_intervention',
      'get_novnc_link',
      'create_temporary_novnc_link',
      'revoke_temporary_novnc_link',
    ]) {
      const properties = byName.get(handoff).inputSchema?.properties || {};
      if (Object.keys(properties).length !== 0)
        throw new RegressionError(`${handoff} unexpectedly accepts arguments`);
    }

    let stableUrl;
    let guestVerified = false;
    if (configuration.exerciseHandoff) {
      const primary = resultText(await call('tools/call', {
        name: 'remote_chrome_request_human_intervention', arguments: {},
      }), 'remote_chrome_request_human_intervention');
      const alias = resultText(await call('tools/call', {
        name: 'get_novnc_link', arguments: {},
      }), 'get_novnc_link');
      stableUrl = stableHandoffUrl(primary);
      if (stableHandoffUrl(alias) !== stableUrl)
        throw new RegressionError('permanent handoff tools returned different URLs');
    }
    if (configuration.exerciseGuest) {
      try {
        const created = resultText(await call('tools/call', {
          name: 'create_temporary_novnc_link', arguments: {},
        }), 'create_temporary_novnc_link');
        if (stableHandoffUrl(created) !== stableUrl)
          throw new RegressionError('temporary handoff changed the permanent URL');
        guestHandoffUrl(created, stableUrl);
        guestVerified = true;
      } finally {
        const revoked = resultText(await call('tools/call', {
          name: 'revoke_temporary_novnc_link', arguments: {},
        }), 'revoke_temporary_novnc_link');
        if (!revoked.includes('is closed'))
          throw new RegressionError('temporary handoff revocation was not confirmed');
      }
    }

    if (configuration.snapshotOnly) {
      resultText(await call('tools/call', {
        name: 'browser_snapshot', arguments: {},
      }), 'browser_snapshot');
      const deletion = await request(endpoint, {
        ...options,
        method: 'DELETE',
        sessionId,
      });
      if (![200, 202, 204].includes(deletion.status))
        throw new RegressionError(`session deletion returned HTTP ${deletion.status}`);
      deleted = true;
      const afterDelete = await request(endpoint, {
        ...options,
        sessionId,
        payload: { jsonrpc: '2.0', id: id++, method: 'tools/list' },
      });
      if (afterDelete.status !== 404)
        throw new RegressionError(`deleted session returned HTTP ${afterDelete.status}, expected 404`);
      return {
        browserCalls: 1,
        deletionVerified: true,
        waitMs: 0,
        snapshotOnly: true,
        handoffVerified: Boolean(stableUrl),
        guestVerified,
      };
    }

    const page = encodeURIComponent(
      `<!doctype html><title>Unified MCP probe</title><main>${READY_MARKER}</main>` +
      `<button onclick="document.querySelector('main').textContent='${CLICKED_MARKER}'">` +
      `${BUTTON_NAME}</button>`,
    );
    await call('tools/call', {
      name: 'browser_navigate',
      arguments: { url: `data:text/html,${page}` },
    });
    const before = resultText(await call('tools/call', {
      name: 'browser_snapshot', arguments: {},
    }), 'browser_snapshot');
    if (!before.includes(READY_MARKER))
      throw new RegressionError('first snapshot did not observe the visible probe page');

    const waitMs = configuration.waitMs === undefined ? 35000 : configuration.waitMs;
    await new Promise(resolve => setTimeout(resolve, waitMs));
    const after = resultText(await call('tools/call', {
      name: 'browser_snapshot', arguments: {},
    }), 'browser_snapshot');
    if (!after.includes(READY_MARKER))
      throw new RegressionError('session lost the visible probe page during the idle wait');

    const escapedButtonName = BUTTON_NAME.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const buttonMatch = after.match(
      new RegExp(`button "${escapedButtonName}" \\[ref=([^\\]]+)\\]`),
    );
    if (!buttonMatch)
      throw new RegressionError('snapshot omitted the probe button reference');
    resultText(await call('tools/call', {
      name: 'browser_click',
      arguments: { element: BUTTON_NAME, target: buttonMatch[1] },
    }), 'browser_click');
    const clicked = resultText(await call('tools/call', {
      name: 'browser_snapshot', arguments: {},
    }), 'browser_snapshot');
    if (!clicked.includes(CLICKED_MARKER))
      throw new RegressionError('browser click did not update the visible probe page');

    const deletion = await request(endpoint, {
      ...options,
      method: 'DELETE',
      sessionId,
    });
    if (![200, 202, 204].includes(deletion.status))
      throw new RegressionError(`session deletion returned HTTP ${deletion.status}`);
    deleted = true;
    const afterDelete = await request(endpoint, {
      ...options,
      sessionId,
      payload: { jsonrpc: '2.0', id: id++, method: 'tools/list' },
    });
    if (afterDelete.status !== 404)
      throw new RegressionError(`deleted session returned HTTP ${afterDelete.status}, expected 404`);

    return {
      browserCalls: 5,
      deletionVerified: true,
      waitMs,
      snapshotOnly: false,
      handoffVerified: Boolean(stableUrl),
      guestVerified,
    };
  } finally {
    if (sessionId && !deleted) {
      await request(endpoint, { ...options, method: 'DELETE', sessionId })
        .catch(() => {});
    }
  }
}

async function main() {
  let configuration;
  try {
    configuration = parseArgs(process.argv.slice(2));
    if (configuration.help) {
      process.stdout.write(`${usage()}\n`);
      return;
    }
    const result = await runRegression(configuration);
    process.stdout.write(result.snapshotOnly
      ? 'PASS: read-only MCP snapshot canary and explicit deletion succeeded\n'
      : `PASS: unified MCP session survived ${result.browserCalls} browser calls, ` +
        `an idle wait, and explicit deletion\n`);
  } catch (error) {
    process.stderr.write(`FAIL: ${error instanceof RegressionError ? error.message : 'unexpected regression failure'}\n`);
    process.exitCode = 1;
  }
}

if (require.main === module)
  void main();

module.exports = {
  RegressionError,
  parseArgs,
  readBearerToken,
  runRegression,
  usage,
  validateEndpoint,
};
