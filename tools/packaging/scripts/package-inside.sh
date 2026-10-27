#!/usr/bin/env bash
# Build Hue (master) inside the EL8 container and emit a relocatable packaging tarball.
set -euo pipefail

PACKAGING_HOME="${PACKAGING_HOME:-/opt/hue-packaging}"
HUE_SRC="${HUE_SRC:-/work/src}"
HUE_PREFIX="${HUE_PREFIX:-/opt/hue}"
OUT_DIR="${OUT_DIR:-/work/out}"
PYTHON_VER="${PYTHON_VER:-python3.11}"
PY_XY="${PYTHON_VER#python}"

ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64) ARCH_LABEL=x86_64 ;;
  aarch64) ARCH_LABEL=aarch64 ;;
  *) ARCH_LABEL="${ARCH}" ;;
esac

if [[ ! -f "${HUE_SRC}/Makefile" ]]; then
  echo "ERROR: Hue source not found at ${HUE_SRC} (mount the repo to /work/src)" >&2
  exit 1
fi

if ! command -v "${PYTHON_VER}" >/dev/null 2>&1; then
  echo "ERROR: ${PYTHON_VER} not on PATH" >&2
  exit 1
fi

VERSION="$(
  "${PYTHON_VER}" - <<PY
import re
text=open("${HUE_SRC}/VERSION").read()
m=re.search(r'VERSION\s*=\s*"([^"]+)"', text)
print(m.group(1) if m else "unknown")
PY
)"
# Disambiguate master-line packages that still ship VERSION=4.11.0
# Prefer GIT_STAMP from host (source mount often excludes .git)
GIT_STAMP="${GIT_STAMP:-}"
if [[ -z "${GIT_STAMP}" ]]; then
  GIT_STAMP="$(git -C "${HUE_SRC}" log -1 --format='%cd-%h' --date=format:'%Y%m%d' 2>/dev/null || date +%Y%m%d)-local"
fi
PKG_NAME="hue-${VERSION}-master-${GIT_STAMP}-linux-${ARCH_LABEL}"
STAGE_ROOT="/work/stage"
PKG_ROOT="${STAGE_ROOT}/hue"

echo "=== Hue packaging ==="
echo "version=${VERSION} stamp=${GIT_STAMP} arch=${ARCH_LABEL} python=${PYTHON_VER}"
echo "src=${HUE_SRC} prefix=${HUE_PREFIX} out=${OUT_DIR}"

rm -rf "${HUE_PREFIX}" "${STAGE_ROOT}"
mkdir -p "${HUE_PREFIX}" "${STAGE_ROOT}" "${OUT_DIR}" /work/build

# Work on a writable copy so the bind-mounted source stays clean
BUILD_SRC="/work/build/hue-src"
echo "--- Syncing source to ${BUILD_SRC}"
rm -rf "${BUILD_SRC}"
mkdir -p "${BUILD_SRC}"
rsync -a \
  --exclude '.git/' \
  --exclude 'build/' \
  --exclude 'node_modules/' \
  --exclude 'dist/' \
  --exclude 'desktop/desktop.db' \
  --exclude 'tools/packaging/vendor/' \
  "${HUE_SRC}/" "${BUILD_SRC}/"

cd "${BUILD_SRC}"

# Ensure conf exists for collectstatic / install paths that expect it
mkdir -p desktop/conf
if [[ -d desktop/conf.dist ]]; then
  cp -a desktop/conf.dist/. desktop/conf/
fi

echo "--- Bootstrap pip/virtualenv for ${PYTHON_VER}"
"${PYTHON_VER}" -m pip install --default-timeout=120 --upgrade \
  'pip==22.2.2' 'setuptools<70' 'wheel' 'virtualenv==20.24.6' || true

# Offline-friendly: replace git+https thrift with vendored copy (GitHub often blocked).
# Copy into writable build tree — packaging mount is :ro and setuptools needs to touch egg-info.
THRIFT_VENDOR_SRC="${PACKAGING_HOME}/vendor/thrift"
THRIFT_VENDOR="${BUILD_SRC}/ext/thrift"
if [[ -d "${THRIFT_VENDOR_SRC}" ]]; then
  echo "--- Vendoring gethue/thrift into ${THRIFT_VENDOR}"
  rm -rf "${THRIFT_VENDOR}"
  mkdir -p "$(dirname "${THRIFT_VENDOR}")"
  cp -a "${THRIFT_VENDOR_SRC}" "${THRIFT_VENDOR}"
  rm -rf "${THRIFT_VENDOR}/thrift.egg-info" "${THRIFT_VENDOR}/.git"
  for f in desktop/core/generate_requirements.py desktop/core/base_requirements.txt; do
    if [[ -f "${f}" ]]; then
      sed -i "s|git+https://github.com/gethue/thrift.git|file://${THRIFT_VENDOR}|g" "${f}"
    fi
  done
else
  echo "WARNING: vendored thrift missing at ${THRIFT_VENDOR_SRC}; pip will try git+https" >&2
fi

echo "--- make install (PYTHON_VER=${PYTHON_VER})"
export PYTHON_VER
export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python
export SKIP_PYTHONDEV_CHECK=1
export ROOT="${BUILD_SRC}"
export PIP_DEFAULT_TIMEOUT="${PIP_DEFAULT_TIMEOUT:-120}"
export PIP_DISABLE_PIP_VERSION_CHECK=1
if [[ -n "${PIP_INDEX_URL:-}" ]]; then
  echo "--- Using PIP_INDEX_URL=${PIP_INDEX_URL}"
elif curl -fsI --max-time 5 https://pypi.tuna.tsinghua.edu.cn/simple/ >/dev/null 2>&1; then
  export PIP_INDEX_URL="https://pypi.tuna.tsinghua.edu.cn/simple"
  export PIP_TRUSTED_HOST="pypi.tuna.tsinghua.edu.cn"
  echo "--- Using Tsinghua PyPI mirror"
fi

# Do NOT export BLD_DIR_ENV — it would pin install to the build-tree venv and leave
# /opt/hue/build without env (master Makefile.vars uses ifndef BLD_DIR_ENV).
PREFIX="$(dirname "${HUE_PREFIX}")" \
  INSTALL_DIR="${HUE_PREFIX}" \
  ROOT="${BUILD_SRC}" \
  PYTHON_VER="${PYTHON_VER}" \
  SKIP_PYTHONDEV_CHECK=1 \
  make install

# Master may land the install venv at build/venvs/python3.11 due to a Makefile.vars
# quote comparison bug; also some install paths keep using the build-tree env.
# Normalize to ${HUE_PREFIX}/build/env for packaging scripts.
mkdir -p "${HUE_PREFIX}/build"
if [[ -d "${HUE_PREFIX}/build/env" ]]; then
  :
elif [[ -d "${HUE_PREFIX}/build/venvs/${PYTHON_VER}" ]]; then
  echo "--- Linking build/env -> build/venvs/${PYTHON_VER}"
  ln -sfn "venvs/${PYTHON_VER}" "${HUE_PREFIX}/build/env"
elif [[ -d "${BUILD_SRC}/build/env" ]]; then
  echo "--- Copying build-tree venv into ${HUE_PREFIX}/build/env"
  rsync -a "${BUILD_SRC}/build/env/" "${HUE_PREFIX}/build/env/"
else
  echo "ERROR: Hue venv not found under ${HUE_PREFIX}/build or ${BUILD_SRC}/build" >&2
  ls -la "${HUE_PREFIX}/build" >&2 || true
  ls -la "${BUILD_SRC}/build" >&2 || true
  exit 1
fi

echo "--- make Hue relocatable"
pushd "${HUE_PREFIX}" >/dev/null
mkdir -p tools
if [[ ! -d tools/virtual-bootstrap ]]; then
  cp -a "${BUILD_SRC}/tools/virtual-bootstrap" tools/ || true
fi
ENV_PY="${HUE_PREFIX}/build/env/bin/python"
BOOTSTRAP="${HUE_PREFIX}/tools/virtual-bootstrap/virtual-bootstrap.py"
if [[ -x "${ENV_PY}" && -f "${BOOTSTRAP}" ]]; then
  "${ENV_PY}" "${BOOTSTRAP}" --relocatable "build/env"
  "${ENV_PY}" "${BOOTSTRAP}" --relocatable_pth "build/env"
elif [[ -f "${HUE_PREFIX}/tools/relocatable.py" ]]; then
  # Fallback to Hue's relocatable helper (master)
  ROOT="${HUE_PREFIX}" PYTHON_VER="${PYTHON_VER}" make -C "${HUE_PREFIX}" relocatable-env || true
fi
if [[ -L build/env/lib64 && ! -e build/env/lib64 ]]; then
  rm -f build/env/lib64
  ln -s lib build/env/lib64
fi
for app in apps/*; do
  if [[ -d "${app}/conf" ]]; then
    appname=$(basename "${app}")
    pushd desktop/conf >/dev/null
    ln -sfv ../../apps/"${appname}"/conf/*.ini . 2>/dev/null || true
    popd >/dev/null
  fi
done
find . -name '*.pyc' -delete || true
popd >/dev/null

# Metadata DB connector for optional external MySQL
echo "--- Installing mysqlclient into venv (optional external MySQL)"
"${HUE_PREFIX}/build/env/bin/pip" install --no-cache-dir 'mysqlclient>=2.1.0,<3' || \
  "${HUE_PREFIX}/build/env/bin/pip" install --no-cache-dir mysqlclient || \
  echo "WARNING: mysqlclient install failed; SQLite will still work" >&2

# trino is in master base_requirements; assert it landed
echo "--- Checking trino client"
"${HUE_PREFIX}/build/env/bin/python" -c "import trino; print('trino', getattr(trino,'__version__', 'ok'))" || \
  "${HUE_PREFIX}/build/env/bin/pip" install --no-cache-dir 'trino==0.329.0'

echo "--- Rearrange to packaging layout"
bash "${PACKAGING_HOME}/scripts/rearrange.sh" "${HUE_PREFIX}" "${PKG_ROOT}"

# Fix egg-links that still point at /opt/hue after relocatable
PYTHON_VER="${PYTHON_VER}" bash "${PACKAGING_HOME}/scripts/fix-egg-links.sh" "${PKG_ROOT}/lib/hue"

# Embed interpreter + stdlib so target hosts do not need system Python
PYTHON_VER="${PYTHON_VER}" bash "${PACKAGING_HOME}/scripts/embed-python.sh" \
  "${PKG_ROOT}/lib/hue" "${PKG_ROOT}/lib/native"

# Refresh runtime scripts from templates (env.sh uses hue_run, no global LD_LIBRARY_PATH)
install -m 0755 "${PACKAGING_HOME}/templates/bin/"* "${PKG_ROOT}/bin/"
install -m 0755 "${PACKAGING_HOME}/templates/sbin/"* "${PKG_ROOT}/sbin/"
install -m 0755 "${PACKAGING_HOME}/templates/shell/"* "${PKG_ROOT}/shell/"
install -m 0755 "${PACKAGING_HOME}/templates/util/"* "${PKG_ROOT}/util/"

# Trim bulky build-only artifacts from the package
echo "--- Trimming package"
rm -rf \
  "${PKG_ROOT}/lib/hue/node_modules" \
  "${PKG_ROOT}/lib/hue/.git" \
  "${PKG_ROOT}/lib/hue/desktop/core/ext-py" \
  || true
find "${PKG_ROOT}" -name '*.pyc' -delete || true
find "${PKG_ROOT}" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

TGZ="${OUT_DIR}/${PKG_NAME}.tar.gz"
echo "--- Creating ${TGZ}"
tar -C "${STAGE_ROOT}" -czf "${TGZ}" hue
sha256sum "${TGZ}" | tee "${TGZ}.sha256"

{
  echo "Package: ${PKG_NAME}"
  echo "Python: ${PYTHON_VER}"
  echo "Top-level:"
  find "${PKG_ROOT}" -maxdepth 1 -mindepth 1 -printf '  %f\n' | sort
  echo "Size: $(du -sh "${TGZ}" | awk '{print $1}')"
} | tee "${OUT_DIR}/${PKG_NAME}.manifest.txt"

echo "=== DONE: ${TGZ} ==="
