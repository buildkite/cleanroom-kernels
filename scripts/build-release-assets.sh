#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[build-release-assets] error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1 || die "missing required command: ${name}"
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
    return
  fi
  die "sha256 tool not found (need sha256sum or shasum)"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KERNEL_VERSION="${CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_VERSION:-6.1.155}"
KERNEL_PROFILES_RAW="${CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_PROFILES:-}"
if [[ -n "${KERNEL_PROFILES_RAW}" ]]; then
  read -r -a KERNEL_PROFILES <<<"${KERNEL_PROFILES_RAW}"
elif [[ -n "${CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_PROFILE+x}" ]]; then
  KERNEL_PROFILES=("${CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_PROFILE}")
else
  KERNEL_PROFILES=(rootfs initrd)
fi
INCLUDE_SPOREVM_KERNELS="${CLEANROOM_KERNELS_INCLUDE_SPOREVM:-1}"
KERNEL_ARCH="${CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_ARCH:-arm64}"
DOCKER_IMAGE="${CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_DOCKER_IMAGE:-ubuntu:22.04}"
DOCKER_PLATFORM="${CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_DOCKER_PLATFORM:-linux/amd64}"
KERNEL_TARBALL_SHA256="${CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_TARBALL_SHA256:-}"
if [[ -z "${KERNEL_TARBALL_SHA256}" && "${KERNEL_VERSION}" == "6.1.155" ]]; then
  KERNEL_TARBALL_SHA256="c29387aeee085fbcbd91236224b9df805063bac43615e75cea2c6b29604a5c73"
fi
DEFAULT_CROSS_COMPILE=""
if [[ "${KERNEL_ARCH}" == "arm64" && "${DOCKER_PLATFORM}" != "linux/arm64" ]]; then
  DEFAULT_CROSS_COMPILE="aarch64-linux-gnu-"
fi
KERNEL_CROSS_COMPILE="${CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_CROSS_COMPILE-${DEFAULT_CROSS_COMPILE}}"

if [[ "${#KERNEL_PROFILES[@]}" -eq 0 ]]; then
  die "at least one kernel profile is required"
fi

if [[ "${#KERNEL_PROFILES[@]}" -gt 1 && -n "${CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_ASSET_BASE:-}" ]]; then
  die "CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_ASSET_BASE is only supported when building a single profile"
fi

for profile in "${KERNEL_PROFILES[@]}"; do
  case "${profile}" in
    initrd|rootfs) ;;
    *)
      die "release kernel profile must be initrd or rootfs, got ${profile}"
      ;;
  esac
done

case "${INCLUDE_SPOREVM_KERNELS}" in
  0|1) ;;
  *) die "CLEANROOM_KERNELS_INCLUDE_SPOREVM must be 0 or 1" ;;
esac

case "${KERNEL_ARCH}" in
  arm64) ;;
  *)
    die "release kernel arch must be arm64, got ${KERNEL_ARCH}"
    ;;
esac

require_command docker
require_command git
require_command python3

OUTPUT_DIR="${1:-${REPO_ROOT}/dist/kernels}"
mkdir -p "${OUTPUT_DIR}"

SOURCE_COMMIT="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || printf 'unknown')"
SOURCE_REPOSITORY="${CLEANROOM_KERNELS_GITHUB_REPOSITORY:-buildkite/cleanroom-kernels}"
RELEASE_TAG="${CLEANROOM_KERNELS_RELEASE_TAG:-${BUILDKITE_TAG:-}}"

build_profile() {
  local kernel_profile="$1"
  local asset_base image_name image_path config_path sha256_path manifest_path kernel_sha256

  asset_base="${CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_ASSET_BASE:-cleanroom-darwin-vz-minimal-${kernel_profile}-${KERNEL_ARCH}-linux-${KERNEL_VERSION}}"
  image_name="${asset_base}-Image"
  image_path="${OUTPUT_DIR}/${image_name}"
  config_path="${image_path}.config"
  sha256_path="${image_path}.sha256"
  manifest_path="${OUTPUT_DIR}/${asset_base}.manifest.json"

  rm -f "${image_path}" "${config_path}" "${sha256_path}" "${manifest_path}"

  CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_PROFILE="${kernel_profile}" \
  CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_ARCH="${KERNEL_ARCH}" \
  CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_VERSION="${KERNEL_VERSION}" \
  CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_DOCKER_IMAGE="${DOCKER_IMAGE}" \
  CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_DOCKER_PLATFORM="${DOCKER_PLATFORM}" \
  CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_CROSS_COMPILE="${KERNEL_CROSS_COMPILE}" \
  CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_TARBALL_SHA256="${KERNEL_TARBALL_SHA256}" \
    "${SCRIPT_DIR}/build-kernel.sh" "${image_path}" >/dev/null

  [[ -f "${image_path}" ]] || die "kernel image was not created: ${image_path}"
  [[ -f "${config_path}" ]] || die "kernel config was not created: ${config_path}"

  kernel_sha256="$(sha256_file "${image_path}")"
  printf '%s  %s\n' "${kernel_sha256}" "${image_name}" > "${sha256_path}"

  ASSET_BASE="${asset_base}" \
  DOCKER_IMAGE="${DOCKER_IMAGE}" \
  DOCKER_PLATFORM="${DOCKER_PLATFORM}" \
  IMAGE_NAME="${image_name}" \
  KERNEL_ARCH="${KERNEL_ARCH}" \
  KERNEL_PROFILE="${kernel_profile}" \
  KERNEL_SHA256="${kernel_sha256}" \
  KERNEL_TARBALL_SHA256="${KERNEL_TARBALL_SHA256}" \
  KERNEL_VERSION="${KERNEL_VERSION}" \
  RELEASE_TAG="${RELEASE_TAG}" \
  SOURCE_COMMIT="${SOURCE_COMMIT}" \
  SOURCE_REPOSITORY="${SOURCE_REPOSITORY}" \
  python3 - <<'PY' > "${manifest_path}"
import json
import os

image_name = os.environ["IMAGE_NAME"]
manifest = {
    "id": os.environ["ASSET_BASE"],
    "backend": "darwin-vz",
    "profile": os.environ["KERNEL_PROFILE"],
    "arch": os.environ["KERNEL_ARCH"],
    "linux_version": os.environ["KERNEL_VERSION"],
    "assets": {
        "image": image_name,
        "config": image_name + ".config",
        "sha256": image_name + ".sha256",
        "manifest": os.environ["ASSET_BASE"] + ".manifest.json",
    },
    "sha256": os.environ["KERNEL_SHA256"],
    "source": {
        "repository": os.environ["SOURCE_REPOSITORY"],
        "commit": os.environ["SOURCE_COMMIT"],
        "tag": os.environ["RELEASE_TAG"],
    },
    "builder": {
        "repository": os.environ["SOURCE_REPOSITORY"],
        "script": "scripts/build-kernel.sh",
        "docker_image": os.environ["DOCKER_IMAGE"],
        "docker_platform": os.environ["DOCKER_PLATFORM"],
        "kernel_tarball_sha256": os.environ["KERNEL_TARBALL_SHA256"],
    },
}
print(json.dumps(manifest, indent=2, sort_keys=True))
PY

  printf '[build-release-assets] wrote %s\n' "${image_path}"
  printf '[build-release-assets] wrote %s\n' "${config_path}"
  printf '[build-release-assets] wrote %s\n' "${sha256_path}"
  printf '[build-release-assets] wrote %s\n' "${manifest_path}"
}

build_sporevm_kernel() {
  local asset_base image_name image_path config_path sha256_path manifest_path kernel_sha256

  asset_base="${SPOREVM_KERNEL_ASSET_BASE:-sporevm-${KERNEL_ARCH}-linux-${KERNEL_VERSION}}"
  image_name="${asset_base}-Image"
  image_path="${OUTPUT_DIR}/${image_name}"
  config_path="${image_path}.config"
  sha256_path="${image_path}.sha256"
  manifest_path="${OUTPUT_DIR}/${asset_base}.manifest.json"

  rm -f "${image_path}" "${config_path}" "${sha256_path}" "${manifest_path}"

  CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_ARCH="${KERNEL_ARCH}" \
  CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_VERSION="${KERNEL_VERSION}" \
  CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_DOCKER_IMAGE="${DOCKER_IMAGE}" \
  CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_DOCKER_PLATFORM="${DOCKER_PLATFORM}" \
  CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_CROSS_COMPILE="${KERNEL_CROSS_COMPILE}" \
  CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_TARBALL_SHA256="${KERNEL_TARBALL_SHA256}" \
    "${SCRIPT_DIR}/build-sporevm-kernel.sh" "${image_path}" >/dev/null

  [[ -f "${image_path}" ]] || die "SporeVM kernel image was not created: ${image_path}"
  [[ -f "${config_path}" ]] || die "SporeVM kernel config was not created: ${config_path}"

  kernel_sha256="$(sha256_file "${image_path}")"
  printf '%s  %s\n' "${kernel_sha256}" "${image_name}" > "${sha256_path}"

  ASSET_BASE="${asset_base}" \
  DOCKER_IMAGE="${DOCKER_IMAGE}" \
  DOCKER_PLATFORM="${DOCKER_PLATFORM}" \
  IMAGE_NAME="${image_name}" \
  KERNEL_ARCH="${KERNEL_ARCH}" \
  KERNEL_SHA256="${kernel_sha256}" \
  KERNEL_TARBALL_SHA256="${KERNEL_TARBALL_SHA256}" \
  KERNEL_VERSION="${KERNEL_VERSION}" \
  RELEASE_TAG="${RELEASE_TAG}" \
  SOURCE_COMMIT="${SOURCE_COMMIT}" \
  SOURCE_REPOSITORY="${SOURCE_REPOSITORY}" \
  python3 - <<'PY' > "${manifest_path}"
import json
import os

image_name = os.environ["IMAGE_NAME"]
manifest = {
    "id": os.environ["ASSET_BASE"],
    "project": "sporevm",
    "purpose": "fork-smoke",
    "arch": os.environ["KERNEL_ARCH"],
    "linux_version": os.environ["KERNEL_VERSION"],
    "assets": {
        "image": image_name,
        "config": image_name + ".config",
        "sha256": image_name + ".sha256",
        "manifest": os.environ["ASSET_BASE"] + ".manifest.json",
    },
    "kernel_config": {
        "devmem": True,
        "strict_devmem": False,
        "base": "cleanroom-darwin-vz-minimal-initrd",
    },
    "sha256": os.environ["KERNEL_SHA256"],
    "source": {
        "repository": os.environ["SOURCE_REPOSITORY"],
        "commit": os.environ["SOURCE_COMMIT"],
        "tag": os.environ["RELEASE_TAG"],
    },
    "builder": {
        "repository": os.environ["SOURCE_REPOSITORY"],
        "script": "scripts/build-sporevm-kernel.sh",
        "docker_image": os.environ["DOCKER_IMAGE"],
        "docker_platform": os.environ["DOCKER_PLATFORM"],
        "kernel_tarball_sha256": os.environ["KERNEL_TARBALL_SHA256"],
    },
}
print(json.dumps(manifest, indent=2, sort_keys=True))
PY

  printf '[build-release-assets] wrote %s\n' "${image_path}"
  printf '[build-release-assets] wrote %s\n' "${config_path}"
  printf '[build-release-assets] wrote %s\n' "${sha256_path}"
  printf '[build-release-assets] wrote %s\n' "${manifest_path}"
}

for profile in "${KERNEL_PROFILES[@]}"; do
  build_profile "${profile}"
done

if [[ "${INCLUDE_SPOREVM_KERNELS}" = "1" ]]; then
  build_sporevm_kernel
fi
