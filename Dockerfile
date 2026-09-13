# syntax=docker/dockerfile:1.7

ARG UBUNTU_BASE_IMAGE="ubuntu@sha256:561618e2c15bf2397621dd04f96926663a3b5616c189cf7e38db7e82f5c538ea"
ARG TAILSCALE_BASE_IMAGE="tailscale/tailscale@sha256:4107a12b1a0466bb3f2c968d5fa35acf509cd7865a958ce1af36724e9f016342"

FROM ${TAILSCALE_BASE_IMAGE} AS tailscale
FROM ${UBUNTU_BASE_IMAGE}

ARG CHATGPT_VERSION="26.820.60940"
ARG CHATGPT_DEB_URL="https://persistent.oaistatic.com/codex-app-prod/linux/deb/pool/main/c/chatgpt/chatgpt_26.820.60940_amd64.deb"
ARG CHATGPT_DEB_SHA256="31d956a8c6c515f8d87e0b7acd9ec919f7e685ba59331b4b97aa45f853afdfd7"
ARG CRD_VERSION="152.0.7977.9"
ARG CRD_DEB_URL="https://dl.google.com/linux/chrome-remote-desktop/deb/pool/main/c/chrome-remote-desktop/chrome-remote-desktop_152.0.7977.9_amd64.deb"
ARG CRD_DEB_SHA256="fc6e10808f589a0475ce20a0038c902701e9e59cfb0ac810a45116f8c057f9e7"
ARG CHROME_VERSION="152.0.7977.64-1"
ARG CHROME_DEB_URL="https://dl.google.com/linux/chrome/deb/pool/main/g/google-chrome-stable/google-chrome-stable_152.0.7977.64-1_amd64.deb"
ARG CHROME_DEB_SHA256="4eae0736a812d9bc851cd2937f7af00e47dbaf8305845eed452703ff009873c7"

LABEL org.opencontainers.image.title="codex-desktop" \
      org.opencontainers.image.description="Persistent Codex desktop with Chrome Remote Desktop and Tailscale SSH" \
      org.opencontainers.image.source="https://github.com/eladrave/codex-desktop-container" \
      io.openai.chatgpt.version="${CHATGPT_VERSION}" \
      io.google.chrome-remote-desktop.version="${CRD_VERSION}" \
      io.google.chrome.version="${CHROME_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    TZ=Etc/UTC \
    HOME=/home/codex \
    XDG_CONFIG_HOME=/home/codex/.config \
    XDG_CACHE_HOME=/home/codex/.cache \
    XDG_DATA_HOME=/home/codex/.local/share \
    CODEX_HOME=/home/codex/.codex \
    CODEX_DESKTOP_CHATGPT_VERSION=${CHATGPT_VERSION} \
    CODEX_DESKTOP_CRD_VERSION=${CRD_VERSION} \
    CODEX_DESKTOP_CHROME_VERSION=${CHROME_VERSION} \
    LIBGL_ALWAYS_SOFTWARE=1

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        dbus \
        dbus-x11 \
        fonts-dejavu-core \
        fonts-liberation \
        fonts-noto-color-emoji \
        git \
        jq \
        less \
        locales \
        openssh-client \
        procps \
        pulseaudio \
        ripgrep \
        sudo \
        supervisor \
        thunar \
        tini \
        tzdata \
        vim-tiny \
        wget \
        xfce4-panel \
        xfce4-session \
        xfce4-settings \
        xfce4-terminal \
        xfconf \
        xfdesktop4 \
        xfwm4 \
        x11-xserver-utils \
        xauth \
    && locale-gen en_US.UTF-8 \
    && groupadd --gid 10001 codex \
    && useradd --uid 10001 --gid 10001 --create-home --shell /bin/bash codex

RUN set -eux; \
    package_dir="$(mktemp -d)"; \
    curl --fail --location --retry 5 --retry-all-errors --output "${package_dir}/chatgpt.deb" "${CHATGPT_DEB_URL}"; \
    echo "${CHATGPT_DEB_SHA256}  ${package_dir}/chatgpt.deb" | sha256sum --check --strict; \
    curl --fail --location --retry 5 --retry-all-errors --output "${package_dir}/chrome-remote-desktop.deb" "${CRD_DEB_URL}"; \
    echo "${CRD_DEB_SHA256}  ${package_dir}/chrome-remote-desktop.deb" | sha256sum --check --strict; \
    curl --fail --location --retry 5 --retry-all-errors --output "${package_dir}/google-chrome.deb" "${CHROME_DEB_URL}"; \
    echo "${CHROME_DEB_SHA256}  ${package_dir}/google-chrome.deb" | sha256sum --check --strict; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      "${package_dir}/chatgpt.deb" \
      "${package_dir}/chrome-remote-desktop.deb" \
      "${package_dir}/google-chrome.deb"; \
    test "$(dpkg-query -W -f='${Version}' chatgpt)" = "${CHATGPT_VERSION}"; \
    test "$(dpkg-query -W -f='${Version}' chrome-remote-desktop)" = "${CRD_VERSION}"; \
    test "$(dpkg-query -W -f='${Version}' google-chrome-stable)" = "${CHROME_VERSION}"; \
    test -x /usr/bin/chatgpt; \
    test -x /opt/google/chrome-remote-desktop/start-host; \
    rm -rf "${package_dir}" /var/lib/apt/lists/*

RUN mv \
      /opt/google/chrome-remote-desktop/start-host \
      /opt/google/chrome-remote-desktop/start-host.real

COPY --from=tailscale /usr/local/bin/tailscale /usr/local/bin/tailscale
COPY --from=tailscale /usr/local/bin/tailscaled /usr/local/bin/tailscaled

COPY start-host-wrapper.sh /opt/google/chrome-remote-desktop/start-host
COPY chrome-remote-desktop.pam /etc/pam.d/chrome-remote-desktop
COPY chrome-remote-desktop-session /etc/chrome-remote-desktop-session
COPY supervisord.conf /etc/supervisor/conf.d/codex-desktop.conf
COPY entrypoint.sh /usr/local/sbin/codex-desktop-entrypoint
COPY run-crd.sh /usr/local/sbin/run-codex-crd
COPY configure-crd.sh /usr/local/bin/configure-chrome-remote-desktop
COPY healthcheck.sh /usr/local/sbin/codex-desktop-healthcheck
COPY codex-autostart.desktop /opt/codex-desktop-home-skel/.config/autostart/codex.desktop

RUN chmod 0755 \
      /usr/local/bin/tailscale \
      /usr/local/bin/tailscaled \
      /usr/local/sbin/codex-desktop-entrypoint \
      /usr/local/sbin/run-codex-crd \
      /usr/local/bin/configure-chrome-remote-desktop \
      /usr/local/sbin/codex-desktop-healthcheck \
      /opt/google/chrome-remote-desktop/start-host \
      /opt/google/chrome-remote-desktop/start-host.real \
      /etc/chrome-remote-desktop-session \
    && chmod 0644 /etc/pam.d/chrome-remote-desktop \
    && chmod 0644 \
      /etc/supervisor/conf.d/codex-desktop.conf \
      /opt/codex-desktop-home-skel/.config/autostart/codex.desktop \
    && install -d -o codex -g codex -m 0700 \
      /home/codex/.cache \
      /home/codex/.codex \
      /home/codex/.config/chrome-remote-desktop \
      /home/codex/.local/share \
      /home/codex/Projects \
    && install -d -m 0755 \
      /run/dbus \
      /run/tailscale \
      /var/lib/tailscale \
      /var/lib/codex-desktop-persistent \
    && printf '%s\n' 'codex ALL=(root) NOPASSWD: /usr/bin/systemctl enable --now chrome-remote-desktop@codex' \
      > /etc/sudoers.d/codex-crd-systemctl \
    && chmod 0440 /etc/sudoers.d/codex-crd-systemctl \
    && rm -f /etc/supervisor/conf.d/supervisord.conf

WORKDIR /home/codex

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=5 \
  CMD ["/usr/local/sbin/codex-desktop-healthcheck"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/sbin/codex-desktop-entrypoint"]
