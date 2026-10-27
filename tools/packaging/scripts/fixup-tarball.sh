#!/usr/bin/env bash
# Post-process an existing packaging tarball: run relocatable + refresh native libs.
set -euo pipefail

PACKAGING_HOME="${PACKAGING_HOME:-/opt/hue-packaging}"
OUT_DIR="${OUT_DIR:-/work/out}"
TGZ="${1:-}"

if [[ -z "${TGZ}" ]]; then
  TGZ="$(ls -1 "${OUT_DIR}"/hue-*-linux-*.tar.gz 2>/dev/null | head -1 || true)"
fi
[[ -n "${TGZ}" && -f "${TGZ}" ]] || { echo "Usage: fixup-tarball.sh <tarball>" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

echo "=== Fixing ${TGZ} ==="
tar -xzf "${TGZ}" -C "${WORK}"
PKG_ROOT="${WORK}/hue"
HUE_LIB="${PKG_ROOT}/lib/hue"

[[ -d "${HUE_LIB}/build/env" ]] || { echo "ERROR: missing ${HUE_LIB}/build/env" >&2; exit 1; }

echo "--- relocatable"
mkdir -p "${HUE_LIB}/tools"
if [[ ! -f "${HUE_LIB}/tools/relocatable.sh" ]]; then
  if [[ -f "${PKG_ROOT}/util/relocatable-upstream.sh" ]]; then
    cp -a "${PKG_ROOT}/util/relocatable-upstream.sh" "${HUE_LIB}/tools/relocatable.sh"
  elif [[ -f "${PACKAGING_HOME}/../relocatable.sh" ]]; then
    cp -a "${PACKAGING_HOME}/../relocatable.sh" "${HUE_LIB}/tools/relocatable.sh"
  fi
fi
# virtual-bootstrap may be missing from install tree
if [[ ! -d "${HUE_LIB}/tools/virtual-bootstrap" && -d /work/src/tools/virtual-bootstrap ]]; then
  cp -a /work/src/tools/virtual-bootstrap "${HUE_LIB}/tools/"
fi
# Prefer Hue virtual-bootstrap relocatable helpers (virtualenv 20+ dropped make-relocatable)
if [[ ! -d "${HUE_LIB}/tools/virtual-bootstrap" && -d /work/src/tools/virtual-bootstrap ]]; then
  mkdir -p "${HUE_LIB}/tools"
  cp -a /work/src/tools/virtual-bootstrap "${HUE_LIB}/tools/"
fi
BOOTSTRAP="${HUE_LIB}/tools/virtual-bootstrap/virtual-bootstrap.py"

# Original install prefix was /opt/hue — recreate that path so absolute links resolve
# while relocatable rewrites them to relative paths.
rm -rf /opt/hue
ln -sfn "${HUE_LIB}" /opt/hue
ENV_PY="/opt/hue/build/env/bin/python"
pushd /opt/hue >/dev/null
"${ENV_PY}" "${BOOTSTRAP}" --relocatable "build/env"
"${ENV_PY}" "${BOOTSTRAP}" --relocatable_pth "build/env"
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
# Also normalize remaining absolute shebangs to env-based ones
PYTHON_VER="${PYTHON_VER:-python3.11}"
while IFS= read -r -d '' script; do
  if head -1 "${script}" | grep -q '^#!.*/build/env/bin/python'; then
    sed -i "1s|^#!.*|#!/usr/bin/env ${PYTHON_VER}|" "${script}"
  fi
done < <(find "${HUE_LIB}/build/env/bin" -type f -print0)

echo "--- refresh native libs"
rm -rf "${PKG_ROOT}/lib/native"
bash "${PACKAGING_HOME}/scripts/bundle-native.sh" "${PKG_ROOT}"

echo "--- fix editable egg-links"
bash "${PACKAGING_HOME}/scripts/fix-egg-links.sh" "${HUE_LIB}"

echo "--- embed python interpreter"
bash "${PACKAGING_HOME}/scripts/embed-python.sh" "${HUE_LIB}" "${PKG_ROOT}/lib/native"

echo "--- refresh runtime scripts"
install -m 0755 "${PACKAGING_HOME}/templates/bin/"* "${PKG_ROOT}/bin/"
install -m 0755 "${PACKAGING_HOME}/templates/sbin/"* "${PKG_ROOT}/sbin/"
install -m 0755 "${PACKAGING_HOME}/templates/shell/"* "${PKG_ROOT}/shell/"
install -m 0755 "${PACKAGING_HOME}/templates/util/"* "${PKG_ROOT}/util/"

echo "--- rewrite shebang check"
head -1 "${HUE_LIB}/build/env/bin/hue" || true
ls -la "${HUE_LIB}/build/env/bin/${PYTHON_VER}"
file "${HUE_LIB}/build/env/bin/${PYTHON_VER}"

echo "--- repack"
TMP_OUT="${TGZ}.new"
tar -C "${WORK}" -czf "${TMP_OUT}" hue
mv -f "${TMP_OUT}" "${TGZ}"
sha256sum "${TGZ}" | tee "${TGZ}.sha256"
{
  echo "Package: $(basename "${TGZ}" .tar.gz)"
  echo "Top-level:"
  find "${PKG_ROOT}" -maxdepth 1 -mindepth 1 -printf '  %f\n' | sort
  echo "Size: $(du -sh "${TGZ}" | awk '{print $1}')"
} | tee "${OUT_DIR}/$(basename "${TGZ}" .tar.gz).manifest.txt"

echo "=== DONE: ${TGZ} ==="
