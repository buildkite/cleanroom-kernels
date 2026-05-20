#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[ci-publish-release] error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1 || die "missing required command: ${name}"
}

normalize_secret_value() {
  printf '%s' "$1" | tr -d '\r'
}

fetch_secret_optional() {
  local key="$1"
  buildkite-agent secret get "$key" 2>/dev/null || true
}

resolve_github_token() {
  local token

  token="${GITHUB_TOKEN:-}"
  if [[ -z "${token}" ]]; then
    token="$(fetch_secret_optional CLEANROOM_KERNELS_GITHUB_RELEASE_TOKEN)"
  fi
  if [[ -z "$(normalize_secret_value "${token}")" ]]; then
    token="$(fetch_secret_optional CLEANROOM_GITHUB_RELEASE_TOKEN)"
  fi

  normalize_secret_value "${token}"
}

github_json_request() {
  local method="$1"
  local url="$2"
  local body_path="${3:-}"
  local output_path status

  output_path="$(mktemp)"
  if [[ -n "${body_path}" ]]; then
    status="$(
      curl -sS -X "${method}" \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        --data-binary "@${body_path}" \
        -o "${output_path}" \
        -w "%{http_code}" \
        "${url}"
    )"
  else
    status="$(
      curl -sS -X "${method}" \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -o "${output_path}" \
        -w "%{http_code}" \
        "${url}"
    )"
  fi

  printf '%s\n' "${status}"
  cat "${output_path}"
  rm -f "${output_path}"
}

release_create_body() {
  TAG_NAME="${BUILDKITE_TAG}" \
  TARGET_COMMITISH="${BUILDKITE_COMMIT:-}" \
  python3 - <<'PY'
import json
import os

body = {
    "tag_name": os.environ["TAG_NAME"],
    "name": os.environ["TAG_NAME"],
    "body": "Managed Cleanroom kernel release assets.",
}
target_commitish = os.environ.get("TARGET_COMMITISH", "")
if target_commitish:
    body["target_commitish"] = target_commitish

print(json.dumps(body, sort_keys=True))
PY
}

download_kernel_release_artifacts() {
  local archive_path

  mkdir -p "${DIST_DIR}"
  rm -rf "${KERNEL_RELEASE_DIR}"
  rm -f "${ARCHIVE_PATH}"

  buildkite-agent artifact download "dist/kernels.tar.gz" "${REPO_ROOT}"

  archive_path="${ARCHIVE_PATH}"
  [[ -f "${archive_path}" ]] || die "missing downloaded kernel release archive: ${archive_path}"
  tar -xzf "${archive_path}" -C "${DIST_DIR}"
  [[ -d "${KERNEL_RELEASE_DIR}" ]] || die "missing extracted kernel release directory: ${KERNEL_RELEASE_DIR}"
}

get_or_create_release() {
  local create_body_path release_response status

  release_response="$(github_json_request GET "${GITHUB_API_BASE}/releases/tags/${BUILDKITE_TAG}")"
  status="$(printf '%s\n' "${release_response}" | sed -n '1p')"
  if [[ "${status}" == "200" ]]; then
    printf '%s\n' "${release_response}" | sed '1d'
    return
  fi
  if [[ "${status}" != "404" ]]; then
    printf '%s\n' "${release_response}" >&2
    die "failed to fetch GitHub release ${BUILDKITE_TAG}"
  fi

  create_body_path="$(mktemp)"
  release_create_body > "${create_body_path}"
  release_response="$(github_json_request POST "${GITHUB_API_BASE}/releases" "${create_body_path}")"
  rm -f "${create_body_path}"

  status="$(printf '%s\n' "${release_response}" | sed -n '1p')"
  if [[ "${status}" != "201" ]]; then
    printf '%s\n' "${release_response}" >&2
    die "failed to create GitHub release ${BUILDKITE_TAG}"
  fi

  printf '%s\n' "${release_response}" | sed '1d'
}

release_upload_url() {
  python3 -c 'import json, sys; print(json.load(sys.stdin)["upload_url"].split("{", 1)[0])'
}

release_asset_id() {
  local asset_name="$1"

  ASSET_NAME="${asset_name}" python3 -c '
import json
import os
import sys

name = os.environ["ASSET_NAME"]
for asset in json.load(sys.stdin).get("assets", []):
    if asset.get("name") == name:
        print(asset.get("id", ""))
        break
'
}

publish_github_release_assets() {
  local asset_id asset_name asset_path release_json upload_url
  local -a release_assets

  release_json="$(get_or_create_release)"
  upload_url="$(release_upload_url <<<"${release_json}")"
  [[ -n "${upload_url}" ]] || die "failed to resolve GitHub release upload URL for ${BUILDKITE_TAG}"

  mapfile -t release_assets < <(find "${KERNEL_RELEASE_DIR}" -maxdepth 1 -type f | sort)
  release_assets+=("${ARCHIVE_PATH}")
  [[ "${#release_assets[@]}" -gt 1 ]] || die "missing kernel release assets in ${KERNEL_RELEASE_DIR}"

  for asset_path in "${release_assets[@]}"; do
    [[ -f "${asset_path}" ]] || die "missing release asset: ${asset_path}"
    asset_name="$(basename "${asset_path}")"
    asset_id="$(release_asset_id "${asset_name}" <<<"${release_json}")"

    if [[ -n "${asset_id}" ]]; then
      curl -fsSL -X DELETE \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${GITHUB_API_BASE}/releases/assets/${asset_id}" >/dev/null
    fi

    curl -fsSL \
      -X POST \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Content-Type: application/octet-stream" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      --data-binary "@${asset_path}" \
      "${upload_url}?name=${asset_name}" >/dev/null
  done
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist"
KERNEL_RELEASE_DIR="${DIST_DIR}/kernels"
ARCHIVE_PATH="${DIST_DIR}/kernels.tar.gz"
GITHUB_REPOSITORY_NAME="${CLEANROOM_KERNELS_GITHUB_REPOSITORY:-buildkite/cleanroom-kernels}"
GITHUB_API_BASE="https://api.github.com/repos/${GITHUB_REPOSITORY_NAME}"

require_command buildkite-agent
require_command curl
require_command git
require_command python3
require_command tar

[[ -n "${BUILDKITE_TAG:-}" ]] || die "BUILDKITE_TAG is required for release publishing"

cd "${REPO_ROOT}"
git fetch --tags origin

GITHUB_TOKEN="$(resolve_github_token)"
export GITHUB_TOKEN
[[ -n "${GITHUB_TOKEN}" ]] || die "GITHUB_TOKEN or CLEANROOM_KERNELS_GITHUB_RELEASE_TOKEN is required for release publishing"

echo "--- :package: Download kernel release artifacts"
download_kernel_release_artifacts

echo "--- :rocket: Publish GitHub release assets"
publish_github_release_assets
