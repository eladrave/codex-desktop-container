#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_dir}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

owner=lib/remote-browser/browser-owner.cjs
keeper=lib/remote-browser/mcp-keeper.cjs
runner=lib/remote-browser/run-playwright-mcp.sh

for file in "${owner}" "${keeper}" "${runner}"; do
  [[ -f "${file}" ]] || fail "missing browser lifecycle component: ${file}"
done

grep -Fq "chromium.launchPersistentContext(profileDir" "${owner}" ||
  fail 'browser owner does not own the persistent context'
grep -Fq "const binding = await browser.bind" "${owner}" ||
  fail 'browser owner does not bind the private pipe endpoint'
grep -Fq "chmod(endpoint, 0o600)" "${owner}" ||
  fail 'browser endpoint is not owner-only'
grep -Fq "browser.once('disconnected'" "${owner}" ||
  fail 'browser owner does not exit for supervisor recovery after a crash'

for protocol_step in \
  "method: 'initialize'" \
  "method: 'notifications/initialized'" \
  "call(sessionId, 'tools/list')" \
  "name: 'browser_tabs'" \
  "arguments: { action: 'list' }" \
  "request(undefined, sessionId, 'DELETE')"; do
  grep -Fq "${protocol_step}" "${keeper}" ||
    fail "keeper is missing protocol step: ${protocol_step}"
done
grep -Fq 'while (!stopping)' "${keeper}" ||
  fail 'keeper does not retry after browser or MCP recovery'
if rg -n "browser_(navigate|click|type|fill|press|evaluate)" "${keeper}"; then
  fail 'keeper must not mutate the visible browser'
fi

grep -Fq -- '--endpoint "${browser_endpoint}"' "${runner}" ||
  fail 'Playwright MCP does not attach to the owner endpoint'
grep -Fq 'endpoint.sock' "${runner}" ||
  fail 'Playwright MCP stable endpoint path changed unexpectedly'
if rg -n -- '--extension|extension-token|remote-debugging-(port|address)' \
  "${owner}" "${keeper}" "${runner}"; then
  fail 'browser lifecycle regressed to extension mode or TCP CDP'
fi

printf 'PASS: MCP keeper and private browser-owner contracts\n'
