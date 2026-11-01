#!/usr/bin/env bash
set -uo pipefail

SKIP_ENV=false
SKIP_NETWORK=false
STRICT_PLAYWRIGHT=false
IMAGE_CHECK=false
failures=0

for arg in "$@"; do
    case "${arg}" in
        --skip-env) SKIP_ENV=true ;;
        --skip-network) SKIP_NETWORK=true ;;
        --strict-playwright) STRICT_PLAYWRIGHT=true ;;
        --image-check) IMAGE_CHECK=true; SKIP_ENV=true; SKIP_NETWORK=true ;;
        -h|--help)
            echo "usage: check.sh [--skip-env] [--skip-network] [--strict-playwright] [--image-check]"
            exit 0
            ;;
        *)
            echo "unknown option: ${arg}" >&2
            exit 2
            ;;
    esac
done

ok() { printf '  OK    %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; failures=$((failures + 1)); }

check_version_cmd() {
    local name="$1"
    shift
    if ! command -v "$1" >/dev/null 2>&1; then
        fail "${name}: command not found"
        return
    fi
    local out rc first
    out="$(TERM="${TERM:-xterm}" "$@" 2>&1)"
    rc=$?
    first="${out%%$'\n'*}"
    if [ "${rc}" -eq 0 ]; then
        ok "${name}: ${first}"
    else
        fail "${name}: failed to run (${first:-exit ${rc}})"
    fi
}

require_var() {
    local name="$1"
    local value="${!name:-}"
    if [ -z "${value}" ]; then
        fail "environment: ${name} is empty"
        return
    fi
    case "${value}" in
        "<"*">") fail "environment: ${name} still contains a placeholder" ;;
        *) ok "environment: ${name}=${value}" ;;
    esac
}

require_secret() {
    local name="$1"
    local value="${!name:-}"
    if [ -z "${value}" ]; then
        fail "environment: ${name} is empty"
        return
    fi
    case "${value}" in
        "<"*">") fail "environment: ${name} still contains a placeholder" ;;
        *) ok "environment: ${name}=<set>" ;;
    esac
}

mcp_probe() {
    local url="$1"
    local body
    local code
    body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}'
    code="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' \
        -X POST \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -d "${body}" "${url}" 2>/dev/null)" || code=000
    case "${code}" in
        200|202|204|405) return 0 ;;
        *) return 1 ;;
    esac
}

echo "== environment =="
if [ "${SKIP_ENV}" = "true" ]; then
    warn "environment checks skipped"
else
    require_var WEB_CONTAINER_PORT
    require_var SSH_CONTAINER_PORT
    require_var SEARXNG_MCP_URL
    require_var PLAYWRIGHT_MCP_URL
    require_var LOCAL_LLM_BASE_URL
    require_var LOCAL_LLM_MODEL
    require_var OPENCODE_GO_BASE_URL
    require_secret OPENCODE_GO_API_KEY
fi

echo "== toolchain =="
check_version_cmd Flutter flutter --version
check_version_cmd Dart dart --version
check_version_cmd OpenCode opencode --version
check_version_cmd Node node --version
check_version_cmd npm npm --version
check_version_cmd Python python3 --version
check_version_cmd Git git --version
check_version_cmd Java java -version
check_version_cmd javac javac -version
check_version_cmd jq jq --version
check_version_cmd ripgrep rg --version
check_version_cmd mc mc --version
check_version_cmd ssh ssh -V
check_version_cmd sshd /usr/sbin/sshd -V

if command -v fd-info >/dev/null 2>&1; then
    ok "fd-info: available"
else
    fail "fd-info: not found"
fi

if tmpdir="$(mktemp -d)"; then
    if python3 -m venv "${tmpdir}/venv" >/dev/null 2>&1 \
        && "${tmpdir}/venv/bin/pip" --version >/dev/null 2>&1; then
        ok "Python venv: pip works"
    else
        fail "Python venv: could not create venv or run pip"
    fi
    rm -rf "${tmpdir}"
fi

echo "== Android =="
ANDROID_HOME="${ANDROID_HOME:-/opt/android-sdk}"
API_LEVEL="${ANDROID_API_LEVEL:?ANDROID_API_LEVEL is required}"
BUILD_TOOLS="${ANDROID_BUILD_TOOLS:?ANDROID_BUILD_TOOLS is required}"
SYSTEM_IMAGE="${ANDROID_SYSTEM_IMAGE:?ANDROID_SYSTEM_IMAGE is required}"
SYSTEM_IMAGE_DIR="${ANDROID_HOME}/${SYSTEM_IMAGE//;/\/}"

if [ -x "${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager" ]; then
    ok "Android cmdline-tools: present"
    check_version_cmd sdkmanager "${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager" --version
else
    fail "Android cmdline-tools: sdkmanager not found"
fi

check_version_cmd adb "${ANDROID_HOME}/platform-tools/adb" version
check_version_cmd emulator "${ANDROID_HOME}/emulator/emulator" -version

[ -d "${ANDROID_HOME}/platforms/android-${API_LEVEL}" ] \
    && ok "Android platform: android-${API_LEVEL}" \
    || fail "Android platform: android-${API_LEVEL} missing"
[ -d "${ANDROID_HOME}/build-tools/${BUILD_TOOLS}" ] \
    && ok "Android build-tools: ${BUILD_TOOLS}" \
    || fail "Android build-tools: ${BUILD_TOOLS} missing"
[ -d "${SYSTEM_IMAGE_DIR}" ] \
    && ok "Android system image: ${SYSTEM_IMAGE}" \
    || fail "Android system image: ${SYSTEM_IMAGE} missing"
[ -f "${ANDROID_HOME}/licenses/android-sdk-license" ] \
    && ok "Android SDK licenses: accepted" \
    || fail "Android SDK licenses: not accepted"

if [ "${IMAGE_CHECK}" = "true" ]; then
    warn "runtime checks (KVM, AVD, mounts) skipped for image verification"
else
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        ok "/dev/kvm: readable and writable"
    else
        fail "/dev/kvm: not accessible"
    fi

    AVD_NAME="${ANDROID_AVD_NAME:?ANDROID_AVD_NAME is required}"
    if [ -f "/home/dev/.android/avd/${AVD_NAME}.ini" ]; then
        ok "AVD: ${AVD_NAME}"
    else
        warn "AVD: ${AVD_NAME} not created yet"
    fi

    if [ -d /home/dev ]; then
        owner="$(stat -c '%u:%g' /home/dev)"
        expected="${DEV_UID:?DEV_UID is required}:${DEV_GID:?DEV_GID is required}"
        [ "${owner}" = "${expected}" ] \
            && ok "/home/dev ownership: ${owner}" \
            || fail "/home/dev ownership: ${owner}, expected ${expected}"
    fi

    if [ -f /home/dev/.config/opencode/opencode.jsonc ]; then
        if python3 -c '
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
text = re.sub(r"(?m)^\s*//.*$", "", text)
json.loads(text)
' /home/dev/.config/opencode/opencode.jsonc >/dev/null 2>&1; then
            ok "OpenCode config: valid JSONC"
        else
            fail "OpenCode config: invalid JSONC"
        fi
    else
        warn "OpenCode config: not mounted at /home/dev/.config/opencode/opencode.jsonc"
    fi

    if [ -r /workspace/AGENTS.md ]; then
        ok "Agent runbook: /workspace/AGENTS.md"
    else
        warn "Agent runbook: /workspace/AGENTS.md is not mounted"
    fi

    if [ -r /run/flutterdev/topology.json ] \
        && jq empty /run/flutterdev/topology.json >/dev/null 2>&1; then
        ok "Runtime topology: /run/flutterdev/topology.json"
    else
        fail "Runtime topology: /run/flutterdev/topology.json is missing or invalid"
    fi
fi

if [ "${SKIP_NETWORK}" = "true" ]; then
    echo "== network =="
    warn "network checks skipped"
else
    echo "== network =="
    if mcp_probe "${SEARXNG_MCP_URL:-}"; then
        ok "SearXNG MCP: reachable"
    else
        fail "SearXNG MCP: unreachable (${SEARXNG_MCP_URL:-empty})"
    fi

    if mcp_probe "${PLAYWRIGHT_MCP_URL:-}"; then
        ok "Playwright MCP: reachable"
    else
        if [ "${STRICT_PLAYWRIGHT}" = "true" ]; then
            fail "Playwright MCP: unreachable (${PLAYWRIGHT_MCP_URL:-empty})"
        else
            warn "Playwright MCP: unreachable (${PLAYWRIGHT_MCP_URL:-empty})"
        fi
    fi

    if [ -n "${LOCAL_LLM_BASE_URL:-}" ]; then
        llm_code="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' \
            "${LOCAL_LLM_BASE_URL%/}/models" 2>/dev/null)" || llm_code=000
        case "${llm_code}" in
            2*) ok "Local LLM: reachable" ;;
            *) warn "Local LLM: unreachable (HTTP ${llm_code})" ;;
        esac
    else
        warn "Local LLM: endpoint is empty"
    fi
fi

echo
if [ "${failures}" -eq 0 ]; then
    echo "RESULT: OK"
    exit 0
fi
echo "RESULT: FAIL (${failures})"
exit 1
