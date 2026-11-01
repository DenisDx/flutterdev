#!/usr/bin/env bash
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*"; }
die() { printf '[entrypoint] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "entrypoint must run as root"

rm -rf /tmp/android-unknown

DEV_UID="${DEV_UID:?DEV_UID is required}"
DEV_GID="${DEV_GID:?DEV_GID is required}"
SSH_ENABLED="${SSH_ENABLED:-true}"
SSH_CONTAINER_PORT="${SSH_CONTAINER_PORT:?SSH_CONTAINER_PORT is required}"
WEB_CONTAINER_PORT="${WEB_CONTAINER_PORT:?WEB_CONTAINER_PORT is required}"
SSH_KEY_DIR=/var/lib/flutterdev/ssh
ACCESS_DIR=/etc/flutterdev/access
AUTHORIZED_KEYS="${ACCESS_DIR}/authorized_keys"
RUN_DIR=/run/sshd
ANDROID_HOME="${ANDROID_HOME:-/opt/android-sdk}"
JAVA_HOME="${JAVA_HOME:-/opt/java-home}"
ANDROID_API_LEVEL="${ANDROID_API_LEVEL:?ANDROID_API_LEVEL is required}"
ANDROID_BUILD_TOOLS="${ANDROID_BUILD_TOOLS:?ANDROID_BUILD_TOOLS is required}"

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

AVD_NAME="${ANDROID_AVD_NAME:?ANDROID_AVD_NAME is required}"
SYSTEM_IMAGE="${ANDROID_SYSTEM_IMAGE:?ANDROID_SYSTEM_IMAGE is required}"
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

install -d -m 0755 /run/flutterdev
jq -n \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg container "flutterdev" \
    --arg network "${DOCKER_NETWORK:-}" \
    --arg workspace "/workspace" \
    --arg web_internal_url "http://flutterdev:${WEB_CONTAINER_PORT}" \
    --arg web_container_port "${WEB_CONTAINER_PORT}" \
    --arg browser_render_url "http://flutterdev:${WEB_CONTAINER_PORT}" \
    --arg browser_mcp_url "${PLAYWRIGHT_MCP_URL:-}" \
    --arg searxng_mcp_url "${SEARXNG_MCP_URL:-}" \
    --arg local_llm_base_url "${LOCAL_LLM_BASE_URL:-}" \
    --arg local_llm_model "${LOCAL_LLM_MODEL:-}" \
    --arg opencode_go_base_url "${OPENCODE_GO_BASE_URL:-}" \
    --arg android_avd "${ANDROID_AVD_NAME}" \
    --arg android_system_image "${ANDROID_SYSTEM_IMAGE}" \
    --arg android_sdk "${ANDROID_HOME}" \
    --arg flutter_bin "/opt/flutter/bin/flutter" \
    --arg dart_bin "/opt/flutter/bin/dart" \
    --arg java_home "${JAVA_HOME}" \
    --arg opencode_config "/home/dev/.config/opencode/opencode.jsonc" \
    --arg agents_file "/workspace/AGENTS.md" \
    --arg ssh_container_port "${SSH_CONTAINER_PORT}" \
    '{
        generated_at: $generated_at,
        container: $container,
        network: $network,
        workspace: $workspace,
        web: {
            internal_url: $web_internal_url,
            container_port: $web_container_port
        },
        browser: {
            render_url: $browser_render_url,
            mcp_url: $browser_mcp_url
        },
        mcp: {
            dart: {
                transport: "stdio",
                command: ["dart", "mcp-server"]
            },
            searxng_url: $searxng_mcp_url,
            playwright_url: $browser_mcp_url
        },
        models: {
            local: {
                base_url: $local_llm_base_url,
                model: $local_llm_model
            },
            opencode_go: {
                base_url: $opencode_go_base_url,
                api_key_env: "OPENCODE_GO_API_KEY"
            }
        },
        android: {
            avd: $android_avd,
            system_image: $android_system_image,
            sdk: $android_sdk
        },
        toolchain: {
            flutter: $flutter_bin,
            dart: $dart_bin,
            java_home: $java_home
        },
        opencode: {
            config: $opencode_config
        },
        agents_file: $agents_file,
        ssh: {
            container_port: $ssh_container_port
        }
    }' > /run/flutterdev/topology.json
chmod 0644 /run/flutterdev/topology.json

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
