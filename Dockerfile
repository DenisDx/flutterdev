# syntax=docker/dockerfile:1.7

ARG BASE_IMAGE=ubuntu:26.04
FROM ${BASE_IMAGE}

ARG FLUTTER_CHANNEL=stable
ARG OPENCODE_CHANNEL=stable
ARG NODE_CHANNEL=lts
ARG DEV_UID=1000
ARG DEV_GID=1000
ARG ANDROID_API_LEVEL=36
ARG ANDROID_BUILD_TOOLS=36.0.0
ARG ANDROID_SYSTEM_IMAGE=system-images;android-36;google_apis;x86_64
ARG ANDROID_AVD_NAME=flutterdev_api36
ARG ANDROID_ACCEPT_LICENSES=false
ARG JDK_PACKAGE=openjdk-21-jdk

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    FLUTTER_SUPPRESS_ANALYTICS=true \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_API_LEVEL=${ANDROID_API_LEVEL} \
    ANDROID_BUILD_TOOLS=${ANDROID_BUILD_TOOLS} \
    ANDROID_SYSTEM_IMAGE=${ANDROID_SYSTEM_IMAGE} \
    ANDROID_AVD_NAME=${ANDROID_AVD_NAME}

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        coreutils \
        curl \
        findutils \
        git \
        jq \
        less \
        libglu1-mesa \
        mc \
        openssh-client \
        openssh-server \
        procps \
        python3 \
        python3-pip \
        python3-venv \
        ripgrep \
        unzip \
        xz-utils \
        zip \
        ${JDK_PACKAGE} \
        libpulse0 \
        libx11-6 \
        libxext6 \
        libxrender1 \
        libxcomposite1 \
        libxcursor1 \
        libxi6 \
        libxtst6 \
        libnss3 \
        libasound2t64 \
        libxkbcommon0 \
        libgbm1 \
        libxdamage1 \
        libxfixes3 \
        libxkbfile1 \
        libxrandr2; \
    rm -rf /var/lib/apt/lists/*

# Закомментированный блок Linux desktop toolchain.
# Включать только при необходимости сборки Linux desktop приложений.
# RUN set -eux; \
#     apt-get update; \
#     apt-get install -y --no-install-recommends \
#         clang \
#         cmake \
#         ninja-build \
#         pkg-config \
#         libgtk-3-dev \
#         libstdc++-14-dev \
#         libc++-dev \
#         libc++abi-dev \
#         g++; \
#     rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    if getent group "${DEV_GID}" >/dev/null; then \
        existing_group="$(getent group "${DEV_GID}" | cut -d: -f1)"; \
        if [ "${existing_group}" != "dev" ]; then \
            groupmod -n dev "${existing_group}"; \
        fi; \
    else \
        groupadd --gid "${DEV_GID}" dev; \
    fi; \
    if getent passwd "${DEV_UID}" >/dev/null; then \
        existing_user="$(getent passwd "${DEV_UID}" | cut -d: -f1)"; \
        if [ "${existing_user}" != "dev" ]; then \
            if [ -d /home/dev ]; then \
                usermod -l dev -d /home/dev "${existing_user}"; \
            else \
                usermod -l dev -d /home/dev -m "${existing_user}"; \
            fi; \
        fi; \
    else \
        useradd --uid "${DEV_UID}" --gid "${DEV_GID}" \
            --create-home --shell /bin/bash dev; \
    fi; \
    usermod -G "" dev; \
    usermod -p '*' dev; \
    install -d -o "${DEV_UID}" -g "${DEV_GID}" -m 755 /home/dev; \
    install -d -o "${DEV_UID}" -g "${DEV_GID}" -m 755 /home/dev/.config; \
    install -d -o "${DEV_UID}" -g "${DEV_GID}" -m 755 /home/dev/.local; \
    install -d -o "${DEV_UID}" -g "${DEV_GID}" -m 755 /home/dev/.android; \
    install -d -o "${DEV_UID}" -g "${DEV_GID}" -m 755 /home/dev/.cache; \
    install -d -o "${DEV_UID}" -g "${DEV_GID}" -m 755 /home/dev/.gradle; \
    install -d -o "${DEV_UID}" -g "${DEV_GID}" -m 755 /home/dev/.pub-cache; \
    install -d -o root -g root -m 755 /var/lib/flutterdev/ssh; \
    install -d -o root -g root -m 755 /etc/flutterdev/access; \
    install -d -o root -g root -m 755 /run/sshd

# Node.js: актуальная LTS по версии из https://nodejs.org/dist/index.json.
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) node_arch=x64 ;; \
        arm64) node_arch=arm64 ;; \
        *) echo "Unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL https://nodejs.org/dist/index.json -o /tmp/node-index.json; \
    if [ "${NODE_CHANNEL}" = "lts" ]; then \
        node_version="$(jq -r '[.[] | select(.lts != false)][0].version' /tmp/node-index.json)"; \
    elif [ "${NODE_CHANNEL}" = "current" ]; then \
        node_version="$(jq -r '.[0].version' /tmp/node-index.json)"; \
    else \
        node_version="${NODE_CHANNEL}"; \
    fi; \
    test -n "${node_version}" -a "${node_version}" != "null"; \
    curl -fsSL "https://nodejs.org/dist/${node_version}/node-${node_version}-linux-${node_arch}.tar.xz" \
        -o /tmp/node.tar.xz; \
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1; \
    node --version; \
    npm --version

# Flutter SDK: последний выпуск выбранного канала.
RUN set -eux; \
    case "${FLUTTER_CHANNEL}" in \
        stable|beta|dev|main) ;; \
        *) echo "Unsupported FLUTTER_CHANNEL: ${FLUTTER_CHANNEL}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json \
        -o /tmp/flutter-releases.json; \
    archive="$(jq -r --arg ch "${FLUTTER_CHANNEL}" \
        '.base_url + "/" + (.releases | map(select(.channel == $ch))[0].archive)' \
        /tmp/flutter-releases.json)"; \
    test -n "${archive}" -a "${archive}" != "null"; \
    curl -fsSL "${archive}" -o /tmp/flutter.tar.xz; \
    install -d -m 755 /opt; \
    tar -xJf /tmp/flutter.tar.xz -C /opt; \
    chown -R "${DEV_UID}:${DEV_GID}" /opt/flutter; \
    git config --system --add safe.directory /opt/flutter; \
    runuser -u dev -- env HOME=/home/dev PATH=/opt/flutter/bin:/usr/local/bin:/usr/bin:/bin \
        flutter config --no-analytics; \
    runuser -u dev -- env HOME=/home/dev PATH=/opt/flutter/bin:/usr/local/bin:/usr/bin:/bin \
        flutter precache --web; \
    runuser -u dev -- env HOME=/home/dev PATH=/opt/flutter/bin:/usr/local/bin:/usr/bin:/bin \
        flutter --version

# JDK: JAVA_HOME определяется по фактической установке.
RUN set -eux; \
    java_home="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"; \
    test -x "${java_home}/bin/java"; \
    ln -sfn "${java_home}" /opt/java-home; \
    /opt/java-home/bin/java -version

ENV JAVA_HOME=/opt/java-home

# Android SDK command-line tools, platform-tools, platforms, build-tools,
# emulator и выбранный system image.
RUN set -eux; \
    if [ "${ANDROID_ACCEPT_LICENSES}" != "true" ]; then \
        echo "Android SDK licenses not accepted: set ANDROID_ACCEPT_LICENSES=true" >&2; \
        exit 1; \
    fi; \
    install -d -o "${DEV_UID}" -g "${DEV_GID}" -m 755 /opt/android-sdk/cmdline-tools; \
    curl -fsSL https://dl.google.com/android/repository/repository2-3.xml -o /tmp/android-repo.xml; \
    cmdline_url="$(python3 -c 'import xml.etree.ElementTree as ET; r=ET.parse("/tmp/android-repo.xml").getroot(); print(next(((a.findtext("complete/url") or a.findtext("url")) for p in r.iter("remotePackage") if p.get("path")=="cmdline-tools;latest" for a in p.iter("archive") if a.findtext("host-os")=="linux"), ""))')"; \
    test -n "${cmdline_url}"; \
    case "${cmdline_url}" in \
        http*) ;; \
        *) cmdline_url="https://dl.google.com/android/repository/${cmdline_url}" ;; \
    esac; \
    curl -fsSL "${cmdline_url}" -o /tmp/cmdline-tools.zip; \
    unzip -q /tmp/cmdline-tools.zip -d /tmp/cmdline-tools; \
    rm -rf /opt/android-sdk/cmdline-tools/latest; \
    mv /tmp/cmdline-tools/cmdline-tools /opt/android-sdk/cmdline-tools/latest; \
    chown -R "${DEV_UID}:${DEV_GID}" /opt/android-sdk; \
    yes | runuser -u dev -- env \
        HOME=/home/dev \
        JAVA_HOME=/opt/java-home \
        ANDROID_HOME=/opt/android-sdk \
        PATH=/opt/java-home/bin:/opt/android-sdk/cmdline-tools/latest/bin:/usr/local/bin:/usr/bin:/bin \
        sdkmanager --sdk_root=/opt/android-sdk --licenses >/dev/null; \
    runuser -u dev -- env \
        HOME=/home/dev \
        JAVA_HOME=/opt/java-home \
        ANDROID_HOME=/opt/android-sdk \
        PATH=/opt/java-home/bin:/opt/android-sdk/cmdline-tools/latest/bin:/usr/local/bin:/usr/bin:/bin \
        sdkmanager --sdk_root=/opt/android-sdk --install \
            "platform-tools" \
            "platforms;android-${ANDROID_API_LEVEL}" \
            "build-tools;${ANDROID_BUILD_TOOLS}" \
            "emulator" \
            "${ANDROID_SYSTEM_IMAGE}"; \
    chown -R "${DEV_UID}:${DEV_GID}" /opt/android-sdk; \
    test -x /opt/android-sdk/platform-tools/adb; \
    test -x /opt/android-sdk/emulator/emulator; \
    /opt/android-sdk/platform-tools/adb version; \
    /opt/android-sdk/emulator/emulator -version | head -1

# OpenCode: последняя стабильная версия выбранного канала.
RUN set -eux; \
    if [ "${OPENCODE_CHANNEL}" = "stable" ]; then \
        package="opencode-ai@latest"; \
    else \
        package="opencode-ai@${OPENCODE_CHANNEL}"; \
    fi; \
    npm install -g --no-fund --no-audit "${package}"; \
    opencode --version

ENV PATH="/opt/flutter/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/opt/android-sdk/emulator:/usr/local/bin:${PATH}"

RUN printf '%s\n' \
        'export JAVA_HOME=/opt/java-home' \
        'export ANDROID_HOME=/opt/android-sdk' \
        'export ANDROID_SDK_ROOT=/opt/android-sdk' \
        'export FLUTTER_SUPPRESS_ANALYTICS=true' \
        'export PATH=/opt/flutter/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/opt/android-sdk/emulator:$PATH' \
        > /etc/profile.d/flutterdev.sh; \
    chmod 0644 /etc/profile.d/flutterdev.sh

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/check.sh /usr/local/bin/check.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/check.sh

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
