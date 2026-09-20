#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_dir}"

grep -Fq -- '-listen 127.0.0.2' run-x11vnc.sh
grep -Fq -- '-no6' run-x11vnc.sh
grep -Fq -- '-noipv6' run-x11vnc.sh
grep -Eq -- '-rfbportv6([=[:space:]]+)-1' run-x11vnc.sh
grep -Fq -- '-nopw' run-x11vnc.sh
grep -Fq -- "-display \"\${display}\"" run-x11vnc.sh
grep -Fq -- "-auth \"\${xauthority}\"" run-x11vnc.sh
if grep -Fq -- '-rfbauth' run-x11vnc.sh; then
  echo 'The private raw VNC backend must not add a second password prompt.' >&2
  exit 1
fi

grep -Fq '127.0.0.2:6081' run-novnc.sh
grep -Fq '127.0.0.2:5900' run-novnc.sh
if grep -Eq '127\.0\.0\.1:(5900|6081)' run-novnc.sh run-x11vnc.sh; then
  echo 'VNC backends must not use the userspace-netstack forwarded localhost.' >&2
  exit 1
fi
if grep -Eq '0\.0\.0\.0:(5900|6081)' run-novnc.sh supervisord.conf; then
  echo 'VNC and noVNC must not listen on every container interface.' >&2
  exit 1
fi
if grep -Eq '\[::[01]?\]:(5900|6081)|(^|[^[:alnum:]]):::(5900|6081)' \
  run-novnc.sh run-x11vnc.sh supervisord.conf; then
  echo 'VNC and noVNC must not create bracketed IPv6 listeners.' >&2
  exit 1
fi

grep -Fq '[program:x11vnc]' supervisord.conf
grep -Fq '[program:novnc]' supervisord.conf
grep -Fq -- '--tun=userspace-networking' supervisord.conf
if grep -Eq '/dev/net/tun|NET_ADMIN|NET_RAW' compose.yaml; then
  echo 'Userspace Tailscale must not require a TUN device or network capabilities.' >&2
  exit 1
fi
if grep -Eq '^[[:space:]]+ports:' compose.yaml; then
  echo 'Compose must not publish noVNC, VNC, or browser-control ports.' >&2
  exit 1
fi

grep -Fq 'reverse_proxy 127.0.0.2:6081' lib/remote-browser/Caddyfile
grep -Fq '127.0.0.1:8443' lib/remote-browser/run-gateway.sh
