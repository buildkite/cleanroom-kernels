#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[release] error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_command git
require_command svu

if [[ -n "$(git status --porcelain)" ]]; then
  die "working tree has uncommitted changes"
fi

git fetch --tags origin

CURRENT="$(svu current)"
NEXT="$(svu next)"

[[ -n "${NEXT}" ]] || die "svu did not calculate the next version"

if [[ "${NEXT}" == "${CURRENT}" ]]; then
  printf 'No version bump detected (current: %s). Use conventional commits (feat:, fix:, etc.).\n' "${CURRENT}"
  exit 1
fi

printf 'Releasing %s -> %s\n' "${CURRENT}" "${NEXT}"
git tag "${NEXT}"
git push origin "${NEXT}"
printf 'Tagged and pushed %s - Buildkite release pipeline will publish the release.\n' "${NEXT}"
