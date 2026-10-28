#!/usr/bin/env bash
# Bundle a relocatable CPython runtime (interpreter + stdlib + libpython).
# Usage: embed-python.sh <hue_install_root> <native_dir> [python_home_dir]
# Honors PYTHON_VER (default python3.11) so master packages embed 3.11.
set -euo pipefail

HUE_ROOT="${1:?}"
NATIVE_DIR="${2:?}"
# Default: sibling of hue install under package lib/
PY_HOME="${3:-$(cd "$(dirname "${HUE_ROOT}")" && pwd)/python-runtime}"
VENV_BIN="${HUE_ROOT}/build/env/bin"

PYTHON_VER="${PYTHON_VER:-python3.11}"
# python3.11 -> 3.11
PY_XY="${PYTHON_VER#python}"

SYS_PY="$(readlink -f "/usr/bin/${PYTHON_VER}" 2>/dev/null || true)"
if [[ -z "${SYS_PY}" || ! -x "${SYS_PY}" ]]; then
  echo "ERROR: /usr/bin/${PYTHON_VER} not found on build host" >&2
  exit 1
fi

echo "--- Embedding ${PYTHON_VER} runtime into ${PY_HOME}"
rm -rf "${PY_HOME}"
mkdir -p "${PY_HOME}/lib64" "${VENV_BIN}" "${NATIVE_DIR}"

# Stdlib + dynload (RHEL/Rocky uses lib64)
if [[ -d "/usr/lib64/python${PY_XY}" ]]; then
  cp -a "/usr/lib64/python${PY_XY}" "${PY_HOME}/lib64/"
elif [[ -d "/usr/lib/python${PY_XY}" ]]; then
  mkdir -p "${PY_HOME}/lib64"
  cp -a "/usr/lib/python${PY_XY}" "${PY_HOME}/lib64/"
else
  echo "ERROR: stdlib python${PY_XY} not found under /usr/lib64 or /usr/lib" >&2
  exit 1
fi
# Drop bulky/test caches not needed at runtime
find "${PY_HOME}/lib64/python${PY_XY}" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
find "${PY_HOME}/lib64/python${PY_XY}" -type d -name 'test' -prune -exec rm -rf {} + 2>/dev/null || true
find "${PY_HOME}/lib64/python${PY_XY}" -type d -name 'tests' -prune -exec rm -rf {} + 2>/dev/null || true

# libpython next to stdlib so PYTHONHOME resolves it
cp -a /usr/lib64/libpython${PY_XY}.so* "${PY_HOME}/lib64/" 2>/dev/null || \
  cp -a /usr/lib/libpython${PY_XY}.so* "${PY_HOME}/lib64/"
# Also keep a copy in lib/native for extensions that dlopen by soname via LD_LIBRARY_PATH
cp -a /usr/lib64/libpython${PY_XY}.so* "${NATIVE_DIR}/" 2>/dev/null || \
  cp -a /usr/lib/libpython${PY_XY}.so* "${NATIVE_DIR}/" 2>/dev/null || true

# Real interpreter into venv
rm -f "${VENV_BIN}/python" "${VENV_BIN}/python3" "${VENV_BIN}/${PYTHON_VER}"
cp -a "${SYS_PY}" "${VENV_BIN}/${PYTHON_VER}"
chmod 755 "${VENV_BIN}/${PYTHON_VER}"
ln -sfn "${PYTHON_VER}" "${VENV_BIN}/python"
ln -sfn "${PYTHON_VER}" "${VENV_BIN}/python3"

# Record home for runtime scripts
echo "${PY_HOME}" > "${HUE_ROOT}/build/env/PYTHONHOME.path"
PKG_LIB="$(cd "$(dirname "${HUE_ROOT}")" && pwd)"
echo "python-runtime" > "${PKG_LIB}/.python-home-name"

# Rewrite venv script shebangs
while IFS= read -r -d '' script; do
  if head -1 "${script}" | grep -qE '^#!.*(python|env)'; then
    sed -i "1s|^#!.*|#!/usr/bin/env ${PYTHON_VER}|" "${script}"
  fi
done < <(find "${VENV_BIN}" -type f -print0)

echo "--- Verifying embedded runtime"
export PYTHONHOME="${PY_HOME}"
export LD_LIBRARY_PATH="${PY_HOME}/lib64:${NATIVE_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
"${VENV_BIN}/${PYTHON_VER}" -c "import encodings, ssl, sqlite3, ctypes, codecs; codecs.lookup('windows-1252'); print('ok', encodings.__file__)"
# RHEL/Rocky often ship western encodings as encodings/*.pyc only — keep them.
enc_pyc=$(find "${PY_HOME}/lib64/python${PY_XY}/encodings" -maxdepth 1 -name '*.pyc' 2>/dev/null | wc -l)
echo "encodings/*.pyc retained: ${enc_pyc}"
du -sh "${PY_HOME}"
