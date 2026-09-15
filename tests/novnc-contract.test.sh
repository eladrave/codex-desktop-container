#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_dir}"

grep -Fq -- "-rfbauth \"\${password_file}\"" run-x11vnc.sh
grep -Fq -- '-listen 127.0.0.1' run-x11vnc.sh
grep -Fq -- '-no6' run-x11vnc.sh
grep -Fq -- "-display \"\${display}\"" run-x11vnc.sh
grep -Fq -- "-auth \"\${xauthority}\"" run-x11vnc.sh
if grep -Fq -- '-nopw' run-x11vnc.sh; then
  echo 'x11vnc must require its persistent VNC password.' >&2
  exit 1
fi

grep -Fq "\"\${tailscale_ip}:6080\"" run-novnc.sh
grep -Fq '127.0.0.1:5900' run-novnc.sh
if grep -Eq '0\.0\.0\.0:(5900|6080)' run-novnc.sh supervisord.conf; then
  echo 'VNC and noVNC must not listen on every container interface.' >&2
  exit 1
fi

grep -Fq '[program:x11vnc]' supervisord.conf
grep -Fq '[program:novnc]' supervisord.conf
if grep -Eq '^[[:space:]]+ports:' compose.yaml; then
  echo 'Compose must not publish noVNC, VNC, or browser-control ports.' >&2
  exit 1
fi
