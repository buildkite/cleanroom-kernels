#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[ci-build-release-assets] error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1 || die "missing required command: ${name}"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
KERNEL_RELEASE_DIR="${REPO_ROOT}/dist/kernels"
ARCHIVE_PATH="${REPO_ROOT}/dist/kernels.tar.gz"

require_command docker
require_command git
require_command python3
require_command tar

cd "${REPO_ROOT}"
rm -rf "${KERNEL_RELEASE_DIR}" "${ARCHIVE_PATH}"
mkdir -p "${REPO_ROOT}/dist"

echo "--- :penguin: Build Cleanroom darwin-vz kernel release assets"
"${SCRIPT_DIR}/build-release-assets.sh" "${KERNEL_RELEASE_DIR}"

echo "--- :package: Package kernel release artifacts"
tar -C "${REPO_ROOT}/dist" -czf "${ARCHIVE_PATH}" kernels

if command -v buildkite-agent >/dev/null 2>&1; then
  echo "--- :buildkite: Upload kernel release artifacts"
  buildkite-agent artifact upload "dist/kernels.tar.gz"
  buildkite-agent artifact upload "dist/kernels/*"
else
  printf '[ci-build-release-assets] buildkite-agent not found; skipped artifact upload\n' >&2
fi
