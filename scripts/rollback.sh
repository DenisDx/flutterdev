#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

ENV_FILE=.env
VERSIONS_FILE=versions.env
IMAGE=flutterdev:local
SERVICE=flutterdev
CONTAINER=flutterdev
STATE_FILE=state/updates/last-rollback.env
COMPOSE=(docker compose --env-file "${ENV_FILE}" --env-file "${VERSIONS_FILE}")

log() { printf '[rollback] %s\n' "$*"; }
die() { printf '[rollback] ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "${ENV_FILE}" ] || die "${ENV_FILE} not found"
[ -f "${VERSIONS_FILE}" ] || die "${VERSIONS_FILE} not found"
[ -f "${STATE_FILE}" ] || die "no rollback data in ${STATE_FILE}"

set -a
# shellcheck disable=SC1090,SC1091
. "./${STATE_FILE}"
set +a

[ -n "${ROLLBACK_TAG:-}" ] || die "ROLLBACK_TAG is empty in ${STATE_FILE}"
[ -n "${ROLLBACK_IMAGE_ID:-}" ] || die "ROLLBACK_IMAGE_ID is empty in ${STATE_FILE}"

docker info >/dev/null 2>&1 || die "Docker daemon is not available"
docker image inspect "${ROLLBACK_TAG}" >/dev/null 2>&1 \
    || die "rollback image ${ROLLBACK_TAG} not found"

current_id="$(docker image inspect "${IMAGE}" --format '{{.Id}}' 2>/dev/null || true)"
if [ -n "${current_id}" ] && [ "${current_id}" != "${ROLLBACK_IMAGE_ID}" ]; then
    safety_tag="flutterdev:pre-rollback-$(date +%Y%m%d-%H%M%S)"
    docker tag "${current_id}" "${safety_tag}"
    log "saved current image as ${safety_tag}"
fi

log "restoring ${IMAGE} from ${ROLLBACK_TAG}"
docker tag "${ROLLBACK_TAG}" "${IMAGE}"
"${COMPOSE[@]}" up -d --force-recreate "${SERVICE}"

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
    docker logs --tail 80 "${CONTAINER}" 2>&1 || true
    die "container did not become healthy after rollback (status: ${status})"
fi

"${COMPOSE[@]}" exec -T --user dev "${SERVICE}" /usr/local/bin/check.sh --skip-network

log "rollback finished"
log "user state in workspace/ and state/ was not rolled back"
