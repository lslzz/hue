#!/usr/bin/env bash
# Convert a Hue `make install` tree into the packaging layout:
#   bin conf etc lib LICENSE NOTICE logs run sbin shell util www
set -euo pipefail

INSTALL_DIR="${1:?Usage: rearrange.sh <hue_install_dir> <output_pkg_root>}"
PKG_ROOT="${2:?Usage: rearrange.sh <hue_install_dir> <output_pkg_root>}"
PACKAGING_HOME="${PACKAGING_HOME:-/opt/hue-packaging}"

rm -rf "${PKG_ROOT}"
mkdir -p \
  "${PKG_ROOT}/bin" \
  "${PKG_ROOT}/conf" \
  "${PKG_ROOT}/etc" \
  "${PKG_ROOT}/lib/hue" \
  "${PKG_ROOT}/lib/native" \
  "${PKG_ROOT}/logs" \
  "${PKG_ROOT}/run" \
  "${PKG_ROOT}/sbin" \
  "${PKG_ROOT}/shell" \
  "${PKG_ROOT}/util" \
  "${PKG_ROOT}/www" \
  "${PKG_ROOT}/data"

echo "--- Copying Hue install tree to lib/hue"
# Prefer hardlink-aware copy when same filesystem
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete "${INSTALL_DIR}/" "${PKG_ROOT}/lib/hue/"
else
  cp -a "${INSTALL_DIR}/." "${PKG_ROOT}/lib/hue/"
fi

echo "--- Publishing conf"
if [[ -d "${PKG_ROOT}/lib/hue/desktop/conf" ]]; then
  # Prefer installed conf; fall back to conf.dist content already installed
  cp -a "${PKG_ROOT}/lib/hue/desktop/conf/." "${PKG_ROOT}/conf/"
fi
# Packaging overlays (defaults + mysql example)
if [[ -d "${PACKAGING_HOME}/conf" ]]; then
  cp -a "${PACKAGING_HOME}/conf/." "${PKG_ROOT}/conf/"
fi

echo "--- Publishing www static assets"
if [[ -d "${PKG_ROOT}/lib/hue/build/static" ]]; then
  # Keep a stable www/ entry; leave original in place for Hue runtime
  ln -sfn "../lib/hue/build/static" "${PKG_ROOT}/www/static" || \
    cp -a "${PKG_ROOT}/lib/hue/build/static" "${PKG_ROOT}/www/static"
fi
# Marker so www is never empty in listings
cat > "${PKG_ROOT}/www/README.txt" <<'EOF'
Hue static assets live in ./static (symlink or copy of lib/hue/build/static).
Do not serve this directory with an external web server unless you know the Hue static URL layout.
EOF

echo "--- Installing runtime scripts"
install -m 0755 "${PACKAGING_HOME}/templates/bin/"* "${PKG_ROOT}/bin/"
install -m 0755 "${PACKAGING_HOME}/templates/sbin/"* "${PKG_ROOT}/sbin/"
install -m 0755 "${PACKAGING_HOME}/templates/shell/"* "${PKG_ROOT}/shell/"
install -m 0755 "${PACKAGING_HOME}/templates/util/"* "${PKG_ROOT}/util/"
if [[ -d "${PACKAGING_HOME}/templates/etc" ]]; then
  cp -a "${PACKAGING_HOME}/templates/etc/." "${PKG_ROOT}/etc/"
fi

# Keep upstream relocatable helper available
if [[ -f "${PKG_ROOT}/lib/hue/tools/relocatable.sh" ]]; then
  cp -a "${PKG_ROOT}/lib/hue/tools/relocatable.sh" "${PKG_ROOT}/util/relocatable-upstream.sh"
  chmod 0755 "${PKG_ROOT}/util/relocatable-upstream.sh"
fi

echo "--- LICENSE / NOTICE"
if [[ -f "${PKG_ROOT}/lib/hue/LICENSE.txt" ]]; then
  cp -a "${PKG_ROOT}/lib/hue/LICENSE.txt" "${PKG_ROOT}/LICENSE"
elif [[ -f "${PKG_ROOT}/lib/hue/LICENSE" ]]; then
  cp -a "${PKG_ROOT}/lib/hue/LICENSE" "${PKG_ROOT}/LICENSE"
elif [[ -f /work/src/LICENSE.txt ]]; then
  cp -a /work/src/LICENSE.txt "${PKG_ROOT}/LICENSE"
fi
# NOTICE.txt is not part of INSTALL_CORE_FILES; pull from install tree or source checkout
if [[ -f "${PKG_ROOT}/lib/hue/NOTICE.txt" ]]; then
  cp -a "${PKG_ROOT}/lib/hue/NOTICE.txt" "${PKG_ROOT}/NOTICE"
elif [[ -f "${PKG_ROOT}/lib/hue/NOTICE" ]]; then
  cp -a "${PKG_ROOT}/lib/hue/NOTICE" "${PKG_ROOT}/NOTICE"
elif [[ -f /work/src/NOTICE.txt ]]; then
  cp -a /work/src/NOTICE.txt "${PKG_ROOT}/NOTICE"
fi

# Placeholders so empty dirs survive tar
touch "${PKG_ROOT}/logs/.keep" "${PKG_ROOT}/run/.keep" "${PKG_ROOT}/data/.keep"

# Version stamp
version="unknown"
if [[ -f "${PKG_ROOT}/lib/hue/VERSION" ]]; then
  version="$(sed -n 's/^VERSION="\(.*\)"/\1/p' "${PKG_ROOT}/lib/hue/VERSION" | head -1)"
  [[ -z "${version}" ]] && version="$(tr -d '[:space:]' < "${PKG_ROOT}/lib/hue/VERSION")"
fi
{
  echo "name=hue"
  echo "version=${version}"
  echo "packaged_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "arch=$(uname -m)"
} > "${PKG_ROOT}/etc/build-info"

echo "--- Bundling native libraries"
bash "${PACKAGING_HOME}/scripts/bundle-native.sh" "${PKG_ROOT}"

echo "--- rearrange done: ${PKG_ROOT}"
find "${PKG_ROOT}" -maxdepth 1 -printf '%f\n' | sort
