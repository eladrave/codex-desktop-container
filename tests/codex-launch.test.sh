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

fake_codex="${test_dir}/chatgpt"
count_file="${test_dir}/count"
termination_marker="${test_dir}/terminated"
cat >"${fake_codex}" <<'EOF'
#!/usr/bin/env bash
count=0
if [[ -s "${CODEX_DESKTOP_TEST_COUNT}" ]]; then
  count="$(<"${CODEX_DESKTOP_TEST_COUNT}")"
fi
count=$((count + 1))
printf '%d\n' "${count}" >"${CODEX_DESKTOP_TEST_COUNT}"
if [[ "${count}" == 1 ]]; then
  exit 23
fi
trap 'touch "${CODEX_DESKTOP_TEST_TERMINATED}"; exit 0' TERM INT HUP
while true; do sleep 1; done
EOF
chmod 0755 "${fake_codex}"

CODEX_DESKTOP_BINARY="${fake_codex}" \
CODEX_DESKTOP_LOCK_DIR="${test_dir}/lock" \
CODEX_DESKTOP_RESTART_DELAY=0 \
CODEX_DESKTOP_TEST_COUNT="${count_file}" \
CODEX_DESKTOP_TEST_TERMINATED="${termination_marker}" \
  "${repo_dir}/run-codex.sh" &
runner_pid=$!

for _ in $(seq 1 50); do
  [[ "$(cat "${count_file}" 2>/dev/null || true)" == 2 ]] && break
  sleep 0.1
done
[[ "$(<"${count_file}")" == 2 ]]

CODEX_DESKTOP_BINARY="${fake_codex}" \
CODEX_DESKTOP_LOCK_DIR="${test_dir}/lock" \
CODEX_DESKTOP_RUN_ONCE=1 \
  "${repo_dir}/run-codex.sh"
[[ "$(<"${count_file}")" == 2 ]]

kill -TERM "${runner_pid}"
wait "${runner_pid}"
runner_pid=
[[ -e "${termination_marker}" ]]
[[ "$(<"${count_file}")" == 2 ]]
