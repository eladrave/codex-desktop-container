#!/usr/bin/env bash
set -Eeuo pipefail

profile_dir="${CODEX_CHROME_PROFILE_DIR:-/home/codex/.config/remote-browser/chrome-profile}"
session_file="${CODEX_DESKTOP_SESSION_FILE:-/run/codex-desktop/desktop.env}"
lock_dir="${CODEX_CHROME_LOCK_DIR:-/run/codex-desktop/chrome-runner.lock}"
lock_owner="${lock_dir}/pid"

fail() {
  printf 'Chrome owner cannot start: %s\n' "$1" >&2
  exit 78
}

[[ "$(id -u)" == 10001 ]] || fail 'must run as the codex user'
[[ -x /usr/local/bin/node ]] || fail 'Node.js is unavailable'
[[ -f /opt/codex-desktop/remote-browser/browser-owner.cjs ]] || \
  fail 'browser owner helper is unavailable'

# Both desktop launchers publish the active display here. Waiting keeps Chrome
# independently supervised without assuming a display or requiring a host GUI.
while true; do
  if [[ -f "${session_file}" && ! -L "${session_file}" ]] && \
    [[ "$(stat -c '%u:%g:%a' "${session_file}" 2>/dev/null || true)" == \
      '10001:10001:600' ]]; then
    display="$(sed -n 's/^DISPLAY=//p' "${session_file}" | head -n 1)"
    xauthority="$(sed -n 's/^XAUTHORITY=//p' "${session_file}" | head -n 1)"
    if [[ "${display}" =~ ^:[0-9]+$ && -r "${xauthority}" ]]; then
      break
    fi
  fi
  sleep 1
done

install -d -m 0700 "${profile_dir}"
[[ -w "${profile_dir}" ]] || fail "profile is not writable: ${profile_dir}"

acquire_lock() {
  local existing_pid existing_command
  if mkdir "${lock_dir}" 2>/dev/null; then
    printf '%d\n' "$$" >"${lock_owner}"
    return 0
  fi

  existing_pid=
  if [[ -r "${lock_owner}" ]]; then
    read -r existing_pid <"${lock_owner}" || existing_pid=
  fi
  if [[ "${existing_pid}" =~ ^[0-9]+$ ]] && \
    kill -0 "${existing_pid}" 2>/dev/null; then
    if [[ -r "/proc/${existing_pid}/cmdline" ]]; then
      existing_command="$(tr '\0' ' ' <"/proc/${existing_pid}/cmdline")"
    else
      existing_command="$(ps -p "${existing_pid}" -o command= 2>/dev/null || true)"
    fi
    if [[ "${existing_command}" == *run-codex-chrome* || \
      "${existing_command}" == *run-chrome.sh* ]]; then
      return 1
    fi
  fi

  rm -f -- "${lock_owner}"
  rmdir -- "${lock_dir}" 2>/dev/null || return 1
  mkdir "${lock_dir}" 2>/dev/null || return 1
  printf '%d\n' "$$" >"${lock_owner}"
}

release_lock() {
  local current_owner=
  if [[ -r "${lock_owner}" ]]; then
    read -r current_owner <"${lock_owner}" || current_owner=
  fi
  if [[ "${current_owner}" == "$$" ]]; then
    rm -f -- "${lock_owner}"
    rmdir -- "${lock_dir}" 2>/dev/null || true
  fi
}

if ! acquire_lock; then
  exit 0
fi
trap release_lock EXIT

child_pid=
terminate() {
  trap - TERM INT HUP
  if [[ -n "${child_pid}" ]] && kill -0 "${child_pid}" 2>/dev/null; then
    kill -TERM "${child_pid}" 2>/dev/null || true
    wait "${child_pid}" 2>/dev/null || true
  fi
  exit 0
}
trap terminate TERM INT HUP

export DISPLAY="${display}"
export XAUTHORITY="${xauthority}"
export CODEX_CHROME_PROFILE_DIR="${profile_dir}"

/usr/local/bin/node \
  /opt/codex-desktop/remote-browser/browser-owner.cjs &
child_pid=$!
set +e
wait "${child_pid}"
status=$?
set -e
child_pid=
exit "${status}"
