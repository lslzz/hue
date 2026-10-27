#!/usr/bin/env bash
# Copy runtime shared libraries referenced by Hue's Python extensions into lib/native.
set -euo pipefail

PKG_ROOT="${1:?Usage: bundle-native.sh <package_root>}"
NATIVE_DIR="${PKG_ROOT}/lib/native"
HUE_LIB="${PKG_ROOT}/lib/hue"

mkdir -p "${NATIVE_DIR}"

# Collect .so under the virtualenv / Hue tree
mapfile -t SO_FILES < <(find "${HUE_LIB}" -type f \( -name '*.so' -o -name '*.so.*' \) 2>/dev/null || true)

declare -A SEEN=()
queue=()

add_lib() {
  local lib="$1"
  [[ -z "${lib}" || "${lib}" == "not" || "${lib}" == "found" ]] && return 0
  [[ "${lib}" == /* ]] || return 0
  [[ -e "${lib}" ]] || return 0
  # Skip glibc / loader — must come from target OS
  local base
  base="$(basename "${lib}")"
  case "${base}" in
    # Must come from target OS — bundling these breaks system tools via LD_LIBRARY_PATH
    ld-linux*|ld-*.so*|libc.so*|libm.so*|libdl.so*|libpthread.so*|librt.so*|libresolv.so*|libnss_*.so*|libutil.so*|\
    libselinux*|libpcre*|libpcre2*|libgcc_s*|libstdc++*|libattr*|libcap*|libcrypt.so*)
      return 0
      ;;
  esac
  if [[ -z "${SEEN[${lib}]+x}" ]]; then
    SEEN["${lib}"]=1
    queue+=("${lib}")
  fi
}

# Only collect shared-library *dependencies* of Hue extensions (not the extensions themselves)
if ((${#SO_FILES[@]} > 0)); then
  for so in "${SO_FILES[@]}"; do
    while read -r dep; do
      add_lib "${dep}"
    done < <(ldd "${so}" 2>/dev/null | awk '/=>/ {print $3} /^[^[:space:]]/ && /ld-linux|ld-musl/ {print $1}' || true)
  done
fi

# Always try to bundle common Hue deps if present on the build image
for name in \
  libsasl2.so libsasl2.so.3 \
  libldap-2.4.so.2 liblber-2.4.so.2 \
  libxml2.so.2 libxslt.so.1 libexslt.so.0 \
  libssl.so.1.1 libcrypto.so.1.1 \
  libffi.so.6 libffi.so.7 \
  libkrb5.so.3 libk5crypto.so.3 libgssapi_krb5.so.2 libkrb5support.so.0 libcom_err.so.2 \
  libsqlite3.so.0 \
  libmariadb.so.3 libmysqlclient.so.21 libmysqlclient.so.18 \
  libz.so.1 libbz2.so.1 \
  libxmlsec1.so.1 libxmlsec1-openssl.so.1 \
  libsnappy.so.1
do
  while read -r path; do
    add_lib "${path}"
  done < <(ldconfig -p 2>/dev/null | awk -v n="$name" '$1 == n {print $NF}' || true)
  for cand in "/usr/lib64/${name}" "/usr/lib/${name}" "/lib64/${name}"; do
    [[ -e "${cand}" ]] && add_lib "${cand}"
  done
done

copied=0
if ((${#queue[@]} > 0)); then
  for lib in "${queue[@]}"; do
    base="$(basename "${lib}")"
    dest="${NATIVE_DIR}/${base}"
    if [[ ! -e "${dest}" ]]; then
      cp -aL "${lib}" "${dest}" 2>/dev/null || cp -a "${lib}" "${dest}"
      chmod a+r "${dest}" || true
      copied=$((copied + 1))
    fi
  done
fi

# Recursively resolve deps of newly copied libs (one more pass)
mapfile -t NATIVE_SOS < <(find "${NATIVE_DIR}" -maxdepth 1 -type f \( -name '*.so' -o -name '*.so.*' \) 2>/dev/null || true)
if ((${#NATIVE_SOS[@]} > 0)); then
  for so in "${NATIVE_SOS[@]}"; do
    while read -r dep; do
      [[ -z "${dep}" || ! -e "${dep}" ]] && continue
      base="$(basename "${dep}")"
      case "${base}" in
        ld-linux*|ld-*.so*|libc.so*|libm.so*|libdl.so*|libpthread.so*|librt.so*|libresolv.so*|libnss_*.so*|libutil.so*|\
        libselinux*|libpcre*|libpcre2*|libgcc_s*|libstdc++*|libattr*|libcap*|libcrypt.so*)
          continue
          ;;
      esac
      dest="${NATIVE_DIR}/${base}"
      if [[ ! -e "${dest}" ]]; then
        cp -aL "${dep}" "${dest}" 2>/dev/null || cp -a "${dep}" "${dest}" || true
        chmod a+r "${dest}" || true
        copied=$((copied + 1))
      fi
    done < <(ldd "${so}" 2>/dev/null | awk '/=>/ {print $3}' || true)
  done
fi
# Final sweep: drop OS-core libs that must not override system ones
find "${NATIVE_DIR}" -maxdepth 1 -type f \( \
  -name 'libselinux*' -o -name 'libpcre*' -o -name 'libpcre2*' \
  -o -name 'libgcc_s*' -o -name 'libstdc++*' -o -name 'libattr*' \
  -o -name 'libcap.so*' -o -name 'libcrypt.so*' \
\) -delete 2>/dev/null || true

echo "bundle-native: copied ${copied} libraries into ${NATIVE_DIR}"
ls -la "${NATIVE_DIR}" | head -50 || true
