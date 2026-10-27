#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "${ROOT}/util/env.sh"
# shellcheck disable=SC1091
source "${ROOT}/util/db-select.sh"

packaging_ensure_sqlite
exec hue_run "${HUE_CLI}" migrate --noinput "$@"
