#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "${test_dir}"' EXIT

mkdir -p "${test_dir}/bin" "${test_dir}/runtime"
touch "${test_dir}/Xauthority"
cat >"${test_dir}/bin/dbus-run-session" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == -- && "$2" == xfce4-session ]]
EOF
chmod 0755 "${test_dir}/bin/dbus-run-session"

PATH="${test_dir}/bin:${PATH}" \
DISPLAY=:77 \
XAUTHORITY="${test_dir}/Xauthority" \
CODEX_DESKTOP_RUNTIME_DIR="${test_dir}/runtime" \
  "${repo_dir}/chrome-remote-desktop-session"

expected="${test_dir}/expected"
cat >"${expected}" <<EOF
DISPLAY=:77
XAUTHORITY=${test_dir}/Xauthority
EOF
cmp "${expected}" "${test_dir}/runtime/desktop.env"

if stat -c '%a' "${test_dir}/runtime/desktop.env" >/dev/null 2>&1; then
  session_mode="$(stat -c '%a' "${test_dir}/runtime/desktop.env")"
else
  session_mode="$(stat -f '%Lp' "${test_dir}/runtime/desktop.env")"
fi
[[ "${session_mode}" == 600 ]]
