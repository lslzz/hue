#!/usr/bin/env bash
# One-click Hue relocatable tarball builder (x86_64 / aarch64) via RockyLinux 8 containers.
#
# Usage:
#   ./tools/packaging/build-tarball.sh              # current host arch
#   ./tools/packaging/build-tarball.sh --arch amd64
#   ./tools/packaging/build-tarball.sh --arch arm64
#   ./tools/packaging/build-tarball.sh --arch all
#   ./tools/packaging/build-tarball.sh --skip-image  # reuse already-built image
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
IMAGE_NAME="${HUE_PACKAGING_IMAGE:-hue-packaging-el8:master-py311}"
OUT_DIR="${HUE_PACKAGING_OUT:-${REPO_ROOT}/dist/packaging}"
DOCKERFILE="${SCRIPT_DIR}/Dockerfile.el8"

ARCH_ARG="host"
SKIP_IMAGE=0

usage() {
  sed -n '2,12p' "$0"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH_ARG="${2:?}"; shift 2 ;;
    --skip-image) SKIP_IMAGE=1; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1" >&2; exit 1; }
}

need_cmd docker
mkdir -p "${OUT_DIR}"

host_arch="$(uname -m)"
case "${host_arch}" in
  x86_64) HOST_PLATFORM=linux/amd64 ;;
  aarch64) HOST_PLATFORM=linux/arm64 ;;
  *) echo "ERROR: unsupported host arch ${host_arch}" >&2; exit 1 ;;
esac

platforms=()
case "${ARCH_ARG}" in
  host) platforms+=("${HOST_PLATFORM}") ;;
  amd64|x86_64|x64) platforms+=("linux/amd64") ;;
  arm64|aarch64) platforms+=("linux/arm64") ;;
  all) platforms+=("linux/amd64" "linux/arm64") ;;
  *) echo "ERROR: --arch must be host|amd64|arm64|all" >&2; exit 1 ;;
esac

ensure_qemu() {
  local want="$1"
  if [[ "${want}" != "${HOST_PLATFORM}" ]]; then
    if ! docker buildx version >/dev/null 2>&1; then
      echo "ERROR: cross-arch build requires docker buildx" >&2
      exit 1
    fi
    # Best-effort binfmt setup (may need root once)
    docker run --rm --privileged tonistiigi/binfmt --install all >/dev/null 2>&1 || true
  fi
}

build_image() {
  local platform="$1"
  echo "=== Building image ${IMAGE_NAME} for ${platform} ==="
  docker buildx build \
    --load \
    --platform "${platform}" \
    -f "${DOCKERFILE}" \
    -t "${IMAGE_NAME}" \
    "${SCRIPT_DIR}"
}

run_package() {
  local platform="$1"
  echo "=== Packaging Hue on ${platform} ==="
  ensure_qemu "${platform}"

  if [[ "${SKIP_IMAGE}" -ne 1 ]]; then
    build_image "${platform}"
  else
    echo "(skip image build)"
  fi

  local git_stamp
  git_stamp="$(git -C "${REPO_ROOT}" log -1 --format='%cd-%h' --date=format:'%Y%m%d' 2>/dev/null || echo master)"

  docker run --rm \
    --platform "${platform}" \
    -e HUE_SRC=/work/src \
    -e OUT_DIR=/work/out \
    -e PYTHON_VER="${PYTHON_VER:-python3.11}" \
    -e PACKAGING_HOME=/opt/hue-packaging \
    -e PIP_DEFAULT_TIMEOUT="${PIP_DEFAULT_TIMEOUT:-120}" \
    -e PIP_INDEX_URL="${PIP_INDEX_URL:-}" \
    -e PIP_TRUSTED_HOST="${PIP_TRUSTED_HOST:-}" \
    -e GIT_STAMP="${git_stamp}" \
    -v "${REPO_ROOT}:/work/src:ro" \
    -v "${SCRIPT_DIR}:/opt/hue-packaging:ro" \
    -v "${OUT_DIR}:/work/out" \
    "${IMAGE_NAME}"
}

for p in "${platforms[@]}"; do
  run_package "${p}"
done

echo
echo "Artifacts in ${OUT_DIR}:"
ls -lh "${OUT_DIR}" || true
