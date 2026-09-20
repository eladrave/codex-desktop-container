'use strict';

const fs = require('node:fs');
const { createRequire } = require('node:module');
const net = require('node:net');
const path = require('node:path');

function loadMcpUtilsBundle() {
  if (process.argv[1]) {
    try {
      const cliRequire = createRequire(fs.realpathSync(process.argv[1]));
      return cliRequire('playwright-core/lib/utilsBundle');
    } catch {
      // Tests and nonstandard launchers may not resolve from their entrypoint.
    }
  }
  return require('playwright-core/lib/utilsBundle');
}

const {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  Server
} = loadMcpUtilsBundle();

const PATCHED = Symbol.for('remote-browser.inject-instructions.patched');
const HUMAN_HANDOFF_INPUT_SCHEMA = Object.freeze({
  type: 'object',
  properties: {},
  additionalProperties: false
});
const HUMAN_HANDOFF_ANNOTATIONS = Object.freeze({
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false
});
const GUEST_CONTROL_SOCKET = '/run/remote-browser/guest-control.sock';
const GUEST_CONTROL_TIMEOUT_MS = 45000;
const MAX_GUEST_CONTROL_RESPONSE_BYTES = 8192;
const HUMAN_HANDOFF_TOOLS = Object.freeze([
  Object.freeze({
    name: 'remote_chrome_request_human_intervention',
    description: [
      'Return the protected noVNC handoff URL when login, MFA, CAPTCHA, a',
      'security key, consent, or another human-only step is required.',
      'This tool accepts no credentials or verification data.'
    ].join(' '),
    inputSchema: HUMAN_HANDOFF_INPUT_SCHEMA,
    annotations: {
      title: 'Request human intervention',
      ...HUMAN_HANDOFF_ANNOTATIONS
    }
  }),
  Object.freeze({
    name: 'get_novnc_link',
    description: [
      'Return the protected token-embedded noVNC URL for the user to complete',
      'login, 2FA, CAPTCHA, a security key, consent, or another human-only',
      'browser step. This tool accepts no credentials or verification data.'
    ].join(' '),
    inputSchema: HUMAN_HANDOFF_INPUT_SCHEMA,
    annotations: {
      title: 'Get protected noVNC link',
      ...HUMAN_HANDOFF_ANNOTATIONS
    }
  }),
  Object.freeze({
    name: 'create_temporary_novnc_link',
    description: [
      'Create a single-use public noVNC guest link when the user explicitly',
      'says they cannot use Tailscale. The link and resulting session expire',
      'at the original 30-minute deadline. This also returns the permanent',
      'tailnet-only link. This tool accepts no arguments and temporarily',
      'enables public Tailscale Funnel access on a guest-only endpoint.'
    ].join(' '),
    inputSchema: HUMAN_HANDOFF_INPUT_SCHEMA,
    annotations: {
      title: 'Create temporary public noVNC link',
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: false,
      openWorldHint: true
    }
  }),
  Object.freeze({
    name: 'revoke_temporary_novnc_link',
    description: [
      'Immediately revoke the active temporary public noVNC guest session',
      'and remove its Funnel endpoint. This tool accepts no arguments.'
    ].join(' '),
    inputSchema: HUMAN_HANDOFF_INPUT_SCHEMA,
    annotations: {
      title: 'Revoke temporary public noVNC link',
      readOnlyHint: false,
      destructiveHint: true,
      idempotentHint: true,
      openWorldHint: true
    }
  })
]);
const HUMAN_HANDOFF_TOOL_NAMES = new Set(
  HUMAN_HANDOFF_TOOLS.map(tool => tool.name)
);
const FALLBACK = `REMOTE_CHROME_PLAYBOOK_FALLBACK=1

Snapshot the current page before navigating. After a timeout, snapshot again.
Stop and ask the user for human control when login, MFA, CAPTCHA, or a security key is required.
Never expose credentials, cookies, or tokens.`;

function humanHandoffUrl() {
  let configuredUrl = process.env.REMOTE_CHROME_LOGIN_TOKEN_URL;
  const configuredFile = process.env.REMOTE_CHROME_LOGIN_TOKEN_URL_FILE;
  if (!configuredUrl && configuredFile) {
    try {
      const fileStat = fs.lstatSync(configuredFile);
      const permissions = fileStat.mode & 0o777;
      if (
        !fileStat.isFile() ||
        fileStat.isSymbolicLink() ||
        fileStat.size > 2048 ||
        fileStat.uid !== 0 ||
        fileStat.gid !== process.getgid() ||
        permissions !== 0o440
      ) {
        return;
      }
      configuredUrl = fs.readFileSync(configuredFile, 'utf8').trim();
    } catch {
      return;
    }
  }
  if (!configuredUrl)
    return;

  try {
    const parsed = new URL(configuredUrl);
    const queryKeys = [...parsed.searchParams.keys()];
    const token = parsed.searchParams.get('token') || '';
    if (
      parsed.protocol !== 'https:' ||
      !parsed.hostname ||
      parsed.username ||
      parsed.password ||
      parsed.pathname !== '/login/' ||
      parsed.hash ||
      queryKeys.length !== 1 ||
      queryKeys[0] !== 'token' ||
      !/^[A-Za-z0-9_-]{32,128}$/.test(token)
    ) {
      return;
    }
    return configuredUrl;
  } catch {
    return;
  }
}

function humanHandoffResult(request) {
  const argumentsValue = request?.params?.arguments;
  if (
    argumentsValue &&
    (typeof argumentsValue !== 'object' ||
      Array.isArray(argumentsValue) ||
      Object.keys(argumentsValue).length)
  ) {
    return {
      content: [{
        type: 'text',
        text: 'This tool accepts no arguments. Do not send credentials or verification data to the MCP server.'
      }],
      isError: true
    };
  }

  const url = humanHandoffUrl();
  if (!url) {
    return {
      content: [{
        type: 'text',
        text: 'The protected human-handoff URL is unavailable. Ask the server operator to verify the remote browser configuration.'
      }],
      isError: true
    };
  }

  return {
    content: [{
      type: 'text',
      text: [
        'Human intervention is required.',
        'Ask the user to open this protected noVNC URL in a trusted browser and complete the visible human-only step:',
        url,
        '',
        'Do not send passwords, MFA or recovery codes, security-key data, or CAPTCHA answers to the agent.',
        'This reusable URL is a password-equivalent secret until the server credentials are rotated.',
        'When finished, tell the agent to take a fresh snapshot before continuing.'
      ].join('\n')
    }]
  };
}

function hasNoArguments(request) {
  const argumentsValue = request?.params?.arguments;
  return !argumentsValue || (
    typeof argumentsValue === 'object' &&
    !Array.isArray(argumentsValue) &&
    Object.keys(argumentsValue).length === 0
  );
}

function noArgumentsError() {
  return {
    content: [{
      type: 'text',
      text: 'This tool accepts no arguments. Do not send credentials or configuration data to the MCP server.'
    }],
    isError: true
  };
}

function guestControlRequest(action) {
  return new Promise((resolve, reject) => {
    let settled = false;
    let response = '';
    const socket = net.createConnection({ path: GUEST_CONTROL_SOCKET });
    const finish = (error, value) => {
      if (settled)
        return;
      settled = true;
      socket.destroy();
      if (error)
        reject(error);
      else
        resolve(value);
    };
    socket.setTimeout(GUEST_CONTROL_TIMEOUT_MS, () => {
      finish(new Error('guest access controller timed out'));
    });
    socket.on('error', () => {
      finish(new Error('guest access controller is unavailable'));
    });
    socket.on('connect', () => {
      socket.write(`${JSON.stringify({ action })}\n`);
    });
    socket.on('data', chunk => {
      response += chunk.toString('utf8');
      if (Buffer.byteLength(response) > MAX_GUEST_CONTROL_RESPONSE_BYTES) {
        finish(new Error('guest access controller returned an oversized response'));
        return;
      }
      const newline = response.indexOf('\n');
      if (newline === -1)
        return;
      if (response.slice(newline + 1).trim()) {
        finish(new Error('guest access controller returned multiple responses'));
        return;
      }
      try {
        finish(undefined, JSON.parse(response.slice(0, newline)));
      } catch {
        finish(new Error('guest access controller returned invalid data'));
      }
    });
    socket.on('end', () => {
      if (!settled)
        finish(new Error('guest access controller closed without a response'));
    });
  });
}

function validateGuestUrl(value, stableUrl) {
  try {
    const guest = new URL(value);
    const stable = new URL(stableUrl);
    const queryKeys = [...guest.searchParams.keys()];
    const token = guest.searchParams.get('token') || '';
    if (
      guest.protocol !== 'https:' ||
      guest.hostname !== stable.hostname ||
      guest.port !== '8443' ||
      guest.pathname !== '/guest/' ||
      guest.username || guest.password || guest.hash ||
      queryKeys.length !== 1 || queryKeys[0] !== 'token' ||
      !/^[A-Za-z0-9_-]{32,128}$/.test(token)
    ) {
      return;
    }
    return guest.href;
  } catch {
    return;
  }
}

async function createTemporaryGuestResult(request) {
  if (!hasNoArguments(request))
    return noArgumentsError();
  const stableUrl = humanHandoffUrl();
  if (!stableUrl) {
    return {
      content: [{ type: 'text', text: 'The permanent tailnet handoff URL is unavailable.' }],
      isError: true
    };
  }
  try {
    const result = await guestControlRequest('create');
    if (!result || result.ok !== true || result.state !== 'ISSUED')
      throw new Error('temporary guest access could not be created');
    const guestUrl = validateGuestUrl(result.guestUrl, stableUrl);
    const expiresAt = new Date(result.expiresAt);
    const remainingMs = expiresAt.getTime() - Date.now();
    if (!guestUrl || !Number.isFinite(expiresAt.getTime()) ||
        remainingMs <= 0 || remainingMs > 31 * 60 * 1000) {
      throw new Error('temporary guest access response failed validation');
    }
    return {
      content: [{
        type: 'text',
        text: [
          'Permanent tailnet-only noVNC link (bookmark this; it remains stable):',
          stableUrl,
          '',
          'Temporary public noVNC guest link (single-use; access ends at the stated deadline):',
          guestUrl,
          `Expires: ${expiresAt.toISOString()}`,
          '',
          'The guest link is password-equivalent and publicly reachable until redeemed or expired.',
          'Use a private browsing window on the guest machine and call revoke_temporary_novnc_link when finished.'
        ].join('\n')
      }]
    };
  } catch {
    return {
      content: [{
        type: 'text',
        text: 'Temporary public noVNC access is unavailable. The operator may need to enable Tailscale Funnel for this node.'
      }],
      isError: true
    };
  }
}

async function revokeTemporaryGuestResult(request) {
  if (!hasNoArguments(request))
    return noArgumentsError();
  try {
    const result = await guestControlRequest('revoke');
    if (!result || result.ok !== true || result.state !== 'CLOSED')
      throw new Error('temporary guest access was not closed');
    return {
      content: [{
        type: 'text',
        text: 'Temporary public noVNC access is closed. The permanent tailnet-only link is unchanged.'
      }]
    };
  } catch {
    return {
      content: [{
        type: 'text',
        text: 'Temporary guest-access cleanup could not be verified. Ask the operator to inspect the Funnel state before creating another link.'
      }],
      isError: true
    };
  }
}

if (!Server.prototype[PATCHED]) {
  const originalInitialize = Server.prototype._oninitialize;
  const originalSetRequestHandler = Server.prototype.setRequestHandler;

  Object.defineProperty(Server.prototype, PATCHED, { value: true });

  Server.prototype.setRequestHandler = function remoteBrowserSetRequestHandler(
    requestSchema,
    handler
  ) {
    if (requestSchema === ListToolsRequestSchema) {
      const wrappedListTools = async (...args) => {
        const result = await handler(...args);
        const tools = Array.isArray(result?.tools)
          ? result.tools.filter(
              tool => !HUMAN_HANDOFF_TOOL_NAMES.has(tool?.name)
            )
          : [];
        return { ...result, tools: [...tools, ...HUMAN_HANDOFF_TOOLS] };
      };
      return originalSetRequestHandler.call(this, requestSchema, wrappedListTools);
    }

    if (requestSchema === CallToolRequestSchema) {
      const wrappedCallTool = async (request, ...args) => {
        if (request?.params?.name === 'create_temporary_novnc_link')
          return createTemporaryGuestResult(request);
        if (request?.params?.name === 'revoke_temporary_novnc_link')
          return revokeTemporaryGuestResult(request);
        if (HUMAN_HANDOFF_TOOL_NAMES.has(request?.params?.name))
          return humanHandoffResult(request);
        return handler(request, ...args);
      };
      return originalSetRequestHandler.call(this, requestSchema, wrappedCallTool);
    }

    return originalSetRequestHandler.call(this, requestSchema, handler);
  };

  Server.prototype._oninitialize = async function remoteBrowserInitialize(request) {
    const configuredPath = process.env.REMOTE_BROWSER_PLAYBOOK;
    const playbookPath = configuredPath
      ? path.resolve(configuredPath)
      : path.resolve(__dirname, 'browser-playbook.md');

    let instructions = FALLBACK;
    try {
      const candidate = fs.readFileSync(playbookPath, 'utf8').trim();
      if (candidate)
        instructions = candidate;
      else
        console.error('[remote-browser] empty playbook; using fallback');
    } catch {
      console.error('[remote-browser] cannot read playbook; using fallback');
    }

    this._instructions = instructions;
    return originalInitialize.call(this, request);
  };
}
