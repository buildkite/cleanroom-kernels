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

require_config_bool() {
  local config_path="$1"
  local symbol="$2"
  local expected="$3"

  case "${expected}" in
    "")
      return
      ;;
    1)
      grep -qx "CONFIG_${symbol}=y" "${config_path}" || die "${config_path} missing CONFIG_${symbol}=y"
      ;;
    0)
      if grep -qx "CONFIG_${symbol}=y" "${config_path}"; then
        die "${config_path} unexpectedly enables CONFIG_${symbol}"
      fi
      grep -qx "# CONFIG_${symbol} is not set" "${config_path}" || die "${config_path} missing disabled CONFIG_${symbol}"
      ;;
    *)
      die "invalid expected config value for CONFIG_${symbol}: ${expected}"
      ;;
  esac
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

build_sporevm_asset() {
  local purpose="$1"
  local asset_base="$2"
  local build_script="$3"
  local kernel_config_base="$4"
  local kernel_config_devmem="${5:-}"
  local kernel_config_strict_devmem="${6:-}"
  local kernel_config_initrd="${7:-}"
  local kernel_config_virtio_blk="${8:-}"
  local kernel_config_ext4="${9:-}"
  local kernel_config_multiuser="${10:-}"
  local kernel_config_sysvipc="${11:-}"
  local kernel_config_posix_timers="${12:-}"
  local kernel_config_binfmt_script="${13:-}"
  local -a required_enabled_config_symbols=()
  local image_name image_path config_path sha256_path manifest_path kernel_sha256

  if [[ "$#" -gt 13 ]]; then
    required_enabled_config_symbols=("${@:14}")
  fi

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
    "${SCRIPT_DIR}/${build_script}" "${image_path}" >/dev/null

  [[ -f "${image_path}" ]] || die "SporeVM kernel image was not created: ${image_path}"
  [[ -f "${config_path}" ]] || die "SporeVM kernel config was not created: ${config_path}"

  require_config_bool "${config_path}" "DEVMEM" "${kernel_config_devmem}"
  require_config_bool "${config_path}" "STRICT_DEVMEM" "${kernel_config_strict_devmem}"
  require_config_bool "${config_path}" "BLK_DEV_INITRD" "${kernel_config_initrd}"
  require_config_bool "${config_path}" "VIRTIO_BLK" "${kernel_config_virtio_blk}"
  require_config_bool "${config_path}" "EXT4_FS" "${kernel_config_ext4}"
  require_config_bool "${config_path}" "MULTIUSER" "${kernel_config_multiuser}"
  require_config_bool "${config_path}" "SYSVIPC" "${kernel_config_sysvipc}"
  require_config_bool "${config_path}" "POSIX_TIMERS" "${kernel_config_posix_timers}"
  require_config_bool "${config_path}" "BINFMT_SCRIPT" "${kernel_config_binfmt_script}"
  for symbol in "${required_enabled_config_symbols[@]}"; do
    require_config_bool "${config_path}" "${symbol}" "1"
  done

  kernel_sha256="$(sha256_file "${image_path}")"
  printf '%s  %s\n' "${kernel_sha256}" "${image_name}" > "${sha256_path}"

  ASSET_BASE="${asset_base}" \
  DOCKER_IMAGE="${DOCKER_IMAGE}" \
  DOCKER_PLATFORM="${DOCKER_PLATFORM}" \
  IMAGE_NAME="${image_name}" \
  KERNEL_ARCH="${KERNEL_ARCH}" \
  KERNEL_CONFIG_BASE="${kernel_config_base}" \
  KERNEL_CONFIG_DEVMEM="${kernel_config_devmem}" \
  KERNEL_CONFIG_STRICT_DEVMEM="${kernel_config_strict_devmem}" \
  KERNEL_CONFIG_INITRD="${kernel_config_initrd}" \
  KERNEL_CONFIG_VIRTIO_BLK="${kernel_config_virtio_blk}" \
  KERNEL_CONFIG_EXT4="${kernel_config_ext4}" \
  KERNEL_CONFIG_MULTIUSER="${kernel_config_multiuser}" \
  KERNEL_CONFIG_SYSVIPC="${kernel_config_sysvipc}" \
  KERNEL_CONFIG_POSIX_TIMERS="${kernel_config_posix_timers}" \
  KERNEL_CONFIG_BINFMT_SCRIPT="${kernel_config_binfmt_script}" \
  KERNEL_SHA256="${kernel_sha256}" \
  KERNEL_TARBALL_SHA256="${KERNEL_TARBALL_SHA256}" \
  KERNEL_VERSION="${KERNEL_VERSION}" \
  PURPOSE="${purpose}" \
  RELEASE_TAG="${RELEASE_TAG}" \
  BUILD_SCRIPT="${build_script}" \
  SOURCE_COMMIT="${SOURCE_COMMIT}" \
  SOURCE_REPOSITORY="${SOURCE_REPOSITORY}" \
  python3 - <<'PY' > "${manifest_path}"
import json
import os

image_name = os.environ["IMAGE_NAME"]
kernel_config = {"base": os.environ["KERNEL_CONFIG_BASE"]}
for key, env_name in (
    ("devmem", "KERNEL_CONFIG_DEVMEM"),
    ("strict_devmem", "KERNEL_CONFIG_STRICT_DEVMEM"),
    ("initrd", "KERNEL_CONFIG_INITRD"),
    ("virtio_blk", "KERNEL_CONFIG_VIRTIO_BLK"),
    ("ext4", "KERNEL_CONFIG_EXT4"),
    ("multiuser", "KERNEL_CONFIG_MULTIUSER"),
    ("sysvipc", "KERNEL_CONFIG_SYSVIPC"),
    ("posix_timers", "KERNEL_CONFIG_POSIX_TIMERS"),
    ("binfmt_script", "KERNEL_CONFIG_BINFMT_SCRIPT"),
):
    value = os.environ[env_name]
    if value:
        kernel_config[key] = value == "1"

manifest = {
    "id": os.environ["ASSET_BASE"],
    "project": "sporevm",
    "purpose": os.environ["PURPOSE"],
    "arch": os.environ["KERNEL_ARCH"],
    "linux_version": os.environ["KERNEL_VERSION"],
    "assets": {
        "image": image_name,
        "config": image_name + ".config",
        "sha256": image_name + ".sha256",
        "manifest": os.environ["ASSET_BASE"] + ".manifest.json",
    },
    "kernel_config": kernel_config,
    "sha256": os.environ["KERNEL_SHA256"],
    "source": {
        "repository": os.environ["SOURCE_REPOSITORY"],
        "commit": os.environ["SOURCE_COMMIT"],
        "tag": os.environ["RELEASE_TAG"],
    },
    "builder": {
        "repository": os.environ["SOURCE_REPOSITORY"],
        "script": "scripts/" + os.environ["BUILD_SCRIPT"],
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
  build_sporevm_asset \
    "fork-smoke" \
    "${SPOREVM_KERNEL_ASSET_BASE:-sporevm-${KERNEL_ARCH}-linux-${KERNEL_VERSION}}" \
    "build-sporevm-kernel.sh" \
    "cleanroom-darwin-vz-minimal-initrd" \
    "1" \
    "0"
}

build_sporevm_run_kernel() {
  build_sporevm_asset \
    "run" \
    "${SPOREVM_RUN_KERNEL_ASSET_BASE:-sporevm-run-${KERNEL_ARCH}-linux-${KERNEL_VERSION}}" \
    "build-sporevm-run-kernel.sh" \
    "cleanroom-darwin-vz-minimal-initrd+rootfs" \
    "0" \
    "" \
    "1" \
    "1" \
    "1" \
    "1" \
    "1" \
    "1" \
    "1" \
    "HW_RANDOM" \
    "HW_RANDOM_VIRTIO" \
    "FILE_LOCKING" \
    "SHMEM" \
    "TMPFS" \
    "FSNOTIFY" \
    "INOTIFY_USER" \
    "FHANDLE" \
    "POSIX_MQUEUE" \
    "KEYS" \
    "NAMESPACES" \
    "UTS_NS" \
    "IPC_NS" \
    "PID_NS" \
    "NET_NS" \
    "USER_NS" \
    "CGROUPS" \
    "BPF_SYSCALL" \
    "CGROUP_BPF" \
    "CGROUP_SCHED" \
    "FAIR_GROUP_SCHED" \
    "CFS_BANDWIDTH" \
    "CGROUP_CPUACCT" \
    "CGROUP_DEVICE" \
    "CGROUP_FREEZER" \
    "CGROUP_PIDS" \
    "CPUSETS" \
    "PROC_PID_CPUSET" \
    "MEMCG" \
    "SECCOMP" \
    "SECCOMP_FILTER" \
    "OVERLAY_FS" \
    "TUN" \
    "VETH" \
    "MACVLAN" \
    "IPVLAN" \
    "VXLAN" \
    "BRIDGE" \
    "BRIDGE_NETFILTER" \
    "NETFILTER" \
    "NETFILTER_ADVANCED" \
    "NF_CONNTRACK" \
    "NF_NAT" \
    "NETFILTER_XTABLES" \
    "NETFILTER_XT_TARGET_CHECKSUM" \
    "NETFILTER_XT_TARGET_MASQUERADE" \
    "NETFILTER_XT_TARGET_REDIRECT" \
    "NETFILTER_XT_MATCH_ADDRTYPE" \
    "NETFILTER_XT_MATCH_CONNTRACK" \
    "NF_TABLES" \
    "NF_TABLES_IPV4" \
    "NFT_COMPAT" \
    "NFT_CT" \
    "NFT_MASQ" \
    "NFT_NAT" \
    "NFT_REJECT" \
    "NFT_REJECT_IPV4" \
    "IP_NF_IPTABLES" \
    "IP_NF_FILTER" \
    "IP_NF_TARGET_REJECT" \
    "IP_NF_NAT" \
    "IP_NF_TARGET_MASQUERADE" \
    "IP_NF_TARGET_REDIRECT" \
    "IP_NF_MANGLE" \
    "IP_NF_RAW"
}

for profile in "${KERNEL_PROFILES[@]}"; do
  build_profile "${profile}"
done

if [[ "${INCLUDE_SPOREVM_KERNELS}" = "1" ]]; then
  build_sporevm_kernel
  build_sporevm_run_kernel
fi
