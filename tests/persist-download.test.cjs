'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');
const { persistDownload, safeFilename } = require('../lib/remote-browser/persist-download.cjs');

test('saves downloads under the preferred persistent directory without overwriting files', async () => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), 'codex-download-test-'));
  try {
    const downloads = path.join(home, 'Downloads');
    const projects = path.join(home, 'Projects');
    const profile = path.join(home, 'profile');
    await fs.mkdir(downloads);
    await fs.mkdir(projects);
    await fs.mkdir(path.join(profile, 'Default'), { recursive: true });
    await fs.writeFile(path.join(profile, 'Default', 'Preferences'),
      JSON.stringify({ download: { default_directory: projects } }));
    await fs.writeFile(path.join(projects, 'report.txt'), 'existing');

    const download = {
      suggestedFilename: () => 'report.txt',
      saveAs: target => fs.writeFile(target, 'new download'),
    };
    const saved = await persistDownload(download, profile, {
      home, uid: process.getuid(),
    });
    assert.equal(saved, path.join(await fs.realpath(projects), 'report (1).txt'));
    assert.equal(await fs.readFile(path.join(projects, 'report.txt'), 'utf8'), 'existing');
    assert.equal(await fs.readFile(saved, 'utf8'), 'new download');
    assert.deepEqual((await fs.readdir(projects)).sort(), ['report (1).txt', 'report.txt']);
  } finally {
    await fs.rm(home, { recursive: true, force: true });
  }
});

test('rejects an external preference and sanitizes a hostile suggested name', async () => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), 'codex-download-test-'));
  try {
    const downloads = path.join(home, 'Downloads');
    const profile = path.join(home, 'profile');
    await fs.mkdir(downloads);
    await fs.mkdir(path.join(profile, 'Default'), { recursive: true });
    await fs.writeFile(path.join(profile, 'Default', 'Preferences'),
      JSON.stringify({ download: { default_directory: '/tmp' } }));

    const saved = await persistDownload({
      suggestedFilename: () => '../../outside.txt',
      saveAs: target => fs.writeFile(target, 'safe'),
    }, profile, { home, uid: process.getuid() });
    assert.equal(saved, path.join(await fs.realpath(downloads), 'outside.txt'));
    assert.equal(await fs.readFile(saved, 'utf8'), 'safe');
    assert.equal(safeFilename('..\\danger.txt'), 'danger.txt');
    const unicodeName = safeFilename(`${'報'.repeat(100)}.txt`);
    assert.ok(Buffer.byteLength(unicodeName, 'utf8') <= 180);
    assert.ok(unicodeName.endsWith('.txt'));
  } finally {
    await fs.rm(home, { recursive: true, force: true });
  }
});
