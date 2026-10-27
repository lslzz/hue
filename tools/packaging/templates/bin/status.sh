#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "${ROOT}/util/env.sh"

PID_FILE="${HUE_RUN_DIR}/supervisor.pid"

if [[ ! -f "${PID_FILE}" ]]; then
  echo "status: stopped"
  exit 3
fi

pid="$(tr -d '[:space:]' < "${PID_FILE}" || true)"
if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
  echo "status: running pid=${pid}"
  exit 0
fi

echo "status: stopped (stale pid file)"
exit 3
