'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const path = require('node:path');

const HOME = '/home/codex';
const CODEX_UID = 10001;

function safeFilename(value) {
  const filename = path.basename(String(value || '').replaceAll('\\', '/'))
    .replace(/[\x00-\x1f\x7f]/g, '_')
    .trim();
  if (!filename || filename === '.' || filename === '..')
    return 'download';
  if (Buffer.byteLength(filename, 'utf8') <= 180)
    return filename;

  // Linux's NAME_MAX is measured in bytes. Leave room for our collision
  // suffix and preserve a short extension when a website supplies one.
  const extension = path.extname(filename);
  const keepExtension = Buffer.byteLength(extension, 'utf8') <= 32;
  const suffix = keepExtension ? extension : '';
  const stem = keepExtension
    ? filename.slice(0, filename.length - extension.length)
    : filename;
  const budget = 180 - Buffer.byteLength(suffix, 'utf8');
  let shortened = '';
  for (const character of stem) {
    if (Buffer.byteLength(shortened + character, 'utf8') > budget)
      break;
    shortened += character;
  }
  return `${shortened || 'download'}${suffix}`;
}

async function writableDirectory(candidate, home, uid) {
  if (typeof candidate !== 'string' || !path.isAbsolute(candidate))
    return null;
  let resolved;
  try {
    resolved = await fs.realpath(candidate);
    const homeRealPath = await fs.realpath(home);
    const relative = path.relative(homeRealPath, resolved);
    if (relative.startsWith('..') || path.isAbsolute(relative))
      return null;
    const stat = await fs.stat(resolved);
    if (!stat.isDirectory() || stat.uid !== uid)
      return null;
    await fs.access(resolved, fs.constants.W_OK | fs.constants.X_OK);
  } catch {
    return null;
  }
  return resolved;
}

async function downloadDirectory(profileDir, options = {}) {
  const home = options.home || HOME;
  const uid = options.uid ?? CODEX_UID;
  try {
    const preferences = JSON.parse(await fs.readFile(
      path.join(profileDir, 'Default', 'Preferences'), 'utf8'));
    const preferred = await writableDirectory(
      preferences.download?.default_directory, home, uid);
    if (preferred)
      return preferred;
  } catch {
    // A new profile has no Preferences file. Chrome can also replace it while
    // saving settings. Use the persistent default in either case.
  }
  const fallback = await writableDirectory(path.join(home, 'Downloads'), home, uid);
  if (!fallback)
    throw new Error('persistent download directory is unavailable');
  return fallback;
}

async function persistDownload(download, profileDir, options = {}) {
  const directory = await downloadDirectory(profileDir, options);
  const filename = safeFilename(download.suggestedFilename());
  const extension = path.extname(filename);
  const stem = filename.slice(0, filename.length - extension.length);
  const temporary = path.join(directory, `.codex-download-${crypto.randomUUID()}.part`);

  try {
    await download.saveAs(temporary);
    for (let attempt = 0; attempt < 1000; attempt += 1) {
      const suffix = attempt === 0 ? '' : ` (${attempt})`;
      const candidate = path.join(directory, `${stem}${suffix}${extension}`);
      try {
        // Hard-linking is atomic and fails if a file with this name already
        // exists. A browser download must never overwrite an existing file.
        await fs.link(temporary, candidate);
        return candidate;
      } catch (error) {
        if (error.code !== 'EEXIST')
          throw error;
      }
    }
    throw new Error('download filename has too many collisions');
  } finally {
    await fs.rm(temporary, { force: true });
  }
}

module.exports = { persistDownload, safeFilename, downloadDirectory };
