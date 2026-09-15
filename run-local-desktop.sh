#!/usr/bin/env bash
set -Eeuo pipefail

display="${CODEX_DESKTOP_LOCAL_DISPLAY:-:20}"
runtime_dir="${CODEX_DESKTOP_RUNTIME_DIR:-/run/codex-desktop}"
session_file="${runtime_dir}/desktop.env"
xauthority="${CODEX_DESKTOP_XAUTHORITY:-${runtime_dir}/Xauthority}"
desktop_sizes="${CHROME_REMOTE_DESKTOP_DEFAULT_DESKTOP_SIZES:-1920x1080,2560x1440}"
desktop_size="${desktop_sizes%%,*}"

[[ "${display}" =~ ^:[0-9]+$ ]] || {
  echo 'Invalid local desktop display.' >&2
  exit 64
}
[[ "${desktop_size}" =~ ^[0-9]+x[0-9]+$ ]] || {
  echo 'Invalid local desktop size.' >&2
  exit 64
}

display_number="${display#:}"
rm -f -- "/tmp/.X${display_number}-lock" "/tmp/.X11-unix/X${display_number}"
install -d -m 0700 "${runtime_dir}"
touch "${xauthority}"
chmod 0600 "${xauthority}"
cookie="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
xauth -f "${xauthority}" add "${display}" MIT-MAGIC-COOKIE-1 "${cookie}"

Xvfb "${display}" \
  -auth "${xauthority}" \
  -screen 0 "${desktop_size}x24" \
  -nolisten tcp \
  -noreset &
xvfb_pid=$!
session_pid=

# Invoked indirectly by the signal trap below.
# shellcheck disable=SC2317,SC2329
terminate() {
  trap - TERM INT HUP
  if [[ -n "${session_pid}" ]] && kill -0 "${session_pid}" 2>/dev/null; then
    kill -TERM "${session_pid}" 2>/dev/null || true
    wait "${session_pid}" 2>/dev/null || true
  fi
  if kill -0 "${xvfb_pid}" 2>/dev/null; then
    kill -TERM "${xvfb_pid}" 2>/dev/null || true
    wait "${xvfb_pid}" 2>/dev/null || true
  fi
  exit 0
}
trap terminate TERM INT HUP

for _attempt in $(seq 1 100); do
  [[ -S "/tmp/.X11-unix/X${display_number}" ]] && break
  kill -0 "${xvfb_pid}" 2>/dev/null || {
    set +e
    wait "${xvfb_pid}"
    status=$?
    set -e
    exit "${status}"
  }
  sleep 0.1
done
[[ -S "/tmp/.X11-unix/X${display_number}" ]] || {
  echo 'Local Xvfb display did not become ready.' >&2
  exit 1
}

temporary_file="${session_file}.$$"
umask 077
printf 'DISPLAY=%s\nXAUTHORITY=%s\n' "${display}" "${xauthority}" \
  >"${temporary_file}"
mv -f "${temporary_file}" "${session_file}"

DISPLAY="${display}" XAUTHORITY="${xauthority}" \
  dbus-run-session -- xfce4-session &
session_pid=$!
set +e
wait "${session_pid}"
status=$?
session_pid=
set -e
kill -TERM "${xvfb_pid}" 2>/dev/null || true
wait "${xvfb_pid}" 2>/dev/null || true
exit "${status}"
