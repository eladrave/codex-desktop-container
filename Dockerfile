# syntax=docker/dockerfile:1.7

ARG UBUNTU_BASE_IMAGE="ubuntu@sha256:561618e2c15bf2397621dd04f96926663a3b5616c189cf7e38db7e82f5c538ea"
ARG TAILSCALE_BASE_IMAGE="tailscale/tailscale@sha256:4107a12b1a0466bb3f2c968d5fa35acf509cd7865a958ce1af36724e9f016342"
ARG TAILSCALE_BINARY_PLATFORM="linux/amd64"
ARG TAILSCALE_BINARY_ARCH="amd64"
ARG TAILSCALE_ELF_MACHINE_HEX="3e00"
ARG DESKTOP_ARCH="amd64"
ARG INSTALL_CRD="1"

FROM --platform=${TAILSCALE_BINARY_PLATFORM} ${TAILSCALE_BASE_IMAGE} AS tailscale
FROM ${UBUNTU_BASE_IMAGE}

ARG TAILSCALE_BINARY_ARCH
ARG TAILSCALE_ELF_MACHINE_HEX
ARG DESKTOP_ARCH
ARG INSTALL_CRD

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
      org.opencontainers.image.description="Persistent Codex desktop with Chrome, noVNC, optional Chrome Remote Desktop, and Tailscale SSH" \
      org.opencontainers.image.source="https://github.com/eladrave/codex-desktop-container" \
      io.openai.chatgpt.version="${CHATGPT_VERSION}" \
      io.tailscale.binary.arch="${TAILSCALE_BINARY_ARCH}" \
      io.codex-desktop.image.arch="${DESKTOP_ARCH}" \
      io.google.chrome-remote-desktop.enabled="${INSTALL_CRD}" \
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
    CODEX_DESKTOP_TAILSCALE_ARCH=${TAILSCALE_BINARY_ARCH} \
    CODEX_DESKTOP_TAILSCALE_ELF_MACHINE_HEX=${TAILSCALE_ELF_MACHINE_HEX} \
    CODEX_DESKTOP_IMAGE_ARCH=${DESKTOP_ARCH} \
    CODEX_DESKTOP_CRD_ENABLED=${INSTALL_CRD} \
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
        iproute2 \
        jq \
        less \
        locales \
        openssh-client \
        novnc \
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
        websockify \
        xfce4-panel \
        xfce4-session \
        xfce4-settings \
        xfce4-terminal \
        xfconf \
        xfdesktop4 \
        xfwm4 \
        x11-xserver-utils \
        xauth \
        x11vnc \
        xvfb \
    && test -x /usr/bin/ss \
    && locale-gen en_US.UTF-8 \
    && groupadd --gid 10001 codex \
    && useradd --uid 10001 --gid 10001 --create-home --shell /bin/bash codex

RUN set -eux; \
    package_dir="$(mktemp -d)"; \
    curl --fail --location --retry 5 --retry-all-errors --output "${package_dir}/chatgpt.deb" "${CHATGPT_DEB_URL}"; \
    echo "${CHATGPT_DEB_SHA256}  ${package_dir}/chatgpt.deb" | sha256sum --check --strict; \
    if [ "${INSTALL_CRD}" = 1 ]; then \
      curl --fail --location --retry 5 --retry-all-errors --output "${package_dir}/chrome-remote-desktop.deb" "${CRD_DEB_URL}"; \
      echo "${CRD_DEB_SHA256}  ${package_dir}/chrome-remote-desktop.deb" | sha256sum --check --strict; \
    fi; \
    curl --fail --location --retry 5 --retry-all-errors --output "${package_dir}/google-chrome.deb" "${CHROME_DEB_URL}"; \
    echo "${CHROME_DEB_SHA256}  ${package_dir}/google-chrome.deb" | sha256sum --check --strict; \
    apt-get update; \
    set -- "${package_dir}/chatgpt.deb" "${package_dir}/google-chrome.deb"; \
    if [ "${INSTALL_CRD}" = 1 ]; then set -- "$@" "${package_dir}/chrome-remote-desktop.deb"; fi; \
    apt-get install -y --no-install-recommends "$@"; \
    test "$(dpkg-query -W -f='${Version}' chatgpt)" = "${CHATGPT_VERSION}"; \
    test "$(dpkg-query -W -f='${Architecture}' chatgpt)" = "${DESKTOP_ARCH}"; \
    test "$(dpkg-query -W -f='${Version}' google-chrome-stable)" = "${CHROME_VERSION}"; \
    test "$(dpkg-query -W -f='${Architecture}' google-chrome-stable)" = "${DESKTOP_ARCH}"; \
    test -x /usr/bin/chatgpt; \
    if [ "${INSTALL_CRD}" = 1 ]; then \
      test "$(dpkg-query -W -f='${Version}' chrome-remote-desktop)" = "${CRD_VERSION}"; \
      test -x /opt/google/chrome-remote-desktop/start-host; \
    else \
      ! dpkg-query -W chrome-remote-desktop >/dev/null 2>&1; \
    fi; \
    rm -rf "${package_dir}" /var/lib/apt/lists/*

RUN if [ "${INSTALL_CRD}" = 1 ]; then \
      mv /opt/google/chrome-remote-desktop/start-host \
        /opt/google/chrome-remote-desktop/start-host.real; \
    fi

COPY --from=tailscale /usr/local/bin/tailscale /usr/local/bin/tailscale
COPY --from=tailscale /usr/local/bin/tailscaled /usr/local/bin/tailscaled

RUN test "$(od -An -tx1 -j18 -N2 /usr/local/bin/tailscale | tr -d ' \n')" = \
      "${TAILSCALE_ELF_MACHINE_HEX}" \
    && test "$(od -An -tx1 -j18 -N2 /usr/local/bin/tailscaled | tr -d ' \n')" = \
      "${TAILSCALE_ELF_MACHINE_HEX}"

COPY start-host-wrapper.sh /usr/local/share/codex-desktop/start-host-wrapper
COPY chrome-remote-desktop.pam /etc/pam.d/chrome-remote-desktop
COPY chrome-remote-desktop-session /etc/chrome-remote-desktop-session
COPY supervisord.conf /etc/supervisor/conf.d/codex-desktop.conf
COPY entrypoint.sh /usr/local/sbin/codex-desktop-entrypoint
COPY run-session.sh /usr/local/sbin/run-codex-session
COPY run-local-desktop.sh /usr/local/sbin/run-codex-local-desktop
COPY run-crd.sh /usr/local/sbin/run-codex-crd
COPY configure-crd.sh /usr/local/bin/configure-chrome-remote-desktop
COPY configure-novnc.sh /usr/local/bin/configure-codex-novnc
COPY healthcheck.sh /usr/local/sbin/codex-desktop-healthcheck
COPY run-codex.sh /usr/local/sbin/run-codex-desktop
COPY run-chrome.sh /usr/local/sbin/run-codex-chrome
COPY run-x11vnc.sh /usr/local/sbin/run-codex-x11vnc
COPY run-novnc.sh /usr/local/sbin/run-codex-novnc
COPY codex-autostart.desktop /opt/codex-desktop-home-skel/.config/autostart/codex.desktop
COPY chrome-autostart.desktop /etc/xdg/autostart/codex-chrome.desktop

RUN chmod 0755 \
      /usr/local/bin/tailscale \
      /usr/local/bin/tailscaled \
      /usr/local/sbin/codex-desktop-entrypoint \
      /usr/local/sbin/run-codex-session \
      /usr/local/sbin/run-codex-local-desktop \
      /usr/local/sbin/run-codex-crd \
      /usr/local/bin/configure-chrome-remote-desktop \
      /usr/local/bin/configure-codex-novnc \
      /usr/local/sbin/codex-desktop-healthcheck \
      /usr/local/sbin/run-codex-desktop \
      /usr/local/sbin/run-codex-chrome \
      /usr/local/sbin/run-codex-x11vnc \
      /usr/local/sbin/run-codex-novnc \
      /etc/chrome-remote-desktop-session \
    && chmod 0644 /etc/pam.d/chrome-remote-desktop \
    && chmod 0644 \
      /etc/supervisor/conf.d/codex-desktop.conf \
      /opt/codex-desktop-home-skel/.config/autostart/codex.desktop \
      /etc/xdg/autostart/codex-chrome.desktop \
    && install -d -o codex -g codex -m 0700 \
      /home/codex/.cache \
      /home/codex/.codex \
      /home/codex/.local/share \
      /home/codex/Projects \
      /home/codex/.vnc \
    && install -d -m 0755 \
      /run/dbus \
      /run/tailscale \
      /var/lib/tailscale \
      /var/lib/codex-desktop-persistent \
    && if [ "${INSTALL_CRD}" = 1 ]; then \
      install -o root -g root -m 0755 \
        /usr/local/share/codex-desktop/start-host-wrapper \
        /opt/google/chrome-remote-desktop/start-host; \
      chmod 0755 /opt/google/chrome-remote-desktop/start-host.real; \
      install -d -o codex -g codex -m 0700 \
        /home/codex/.config/chrome-remote-desktop; \
      printf '%s\n' 'codex ALL=(root) NOPASSWD: /usr/bin/systemctl enable --now chrome-remote-desktop@codex' \
        > /etc/sudoers.d/codex-crd-systemctl; \
      chmod 0440 /etc/sudoers.d/codex-crd-systemctl; \
    else \
      rm -f \
        /usr/local/share/codex-desktop/start-host-wrapper \
        /usr/local/sbin/run-codex-crd \
        /usr/local/bin/configure-chrome-remote-desktop \
        /etc/pam.d/chrome-remote-desktop \
        /etc/chrome-remote-desktop-session; \
    fi \
    && ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html \
    && rm -f /etc/supervisor/conf.d/supervisord.conf

ARG VCS_REF=""
LABEL org.opencontainers.image.revision="${VCS_REF}"

WORKDIR /home/codex

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=5 \
  CMD ["/usr/local/sbin/codex-desktop-healthcheck"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/sbin/codex-desktop-entrypoint"]
