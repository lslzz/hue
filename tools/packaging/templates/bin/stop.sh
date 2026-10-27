#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "${ROOT}/util/env.sh"

PID_FILE="${HUE_RUN_DIR}/supervisor.pid"

if [[ ! -f "${PID_FILE}" ]]; then
  echo "Hue is not running (no ${PID_FILE})"
  exit 0
fi

pid="$(tr -d '[:space:]' < "${PID_FILE}" || true)"
if [[ -z "${pid}" ]]; then
  echo "Empty pid file; removing"
  rm -f "${PID_FILE}"
  exit 0
fi

if ! kill -0 "${pid}" 2>/dev/null; then
  echo "Stale pid ${pid}; removing pid file"
  rm -f "${PID_FILE}"
  exit 0
fi

echo "Stopping Hue (pid ${pid})..."
kill -TERM "${pid}" 2>/dev/null || true

for _ in $(seq 1 30); do
  if ! kill -0 "${pid}" 2>/dev/null; then
    rm -f "${PID_FILE}"
    echo "Hue stopped"
    exit 0
  fi
  sleep 1
done

echo "Force killing pid ${pid}"
kill -KILL "${pid}" 2>/dev/null || true
rm -f "${PID_FILE}"
echo "Hue stopped (forced)"
