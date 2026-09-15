#!/usr/bin/env bash
set -Eeuo pipefail

codex_binary="${CODEX_DESKTOP_BINARY:-/usr/bin/chatgpt}"
restart_delay="${CODEX_DESKTOP_RESTART_DELAY:-3}"
run_once="${CODEX_DESKTOP_RUN_ONCE:-0}"
lock_dir="${CODEX_DESKTOP_LOCK_DIR:-/run/codex-desktop/codex-runner.lock}"
lock_owner="${lock_dir}/pid"

[[ -x "${codex_binary}" ]] || {
  printf 'Codex desktop is not executable: %s\n' "${codex_binary}" >&2
  exit 69
}
[[ "${restart_delay}" =~ ^[0-9]+$ ]] || {
  echo 'Invalid Codex desktop restart delay.' >&2
  exit 64
}
[[ "${run_once}" == 0 || "${run_once}" == 1 ]] || {
  echo 'CODEX_DESKTOP_RUN_ONCE must be 0 or 1.' >&2
  exit 64
}

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
    if [[ "${existing_command}" == *run-codex-desktop* || \
      "${existing_command}" == *run-codex.sh* ]]; then
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

codex_main_running() {
  local candidate command_line
  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    if [[ -r "/proc/${candidate}/cmdline" ]]; then
      command_line="$(tr '\0' ' ' <"/proc/${candidate}/cmdline")"
    else
      command_line="$(ps -p "${candidate}" -o command= 2>/dev/null || true)"
    fi
    [[ "${command_line}" == *'/usr/lib/chatgpt/ChatGPT'* ]] || continue
    [[ "${command_line}" == *' --type='* ]] && continue
    return 0
  done < <(pgrep -u "$(id -u)" -f '/usr/lib/chatgpt/ChatGPT' || true)
  return 1
}

while true; do
  if [[ "${run_once}" == 0 ]]; then
    while codex_main_running; do
      sleep "${restart_delay}"
    done
  fi

  set +e
  "${codex_binary}" &
  child_pid=$!
  wait "${child_pid}"
  status=$?
  child_pid=
  set -e

  if [[ "${run_once}" == 1 ]]; then
    exit "${status}"
  fi

  printf 'Codex desktop exited with status %d; restarting in %d seconds.\n' \
    "${status}" "${restart_delay}" >&2
  sleep "${restart_delay}"
done
