#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KERNEL_VERSION="${CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_VERSION:-6.1.155}"
KERNEL_ARCH="${CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_ARCH:-arm64}"

OUTPUT_PATH="${1:-${REPO_ROOT}/dist/sporevm-run-${KERNEL_ARCH}-linux-${KERNEL_VERSION}-Image}"

CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_PROFILE=sporevm-run \
  "${SCRIPT_DIR}/build-kernel.sh" "${OUTPUT_PATH}"
