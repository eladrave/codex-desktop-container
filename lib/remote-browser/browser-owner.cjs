#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');

const UID_CODEX = 10001;
const profileDir = process.env.CODEX_CHROME_PROFILE_DIR ||
  '/home/codex/.config/remote-browser/chrome-profile';
const executablePath = process.env.CODEX_CHROME_BINARY ||
  '/usr/bin/google-chrome-stable';
const runtimeDir = process.env.REMOTE_BROWSER_RUNTIME_DIR ||
  '/run/remote-browser/browser';
const socketsDir = path.join(runtimeDir, 'sockets');
const endpointLink = process.env.REMOTE_BROWSER_BROWSER_ENDPOINT ||
  path.join(runtimeDir, 'endpoint.sock');
const keeperReadyFile = process.env.REMOTE_BROWSER_KEEPER_READY_FILE ||
  path.join(runtimeDir, 'keeper.ready');

function validatePathInside(parent, candidate, description) {
  const relative = path.relative(parent, candidate);
  if (!relative || relative.startsWith('..') || path.isAbsolute(relative))
    throw new Error(`${description} must be inside ${parent}`);
}

async function replaceEndpointLink(endpoint) {
  validatePathInside(runtimeDir, endpoint, 'bound endpoint');
  const endpointStat = await fs.promises.lstat(endpoint);
  if (!endpointStat.isSocket())
    throw new Error('Browser.bind did not create a Unix socket');
  await fs.promises.chmod(endpoint, 0o600);

  const temporaryLink = `${endpointLink}.${process.pid}.tmp`;
  await fs.promises.rm(temporaryLink, { force: true });
  await fs.promises.symlink(
    path.relative(path.dirname(endpointLink), endpoint),
    temporaryLink,
  );
  await fs.promises.rename(temporaryLink, endpointLink);
}

async function removeOwnedEndpointLink(endpoint) {
  try {
    const stat = await fs.promises.lstat(endpointLink);
    if (!stat.isSymbolicLink())
      return;
    const target = path.resolve(
      path.dirname(endpointLink),
      await fs.promises.readlink(endpointLink),
    );
    if (target === endpoint)
      await fs.promises.unlink(endpointLink);
  } catch (error) {
    if (error.code !== 'ENOENT')
      throw error;
  }
}

async function main() {
  if (process.getuid?.() !== UID_CODEX)
    throw new Error('must run as UID 10001');
  if (!path.isAbsolute(profileDir) || !path.isAbsolute(runtimeDir) ||
      !path.isAbsolute(endpointLink)) {
    throw new Error('profile and runtime paths must be absolute');
  }
  validatePathInside(runtimeDir, socketsDir, 'socket directory');
  validatePathInside(runtimeDir, endpointLink, 'stable endpoint');
  validatePathInside(runtimeDir, keeperReadyFile, 'keeper readiness file');

  const runtimeStat = await fs.promises.stat(runtimeDir);
  if (!runtimeStat.isDirectory() || runtimeStat.uid !== UID_CODEX ||
      (runtimeStat.mode & 0o077) !== 0) {
    throw new Error('private browser runtime directory permissions are invalid');
  }
  const profileStat = await fs.promises.stat(profileDir);
  if (!profileStat.isDirectory() || profileStat.uid !== UID_CODEX)
    throw new Error('persistent browser profile ownership is invalid');

  await fs.promises.rm(socketsDir, { recursive: true, force: true });
  await fs.promises.mkdir(socketsDir, { recursive: true, mode: 0o700 });
  await fs.promises.chmod(socketsDir, 0o700);
  await fs.promises.rm(endpointLink, { force: true });
  await fs.promises.rm(keeperReadyFile, { force: true });

  process.env.PWTEST_SOCKETS_DIR = socketsDir;
  let context;
  let endpoint;
  try {
    context = await chromium.launchPersistentContext(profileDir, {
      executablePath,
      headless: false,
      chromiumSandbox: true,
      handleSIGINT: false,
      handleSIGTERM: false,
      handleSIGHUP: false,
      viewport: null,
      ignoreDefaultArgs: ['--disable-extensions'],
      args: [
        '--password-store=basic',
        '--no-first-run',
        '--no-default-browser-check',
      ],
    });
    const browser = context.browser();
    if (!browser)
      throw new Error('persistent context did not expose its browser');

    const binding = await browser.bind('codex-desktop-shared-browser', {
      workspaceDir: '/home/codex/Projects',
      metadata: { owner: 'codex-desktop' },
    });
    endpoint = path.resolve(binding.endpoint);
    await replaceEndpointLink(endpoint);

    let stopping = false;
    const requestStop = () => {
      if (stopping)
        return;
      stopping = true;
      void context.close().catch(() => {});
    };
    process.once('SIGTERM', requestStop);
    process.once('SIGINT', requestStop);
    process.once('SIGHUP', requestStop);

    await new Promise(resolve => browser.once('disconnected', resolve));
  } finally {
    if (context)
      await context.close().catch(() => {});
    if (endpoint)
      await removeOwnedEndpointLink(endpoint);
  }
}

main().catch(error => {
  process.stderr.write(
    `Persistent browser owner failed: ${error instanceof Error ? error.message : 'unexpected error'}\n`,
  );
  process.exitCode = 78;
});
