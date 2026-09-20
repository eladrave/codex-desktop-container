#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_dir}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

bash -n run-chrome.sh lib/remote-browser/migrate-chrome-profile.sh
node --check lib/remote-browser/browser-owner.cjs

grep -Fq '/home/codex/.config/remote-browser/chrome-profile' run-chrome.sh ||
  fail 'Chrome runner does not select the nondefault persistent profile'
grep -Fq '/run/codex-desktop/desktop.env' run-chrome.sh ||
  fail 'Chrome runner does not wait for the managed display'
grep -Fq '/opt/codex-desktop/remote-browser/browser-owner.cjs' run-chrome.sh ||
  fail 'Chrome runner does not delegate to the single browser owner'
grep -Fq 'user=codex' supervisord.conf ||
  fail 'browser owner must run as the desktop user'
grep -Fq '[program:remote-browser-owner]' supervisord.conf ||
  fail 'browser owner is not independently supervised'

if rg -n -- '--remote-debugging-(port|address)|--no-sandbox|--disable-setuid-sandbox' \
  run-chrome.sh lib/remote-browser/browser-owner.cjs supervisord.conf; then
  fail 'persistent Chrome regressed to TCP CDP or a disabled sandbox'
fi
grep -Fq "ignoreDefaultArgs: ['--disable-extensions']" \
  lib/remote-browser/browser-owner.cjs ||
  fail 'persistent Chrome does not preserve installed extensions'
grep -Fq 'chromiumSandbox: true' lib/remote-browser/browser-owner.cjs ||
  fail 'persistent Chrome does not explicitly retain its sandbox'

grep -Fq 'refusing to merge' lib/remote-browser/migrate-chrome-profile.sh ||
  fail 'profile migration does not fail closed on two populated profiles'
grep -Fq 'must run as root before services start' \
  lib/remote-browser/migrate-chrome-profile.sh ||
  fail 'profile migration is not constrained to entrypoint startup'
grep -Fq 'rm -f -- "${target_profile}"/Singleton*' \
  lib/remote-browser/migrate-chrome-profile.sh ||
  fail 'profile migration does not clear only stale Chrome locks'
if rg -n 'rm[[:space:]]+-rf' run-chrome.sh \
  lib/remote-browser/migrate-chrome-profile.sh; then
  fail 'browser lifecycle must not recursively delete profile or lock state'
fi

printf 'PASS: persistent headed Chrome owner and profile migration contracts\n'
