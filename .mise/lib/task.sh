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

task::run_root() {
  if (( EUID == 0 )); then
    "$@"
  elif command -v run0 >/dev/null 2>&1; then
    run0 "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "error: root privileges required; install run0 or sudo" >&2
    return 127
  fi
}

task::has_root_runner() {
  (( EUID == 0 ))     || command -v run0 >/dev/null 2>&1     || command -v sudo >/dev/null 2>&1
}
