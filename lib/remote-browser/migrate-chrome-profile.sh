#!/usr/bin/env bash
set -Eeuo pipefail

legacy_profile="${CODEX_CHROME_LEGACY_PROFILE_DIR:-/home/codex/.config/google-chrome}"
target_profile="${CODEX_CHROME_PROFILE_DIR:-/home/codex/.config/remote-browser/chrome-profile}"
target_parent="$(dirname "${target_profile}")"

fail() {
  printf 'Chrome profile migration failed: %s\n' "$1" >&2
  exit 78
}

[[ "$(id -u)" == 0 ]] || fail 'must run as root before services start'
[[ "${legacy_profile}" == /home/codex/* && \
  "${target_profile}" == /home/codex/* && \
  "${legacy_profile}" != "${target_profile}" ]] || \
  fail 'profile paths are outside the persistent Codex home or overlap'

# Entrypoint invokes this before Supervisor. Never move or merge browser state
# while a browser can still hold locks or write to the source profile.
if pgrep -u 10001 -f '(/usr/bin/google-chrome|/opt/google/chrome|chrome_crashpad)' \
  >/dev/null 2>&1; then
  fail 'Chrome is running'
fi

install -d -o codex -g codex -m 0700 "${target_parent}"

if [[ -L "${legacy_profile}" ]]; then
  resolved_legacy="$(readlink -f -- "${legacy_profile}" 2>/dev/null || true)"
  resolved_target="$(readlink -f -- "${target_profile}" 2>/dev/null || true)"
  [[ -n "${resolved_target}" && "${resolved_legacy}" == "${resolved_target}" ]] || \
    fail 'legacy profile symlink does not point to the managed profile'
elif [[ -e "${legacy_profile}" ]]; then
  [[ -d "${legacy_profile}" ]] || fail 'legacy profile is not a directory'
  if [[ -e "${target_profile}" || -L "${target_profile}" ]]; then
    # Probing Chrome's default location may leave an empty directory. Replace
    # only that empty directory; never merge two profile trees.
    if [[ -d "${target_profile}" && ! -L "${target_profile}" ]] && \
      [[ -z "$(find "${legacy_profile}" -mindepth 1 -print -quit)" ]]; then
      rmdir -- "${legacy_profile}"
    else
      fail 'both legacy and managed Chrome profiles exist; refusing to merge'
    fi
  else
    [[ "$(stat -c '%u:%g' "${legacy_profile}")" == '10001:10001' ]] || \
      fail 'legacy profile ownership is not codex:codex'
    mv -- "${legacy_profile}" "${target_profile}"
  fi
fi

if [[ ! -e "${target_profile}" && ! -L "${target_profile}" ]]; then
  install -d -o codex -g codex -m 0700 "${target_profile}"
fi
[[ -d "${target_profile}" && ! -L "${target_profile}" ]] || \
  fail 'managed profile is not a directory'
[[ "$(stat -c '%u:%g' "${target_profile}")" == '10001:10001' ]] || \
  fail 'managed profile ownership is not codex:codex'

if [[ ! -e "${legacy_profile}" && ! -L "${legacy_profile}" ]]; then
  relative_target="$(realpath --relative-to="$(dirname "${legacy_profile}")" "${target_profile}")"
  setpriv --reuid=10001 --regid=10001 --init-groups \
    ln -s -- "${relative_target}" "${legacy_profile}"
fi

[[ -L "${legacy_profile}" ]] || fail 'legacy compatibility path is not a symlink'
[[ "$(readlink -f -- "${legacy_profile}")" == \
  "$(readlink -f -- "${target_profile}")" ]] || \
  fail 'legacy compatibility symlink target is invalid'

# These process locks can survive an unclean container stop. No browser is
# running here, so removing only Singleton* is safe and rollback-friendly.
rm -f -- "${target_profile}"/Singleton*
