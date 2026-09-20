#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const MCP_ROOT = '/usr/local/lib/node_modules/@playwright/mcp';
const EXPECTED_MCP_VERSION = '0.0.82';
const EXPECTED_CORE_VERSION = '1.64.0-alpha-1789764292000';
const EXPECTED_CORE_BUNDLE_SHA256 =
  '728ee6ffd51548f3b200a442749421b039a21621775ec751bff33d10a05b2637';

function fail(message) {
  process.stderr.write(`Playwright lifecycle verification failed: ${message}\n`);
  process.exit(1);
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function count(source, literal) {
  return source.split(literal).length - 1;
}

const mcpPackage = readJson(path.join(MCP_ROOT, 'package.json'));
const coreRoot = path.join(MCP_ROOT, 'node_modules/playwright-core');
const corePackage = readJson(path.join(coreRoot, 'package.json'));
const bundleFile = path.join(coreRoot, 'lib/coreBundle.js');
const bundle = fs.readFileSync(bundleFile, 'utf8');
const bundleHash = crypto.createHash('sha256').update(bundle).digest('hex');

if (mcpPackage.version !== EXPECTED_MCP_VERSION)
  fail(`expected MCP ${EXPECTED_MCP_VERSION}, got ${mcpPackage.version}`);
if (corePackage.version !== EXPECTED_CORE_VERSION)
  fail(`expected playwright-core ${EXPECTED_CORE_VERSION}, got ${corePackage.version}`);
if (bundleHash !== EXPECTED_CORE_BUNDLE_SHA256)
  fail('the pinned upstream core bundle hash changed');

const requiredFragments = [
  // A disconnected shared browser invalidates the cached promise so the next
  // MCP client reconnects instead of receiving a stale browser with no context.
  'shared2.browser.once("disconnected", () => {',
  'if (sharedBrowserPromise === promise2)',
  'sharedBrowserPromise = void 0;',
  // Context creation cannot pass undefined into BrowserBackend.
  'browser.contexts()[0] ?? await browser.newContext(config.browser.contextOptions)',
  // Failed connection/context creation and normal disposal balance ownership.
  'clientCount--;',
  'if (this._disposed)',
  // Extension-mode relay teardown follows the browser disconnect.
  'browser.on("disconnected", () => relay.stop());'
];
for (const fragment of requiredFragments) {
  if (!bundle.includes(fragment))
    fail(`required upstream lifecycle behavior is absent: ${fragment}`);
}
if (count(bundle, 'clientCount--;') < 3)
  fail('shared-browser ownership is not balanced across failure and disposal paths');

for (const forbiddenMarker of [
  'REMOTE_CHROME_MCP_HTTP_SESSION_PATCH=1',
  'REMOTE_CHROME_MCP_LIFECYCLE_PATCH=1'
]) {
  if (bundle.includes(forbiddenMarker))
    fail('the stock upstream bundle contains a local remotechromemcp patch marker');
}

process.stdout.write(
  `PASS: stock Playwright MCP ${EXPECTED_MCP_VERSION} lifecycle recovery verified\n`
);
