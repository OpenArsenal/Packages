#!/usr/bin/env bash
# Shared test setup for the Bats suite. No Arch tooling is required.
bats_repo_setup() {
  root="$(cd -- "$BATS_TEST_DIRNAME/../.." && pwd -P)" || return 1
  set -euo pipefail
}

# Preserve the existing behavior-oriented assertions during migration.
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
