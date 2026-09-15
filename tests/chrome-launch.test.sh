#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
runner_pid=
cleanup() {
  if [[ -n "${runner_pid}" ]] && kill -0 "${runner_pid}" 2>/dev/null; then
    kill -TERM "${runner_pid}" 2>/dev/null || true
    wait "${runner_pid}" 2>/dev/null || true
  fi
  rm -rf -- "${test_dir}"
}
trap cleanup EXIT

fake_chrome="${test_dir}/google-chrome-stable"
captured_args="${test_dir}/args"
profile_dir="${test_dir}/profile"

cat >"${fake_chrome}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${CODEX_CHROME_CAPTURE_ARGS}"
EOF
chmod 0755 "${fake_chrome}"

CODEX_CHROME_BINARY="${fake_chrome}" \
CODEX_CHROME_CAPTURE_ARGS="${captured_args}" \
CODEX_CHROME_PROFILE_DIR="${profile_dir}" \
CODEX_CHROME_LOCK_DIR="${test_dir}/run-once-lock" \
CODEX_CHROME_RUN_ONCE=1 \
  "${repo_dir}/run-chrome.sh"

expected_args="${test_dir}/expected"
cat >"${expected_args}" <<EOF
--user-data-dir=${profile_dir}
--password-store=basic
--no-first-run
--no-default-browser-check
EOF

cmp "${expected_args}" "${captured_args}"
if stat -c '%a' "${profile_dir}" >/dev/null 2>&1; then
  profile_mode="$(stat -c '%a' "${profile_dir}")"
else
  profile_mode="$(stat -f '%Lp' "${profile_dir}")"
fi
[[ "${profile_mode}" == 700 ]]

if grep -Fq -- '--no-sandbox' "${captured_args}"; then
  echo 'Chrome sandbox must remain enabled.' >&2
  exit 1
fi

if grep -Eq -- '--remote-debugging-(port|address)' "${captured_args}"; then
  echo 'Raw CDP must remain mediated by the Codex browser integration.' >&2
  exit 1
fi

# A stale lock that happens to name an unrelated live PID must not suppress the
# managed browser runner.
stale_lock="${test_dir}/stale-lock"
stale_args="${test_dir}/stale-args"
mkdir "${stale_lock}"
printf '%d\n' "$$" >"${stale_lock}/pid"
CODEX_CHROME_BINARY="${fake_chrome}" \
CODEX_CHROME_CAPTURE_ARGS="${stale_args}" \
CODEX_CHROME_PROFILE_DIR="${test_dir}/stale-profile" \
CODEX_CHROME_LOCK_DIR="${stale_lock}" \
CODEX_CHROME_RUN_ONCE=1 \
  "${repo_dir}/run-chrome.sh"
[[ -s "${stale_args}" ]]

lifecycle_chrome="${test_dir}/lifecycle-chrome"
lifecycle_count="${test_dir}/lifecycle-count"
termination_marker="${test_dir}/child-terminated"
lifecycle_profile="${test_dir}/lifecycle-profile"

cat >"${lifecycle_chrome}" <<'EOF'
#!/usr/bin/env bash
count=0
if [[ -s "${CODEX_CHROME_LIFECYCLE_COUNT}" ]]; then
  count="$(<"${CODEX_CHROME_LIFECYCLE_COUNT}")"
fi
count=$((count + 1))
printf '%d\n' "${count}" >"${CODEX_CHROME_LIFECYCLE_COUNT}"
if [[ "${count}" == 1 ]]; then
  exit 23
fi
trap 'touch "${CODEX_CHROME_TERMINATION_MARKER}"; exit 0' TERM INT HUP
while true; do
  sleep 1
done
EOF
chmod 0755 "${lifecycle_chrome}"

CODEX_CHROME_BINARY="${lifecycle_chrome}" \
CODEX_CHROME_PROFILE_DIR="${lifecycle_profile}" \
CODEX_CHROME_LOCK_DIR="${test_dir}/lifecycle-lock" \
CODEX_CHROME_RESTART_DELAY=0 \
CODEX_CHROME_LIFECYCLE_COUNT="${lifecycle_count}" \
CODEX_CHROME_TERMINATION_MARKER="${termination_marker}" \
  "${repo_dir}/run-chrome.sh" &
runner_pid=$!

for _ in $(seq 1 50); do
  [[ "$(cat "${lifecycle_count}" 2>/dev/null || true)" == 2 ]] && break
  sleep 0.1
done
[[ "$(<"${lifecycle_count}")" == 2 ]]

# A duplicate Xfce/autostart invocation must observe the profile lock and exit
# without starting another Chrome process.
CODEX_CHROME_BINARY="${lifecycle_chrome}" \
CODEX_CHROME_PROFILE_DIR="${lifecycle_profile}" \
CODEX_CHROME_LOCK_DIR="${test_dir}/lifecycle-lock" \
CODEX_CHROME_RESTART_DELAY=0 \
CODEX_CHROME_LIFECYCLE_COUNT="${lifecycle_count}" \
CODEX_CHROME_TERMINATION_MARKER="${termination_marker}" \
  "${repo_dir}/run-chrome.sh"
[[ "$(<"${lifecycle_count}")" == 2 ]]

kill -TERM "${runner_pid}"
wait "${runner_pid}"
runner_pid=
[[ -e "${termination_marker}" ]]
[[ "$(<"${lifecycle_count}")" == 2 ]]
