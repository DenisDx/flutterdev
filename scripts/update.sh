#!/usr/bin/env bash
set -euo pipefail

ASSUME_YES=false
for arg in "$@"; do
    case "${arg}" in
        --yes|-y) ASSUME_YES=true ;;
        -h|--help)
            echo "usage: update.sh [--yes]"
            exit 0
            ;;
        *)
            echo "unknown option: ${arg}" >&2
            exit 2
            ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

ENV_FILE=.env
VERSIONS_FILE=versions.env
IMAGE=flutterdev:local
SERVICE=flutterdev
CONTAINER=flutterdev
COMPOSE=(docker compose --env-file "${ENV_FILE}" --env-file "${VERSIONS_FILE}")

log() { printf '[update] %s\n' "$*"; }
die() { printf '[update] ERROR: %s\n' "$*" >&2; exit 1; }

require_var() {
    local name="$1"
    local value="${!name:-}"
    [ -n "${value}" ] || die "${name} is empty in ${ENV_FILE}"
    case "${value}" in
        "<"*">") die "${name} still contains a placeholder in ${ENV_FILE}" ;;
    esac
}

[ -f "${ENV_FILE}" ] || die "${ENV_FILE} not found"
[ -f "${VERSIONS_FILE}" ] || die "${VERSIONS_FILE} not found"
[ -f Dockerfile ] || die "Dockerfile not found"
[ -f compose.yaml ] || die "compose.yaml not found"

env_mode="$(stat -c '%a' "${ENV_FILE}")"
[ "${env_mode}" = "600" ] || log "WARNING: ${ENV_FILE} mode is ${env_mode}; expected 600"

docker info >/dev/null 2>&1 || die "Docker daemon is not available"
docker compose version >/dev/null 2>&1 || die "docker compose is not available"

set -a
# shellcheck disable=SC1090,SC1091
. "./${ENV_FILE}"
# shellcheck disable=SC1090,SC1091
. "./${VERSIONS_FILE}"
set +a

for name in DEV_UID DEV_GID \
    WEB_BIND_ADDRESS WEB_HOST_PORT WEB_CONTAINER_PORT \
    SSH_BIND_ADDRESS SSH_HOST_PORT SSH_CONTAINER_PORT \
    DOCKER_NETWORK KVM_GID ANDROID_AVD_NAME \
    SEARXNG_MCP_URL PLAYWRIGHT_MCP_URL \
    LOCAL_LLM_BASE_URL LOCAL_LLM_MODEL \
    OPENCODE_GO_BASE_URL OPENCODE_GO_API_KEY; do
    require_var "${name}"
done

[ "${ANDROID_ACCEPT_LICENSES:-false}" = "true" ] \
    || die "Android SDK licenses are not accepted; set ANDROID_ACCEPT_LICENSES=true in ${ENV_FILE}"

[ "${DEV_UID}" = "$(id -u)" ] \
    || log "WARNING: DEV_UID=${DEV_UID} differs from host uid $(id -u)"

install -d -m 0755 workspace state state/home state/ssh state/access state/updates
chmod 0755 workspace state/home state/access state/updates 2>/dev/null || true
chmod 0700 state/ssh 2>/dev/null || true

if [ ! -f state/access/authorized_keys ]; then
    install -m 0600 /dev/null state/access/authorized_keys
    log "WARNING: created empty state/access/authorized_keys; add public keys for SSH access"
fi

for path in workspace state/home state/ssh state/access state/updates; do
    owner="$(stat -c '%u:%g' "${path}")"
    expected="${DEV_UID}:${DEV_GID}"
    if [ "${owner}" != "${expected}" ]; then
        if [ "${path}" = "workspace" ]; then
            log "WARNING: ${path} is owned by ${owner}, expected ${expected}"
        else
            die "${path} is owned by ${owner}, expected ${expected}; fix ownership on the host"
        fi
    fi
done

[ -c /dev/kvm ] || die "/dev/kvm is not available"
kvm_gid="$(stat -c '%g' /dev/kvm)"
[ "${kvm_gid}" = "${KVM_GID}" ] \
    || die "/dev/kvm GID is ${kvm_gid}, but KVM_GID=${KVM_GID}"

docker network inspect "${DOCKER_NETWORK}" >/dev/null 2>&1 \
    || docker network create "${DOCKER_NETWORK}" >/dev/null

python3 -c '
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
text = re.sub(r"(?m)^\s*//.*$", "", text)
json.loads(text)
' config/opencode/opencode.jsonc >/dev/null 2>&1 \
    || die "config/opencode/opencode.jsonc is not valid JSONC"

"${COMPOSE[@]}" config >/dev/null || die "docker compose config validation failed"

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="state/updates/update-${STAMP}.log"
ROLLBACK_FILE=state/updates/last-rollback.env
: > "${LOG}"

save_rollback() {
    local previous_id rollback_tag
    previous_id="$(docker image inspect "${IMAGE}" --format '{{.Id}}' 2>/dev/null || true)"
    if [ -z "${previous_id}" ]; then
        log "no previous ${IMAGE} image to save"
        return 0
    fi
    rollback_tag="flutterdev:rollback-${STAMP}"
    docker tag "${previous_id}" "${rollback_tag}"
    cat > "${ROLLBACK_FILE}" <<EOF
ROLLBACK_TAG=${rollback_tag}
ROLLBACK_IMAGE_ID=${previous_id}
ROLLBACK_SAVED_AT=${STAMP}
EOF
    chmod 0600 "${ROLLBACK_FILE}"
    log "saved rollback image ${rollback_tag} (${previous_id})" | tee -a "${LOG}"

    local old_tags
    mapfile -t old_tags < <(docker images --format '{{.Repository}}:{{.Tag}}' \
        | grep '^flutterdev:rollback-' | sort | head -n -3)
    local tag
    for tag in "${old_tags[@]:-}"; do
        [ -n "${tag}" ] || continue
        docker rmi "${tag}" >/dev/null 2>&1 || true
    done
}

save_rollback

log "building ${IMAGE} (${BASE_IMAGE}, flutter=${FLUTTER_CHANNEL}, node=${NODE_CHANNEL}, opencode=${OPENCODE_CHANNEL})"
"${COMPOSE[@]}" build --pull --no-cache "${SERVICE}" 2>&1 | tee -a "${LOG}"

log "verifying new image without user mounts, SSH or emulator"
docker run --rm --network none \
    --entrypoint /usr/local/bin/check.sh \
    "${IMAGE}" --image-check 2>&1 | tee -a "${LOG}"

log "actual versions written to ${LOG}"
{
    echo "updated_at=${STAMP}"
    echo "base_image=${BASE_IMAGE}"
    echo "flutter_channel=${FLUTTER_CHANNEL}"
    echo "opencode_channel=${OPENCODE_CHANNEL}"
    echo "node_channel=${NODE_CHANNEL}"
    echo "android_api=${ANDROID_API_LEVEL}"
    echo "android_build_tools=${ANDROID_BUILD_TOOLS}"
    echo "android_system_image=${ANDROID_SYSTEM_IMAGE}"
} | tee -a "${LOG}"

if [ "${ASSUME_YES}" != "true" ]; then
    log "the running container will be stopped and recreated"
    read -r -p "Continue? [y/N] " answer
    case "${answer}" in
        y|Y|yes|YES) ;;
        *) log "aborted; the old container is still running"; exit 1 ;;
    esac
fi

log "recreating ${CONTAINER}"
"${COMPOSE[@]}" up -d --force-recreate "${SERVICE}" 2>&1 | tee -a "${LOG}"

ready=false
status=unknown
for _ in $(seq 1 90); do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${CONTAINER}" 2>/dev/null || true)"
    if [ "${status}" = "healthy" ]; then
        ready=true
        break
    fi
    sleep 1
done

if [ "${ready}" != "true" ]; then
    docker logs --tail 80 "${CONTAINER}" 2>&1 | tee -a "${LOG}" || true
    die "container did not become healthy (status: ${status})"
fi

log "running service checks"
"${COMPOSE[@]}" exec -T --user dev "${SERVICE}" /usr/local/bin/check.sh 2>&1 | tee -a "${LOG}"

log "update finished; log: ${LOG}"
