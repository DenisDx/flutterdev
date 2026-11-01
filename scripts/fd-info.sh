#!/usr/bin/env bash
set -euo pipefail

TOPOLOGY="${FLUTTERDEV_TOPOLOGY_FILE:-/run/flutterdev/topology.json}"
AGENTS="${FLUTTERDEV_AGENTS_FILE:-/workspace/AGENTS.md}"
OPENCODE_CONFIG="/home/dev/.config/opencode/opencode.jsonc"

echo "flutterdev topology"
echo "  runbook: ${AGENTS}"
echo "  opencode config: ${OPENCODE_CONFIG}"
echo "  topology file: ${TOPOLOGY}"
echo

if [ ! -r "${TOPOLOGY}" ]; then
    echo "ERROR: topology file is not available." >&2
    exit 1
fi

jq . "${TOPOLOGY}"
