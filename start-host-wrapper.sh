#!/usr/bin/env bash
set -Eeuo pipefail

real_start_host=/opt/google/chrome-remote-desktop/start-host.real
config_dir=/home/codex/.config/chrome-remote-desktop
expected_redirect='https://remotedesktop.google.com/_/oauthredirect'

if [[ ! -x "${real_start_host}" ]]; then
  echo "Chrome Remote Desktop's original start-host binary is unavailable." >&2
  exit 1
fi

# Some chat/terminal surfaces copy a URL as Markdown and escape underscores.
# Accept only the known Google OAuth redirect, normalize that presentation,
# and reject every other redirect without echoing the supplied value.
normalized_args=()
for arg in "$@"; do
  case "${arg}" in
    --redirect-url=*)
      redirect_value="${arg#--redirect-url=}"
      redirect_value="${redirect_value//\\_/_}"
      if [[ "${redirect_value}" == "[${expected_redirect}](${expected_redirect})" ]]; then
        redirect_value="${expected_redirect}"
      fi
      if [[ "${redirect_value}" != "${expected_redirect}" ]]; then
        echo "Invalid Chrome Remote Desktop redirect URL. Recopy the wizard command and retry." >&2
        exit 2
      fi
      normalized_args+=("--redirect-url=${expected_redirect}")
      ;;
    --user-name=codex)
      # The compatibility wrapper already selects the persistent desktop user.
      ;;
    --user-name=*|--corp-user=*|--cloud-user=*)
      echo "This container's Chrome Remote Desktop host must run as local user codex." >&2
      exit 2
      ;;
    *)
      normalized_args+=("${arg}")
      ;;
  esac
done

run_start_host() {
  set +e
  "${real_start_host}" "${normalized_args[@]}"
  status=$?
  set -e

  if compgen -G "${config_dir}/host#*.json" >/dev/null; then
    echo "Chrome Remote Desktop registration is present; the supervised host will start automatically."
    return 0
  fi
  return "${status}"
}

if [[ "$(id -u)" -eq 0 ]]; then
  exec setpriv \
    --reuid=10001 \
    --regid=10001 \
    --init-groups \
    env HOME=/home/codex USER=codex LOGNAME=codex SHELL=/bin/bash \
    /opt/google/chrome-remote-desktop/start-host "${normalized_args[@]}"
fi

if [[ "$(id -u)" -ne 10001 ]]; then
  echo "Chrome Remote Desktop setup must run as root or local user codex." >&2
  exit 2
fi

run_start_host
