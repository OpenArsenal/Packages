# shellcheck shell=bash

task::bootstrap() {
  set -euo pipefail
  if [[ "${DEBUG:-0}" == "1" ]]; then
    set -x
  fi
}

task::require_env() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || {
      echo "error: $name not set" >&2
      exit 1
    }
  done
}
