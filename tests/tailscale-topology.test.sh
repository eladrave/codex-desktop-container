#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
gateway="${repo_dir}/lib/remote-browser/run-gateway.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Exercise the exact predicate used by the runtime without starting Caddy or
# mutating Tailscale. Function extraction stops before the command wrapper.
eval "$(sed -n '/^port_is_empty() {/,/^clear_owned_port() {/p' "${gateway}" | sed '$d')"

dns=device.example.ts.net
private='{"TCP":{"8443":{"HTTPS":true}},"Web":{"device.example.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8443"}}}}}'
public='{"TCP":{"443":{"HTTPS":true}},"Web":{"device.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8445"}}}},"AllowFunnel":{"device.example.ts.net:443":true}}'
combined='{"TCP":{"443":{"HTTPS":true},"8443":{"HTTPS":true}},"Web":{"device.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8445"}}},"device.example.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8443"}}}},"AllowFunnel":{"device.example.ts.net:443":true}}'

port_is_exact "${private}" "${dns}" 8443 http://127.0.0.1:8443 0 || \
  fail 'valid private Serve topology was rejected'
port_is_exact "${public}" "${dns}" 443 http://127.0.0.1:8445 1 || \
  fail 'valid public Funnel topology was rejected'
port_is_exact "${combined}" "${dns}" 443 http://127.0.0.1:8445 1 || \
  fail 'public Funnel did not coexist with private Serve'
port_is_exact "${combined}" "${dns}" 8443 http://127.0.0.1:8443 0 || \
  fail 'private Serve did not coexist with public Funnel'
port_is_empty '{}' 443 || fail 'empty port was not recognized'
! port_is_empty "${combined}" 443 || fail 'configured public port was considered empty'

extra_handler='{"TCP":{"443":{"HTTPS":true}},"Web":{"device.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8445"},"/login":{"Proxy":"http://127.0.0.1:8443"}}}},"AllowFunnel":{"device.example.ts.net:443":true}}'
wrong_proxy='{"TCP":{"443":{"HTTPS":true}},"Web":{"device.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8443"}}}},"AllowFunnel":{"device.example.ts.net:443":true}}'
foreground_shadow='{"TCP":{"443":{"HTTPS":true}},"Web":{"device.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8445"}}}},"AllowFunnel":{"device.example.ts.net:443":true},"Foreground":{"TCP":{"443":{"HTTPS":true}},"Web":{"device.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9999"}}}},"AllowFunnel":{"device.example.ts.net:443":true}}}'

! port_is_exact "${extra_handler}" "${dns}" 443 http://127.0.0.1:8445 1 || \
  fail 'extra public path handler was accepted'
! port_is_exact "${wrong_proxy}" "${dns}" 443 http://127.0.0.1:8445 1 || \
  fail 'wrong public proxy target was accepted'
! port_is_exact "${foreground_shadow}" "${dns}" 443 http://127.0.0.1:8445 1 || \
  fail 'foreground shadow configuration was accepted'

printf 'PASS: exact Tailscale Serve/Funnel topology predicates\n'
