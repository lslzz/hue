#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "${ROOT}/util/env.sh"

echo "HUE_HOME=${HUE_HOME}"
echo "HUE_CONF_DIR=${HUE_CONF_DIR}"
echo "Entering Hue Python shell (Ctrl-D to exit)..."
exec hue_run "${HUE_CLI}" shell "$@"
