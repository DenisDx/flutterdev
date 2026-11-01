#!/usr/bin/env bash
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*"; }
die() { printf '[entrypoint] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "entrypoint must run as root"

rm -rf /tmp/android-unknown

DEV_UID="${DEV_UID:-1000}"
DEV_GID="${DEV_GID:-1000}"
SSH_ENABLED="${SSH_ENABLED:-true}"
SSH_CONTAINER_PORT="${SSH_CONTAINER_PORT:-22}"
SSH_KEY_DIR=/var/lib/flutterdev/ssh
ACCESS_DIR=/etc/flutterdev/access
AUTHORIZED_KEYS="${ACCESS_DIR}/authorized_keys"
RUN_DIR=/run/sshd
ANDROID_HOME="${ANDROID_HOME:-/opt/android-sdk}"
JAVA_HOME="${JAVA_HOME:-/opt/java-home}"
ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-36}"
ANDROID_BUILD_TOOLS="${ANDROID_BUILD_TOOLS:-36.0.0}"

if [ -d /home/dev ]; then
    owner="$(stat -c '%u:%g' /home/dev)"
    if [ "${owner}" != "${DEV_UID}:${DEV_GID}" ]; then
        die "/home/dev is owned by ${owner}; expected ${DEV_UID}:${DEV_GID}. Fix ownership on the host."
    fi
fi

if [ -d /workspace ]; then
    ws_owner="$(stat -c '%u:%g' /workspace)"
    if [ "${ws_owner}" != "${DEV_UID}:${DEV_GID}" ]; then
        log "WARNING: /workspace is owned by ${ws_owner}; dev may be unable to write."
    fi
fi

install -d -m 0700 "${SSH_KEY_DIR}"
install -d -m 0755 "${RUN_DIR}"
if [ ! -d "${ACCESS_DIR}" ]; then
    log "WARNING: ${ACCESS_DIR} is not mounted; SSH public key login will fail."
fi

if [ ! -s "${AUTHORIZED_KEYS}" ]; then
    log "WARNING: ${AUTHORIZED_KEYS} is missing or empty; SSH public key login will fail."
fi

ensure_host_key() {
    local type="$1"
    local name="$2"
    local bits="${3:-}"
    if [ ! -s "${SSH_KEY_DIR}/${name}" ]; then
        log "generating SSH host key ${name}"
        if [ -n "${bits}" ]; then
            ssh-keygen -q -t "${type}" -b "${bits}" -N '' -f "${SSH_KEY_DIR}/${name}"
        else
            ssh-keygen -q -t "${type}" -N '' -f "${SSH_KEY_DIR}/${name}"
        fi
    fi
    chmod 0600 "${SSH_KEY_DIR}/${name}"
    if [ -f "${SSH_KEY_DIR}/${name}.pub" ]; then
        chmod 0644 "${SSH_KEY_DIR}/${name}.pub"
    fi
}

ensure_host_key ed25519 ssh_host_ed25519_key
ensure_host_key rsa ssh_host_rsa_key 3072

AVD_NAME="${ANDROID_AVD_NAME:-flutterdev_api36}"
SYSTEM_IMAGE="${ANDROID_SYSTEM_IMAGE:-system-images;android-36;google_apis;x86_64}"
SYSTEM_IMAGE_DIR="${ANDROID_HOME}/${SYSTEM_IMAGE//;/\/}"

if [ "${CREATE_AVD:-true}" = "true" ] \
    && [ -x "${ANDROID_HOME}/cmdline-tools/latest/bin/avdmanager" ] \
    && [ -d "${SYSTEM_IMAGE_DIR}" ] \
    && [ ! -f "/home/dev/.android/avd/${AVD_NAME}.ini" ]; then
    log "creating AVD ${AVD_NAME}"
    install -d -o "${DEV_UID}" -g "${DEV_GID}" -m 0755 /home/dev/.android /home/dev/.android/avd
    echo no | runuser -u dev -- env \
        HOME=/home/dev \
        JAVA_HOME="${JAVA_HOME}" \
        ANDROID_HOME="${ANDROID_HOME}" \
        ANDROID_SDK_ROOT="${ANDROID_HOME}" \
        PATH="${JAVA_HOME}/bin:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:/opt/flutter/bin:/usr/local/bin:/usr/bin:/bin" \
        avdmanager create avd -n "${AVD_NAME}" -k "${SYSTEM_IMAGE}" -d pixel_6 --force \
        || log "WARNING: could not create AVD ${AVD_NAME}"
fi

cat > "${RUN_DIR}/sshd_config" <<EOF
PidFile ${RUN_DIR}/sshd.pid
Port ${SSH_CONTAINER_PORT}
ListenAddress 0.0.0.0
HostKey ${SSH_KEY_DIR}/ssh_host_ed25519_key
HostKey ${SSH_KEY_DIR}/ssh_host_rsa_key
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM no
AuthorizedKeysFile ${AUTHORIZED_KEYS}
AllowUsers dev
AuthenticationMethods publickey
MaxAuthTries 3
StrictModes yes
UseDNS no
PrintMotd no
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding yes
PermitTunnel no
PermitUserEnvironment no
ClientAliveInterval 60
ClientAliveCountMax 3
AcceptEnv LANG LC_*
SetEnv PATH=/opt/flutter/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/opt/android-sdk/emulator:/usr/local/bin:/usr/bin:/bin JAVA_HOME=${JAVA_HOME} ANDROID_HOME=${ANDROID_HOME} ANDROID_SDK_ROOT=${ANDROID_HOME} ANDROID_API_LEVEL=${ANDROID_API_LEVEL} ANDROID_BUILD_TOOLS=${ANDROID_BUILD_TOOLS} ANDROID_AVD_NAME=${AVD_NAME} ANDROID_SYSTEM_IMAGE=${SYSTEM_IMAGE} FLUTTER_SUPPRESS_ANALYTICS=true
Subsystem sftp internal-sftp
EOF
chmod 0644 "${RUN_DIR}/sshd_config"

if [ "${SSH_ENABLED}" = "true" ]; then
    log "starting sshd on port ${SSH_CONTAINER_PORT}"
    exec /usr/sbin/sshd -D -e -f "${RUN_DIR}/sshd_config"
fi

log "SSH is disabled; keeping container alive"
exec sleep infinity
