#!/usr/bin/env bash
set -Eeuo pipefail

chrome_binary="${CODEX_CHROME_BINARY:-/usr/bin/google-chrome-stable}"
profile_dir="${CODEX_CHROME_PROFILE_DIR:-/home/codex/.config/google-chrome}"
restart_delay="${CODEX_CHROME_RESTART_DELAY:-3}"
run_once="${CODEX_CHROME_RUN_ONCE:-0}"

[[ -x "${chrome_binary}" ]] || {
  printf 'Chrome is not executable: %s\n' "${chrome_binary}" >&2
  exit 69
}
[[ "${restart_delay}" =~ ^[0-9]+$ ]] || {
  printf 'Invalid Chrome restart delay.\n' >&2
  exit 64
}
[[ "${run_once}" == 0 || "${run_once}" == 1 ]] || {
  printf 'CODEX_CHROME_RUN_ONCE must be 0 or 1.\n' >&2
  exit 64
}
install -d -m 0700 "${profile_dir}"
[[ -w "${profile_dir}" ]] || {
  printf 'Chrome profile is not writable: %s\n' "${profile_dir}" >&2
  exit 73
}

# Xfce can restore applications from an earlier session while also processing
# autostart entries. Allow only one managed runner for this profile and adopt
# any already-running Chrome until it exits instead of opening windows in a
# tight handoff loop.
lock_dir="${CODEX_CHROME_LOCK_DIR:-/run/codex-desktop/chrome-runner.lock}"
lock_owner="${lock_dir}/pid"
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

  rm -rf -- "${lock_dir}"
  mkdir "${lock_dir}" 2>/dev/null || return 1
  printf '%d\n' "$$" >"${lock_owner}"
}
release_lock() {
  local current_owner
  current_owner=
  if [[ -r "${lock_owner}" ]]; then
    read -r current_owner <"${lock_owner}" || current_owner=
  fi
  if [[ "${current_owner}" == "$$" ]]; then
    rm -rf -- "${lock_dir}"
  fi
}
if ! acquire_lock; then
  exit 0
fi
trap release_lock EXIT

chrome_args=(
  "--user-data-dir=${profile_dir}"
  --password-store=basic
  --no-first-run
  --no-default-browser-check
)

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

chrome_main_running() {
  local candidate command_line
  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    if [[ -r "/proc/${candidate}/cmdline" ]]; then
      command_line="$(tr '\0' ' ' <"/proc/${candidate}/cmdline")"
    else
      command_line="$(ps -p "${candidate}" -o command= 2>/dev/null || true)"
    fi
    [[ "${command_line}" == *"--user-data-dir=${profile_dir}"* ]] || continue
    [[ "${command_line}" == *" --type="* ]] && continue
    return 0
  done < <(pgrep -u "$(id -u)" -f "user-data-dir=${profile_dir}" || true)
  return 1
}

while true; do
  if [[ "${run_once}" == 0 ]]; then
    while chrome_main_running; do
      sleep "${restart_delay}"
    done
  fi

  set +e
  "${chrome_binary}" "${chrome_args[@]}" &
  child_pid=$!
  wait "${child_pid}"
  status=$?
  child_pid=
  set -e

  if [[ "${run_once}" == 1 ]]; then
    exit "${status}"
  fi

  printf 'Chrome exited with status %d; restarting in %d seconds.\n' \
    "${status}" "${restart_delay}" >&2
  sleep "${restart_delay}"
done
