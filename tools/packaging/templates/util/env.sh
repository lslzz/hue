#!/usr/bin/env bash
# Shared environment for packaged Hue. Sourced by bin/sbin/shell scripts.
# shellcheck disable=SC2034

_packaging_find_home() {
  local src="${BASH_SOURCE[0]:-$0}"
  local dir
  dir=$(cd "$(dirname "${src}")" && pwd)
  # util/ -> package root
  cd "${dir}/.." && pwd
}

HUE_HOME="${HUE_HOME:-$(_packaging_find_home)}"
export HUE_HOME

export HUE_CONF_DIR="${HUE_CONF_DIR:-${HUE_HOME}/conf}"
export DESKTOP_LOG_DIR="${DESKTOP_LOG_DIR:-${HUE_HOME}/logs}"
export HUE_RUN_DIR="${HUE_RUN_DIR:-${HUE_HOME}/run}"
export HUE_DATA_DIR="${HUE_DATA_DIR:-${HUE_HOME}/data}"
export PYTHON_EGG_CACHE="${PYTHON_EGG_CACHE:-${HUE_RUN_DIR}/python-eggs}"

HUE_LIB="${HUE_HOME}/lib/hue"
HUE_VENV="${HUE_LIB}/build/env"
HUE_BIN="${HUE_VENV}/bin"
HUE_CLI="${HUE_BIN}/hue"
SUPERVISOR_BIN="${HUE_BIN}/supervisor"
PID_FILE="${HUE_RUN_DIR}/hue.pid"

# Bundled CPython runtime (stdlib + libpython). Required on hosts without system Python.
PYTHON_RUNTIME="${HUE_HOME}/lib/python-runtime"
if [[ -d "${PYTHON_RUNTIME}/lib64/python3.11" || -d "${PYTHON_RUNTIME}/lib64/python3.10" || -d "${PYTHON_RUNTIME}/lib64/python3.9" ]]; then
  export PYTHONHOME="${PYTHON_RUNTIME}"
elif [[ -f "${HUE_VENV}/PYTHONHOME.path" ]]; then
  # fallback absolute path recorded at build time (usually wrong after relocate)
  :
fi

mkdir -p "${DESKTOP_LOG_DIR}" "${HUE_RUN_DIR}" "${HUE_DATA_DIR}" "${PYTHON_EGG_CACHE}"

# Put venv first so `#!/usr/bin/env python3.11` resolves to the embedded interpreter
export PATH="${HUE_BIN}:${HUE_HOME}/bin:${PATH}"

# Do NOT export LD_LIBRARY_PATH globally — it can break system tools (sed/mkdir).
# Only inject native + libpython paths when launching Hue.
hue_run() {
  local lib_path=""
  if [[ -d "${PYTHON_RUNTIME}/lib64" ]]; then
    lib_path="${PYTHON_RUNTIME}/lib64"
  fi
  if [[ -d "${HUE_HOME}/lib/native" ]]; then
    lib_path="${lib_path:+${lib_path}:}${HUE_HOME}/lib/native"
  fi
  if [[ -n "${lib_path}" ]]; then
    env PYTHONHOME="${PYTHONHOME:-}" \
      LD_LIBRARY_PATH="${lib_path}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
      "$@"
  else
    env PYTHONHOME="${PYTHONHOME:-}" "$@"
  fi
}

cd "${HUE_LIB}"
