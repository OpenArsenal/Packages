#!/usr/bin/env bash
set -euo pipefail

trap 'rc=$?; echo "FAILED (rc=$rc) at line $LINENO: $BASH_COMMAND" >&2' ERR

: "${REPO_DIR:?REPO_DIR is required}"
: "${REPO_DB:?REPO_DB is required}"

REPO_GROUP="${REPO_GROUP:-${REPO_NAME:-}}"
if [[ -z "${REPO_GROUP}" ]]; then
  echo "REPO_GROUP (or REPO_NAME) is required to set repo directory group ownership." >&2
  exit 1
fi

info() { echo "$*"; }
err()  { echo "error: $*" >&2; }

run_root() { run0 "$@"; }

require_safe_repo_dir() {
  local dir="$1"
  if [[ -z "$dir" || "$dir" == "/" ]]; then
    err "Refusing to operate on REPO_DIR='$dir'."
    exit 1
  fi
}

# Trigger polkit once, then reuse the same elevated context by running all root ops in one run0 session.
run_root_block() {
  local script
  script="$(
    cat <<'EOS'
set -euo pipefail

dir="$1"
group="$2"
db="$3"

install -d -m 2775 -o root -g "$group" "$dir"
chown root:"$group" "$dir"
chmod 2775 "$dir"
find "$dir" -type d -exec chmod g+s {} +

db_dir="$(dirname "$db")"
install -d -m 2775 -o root -g "$group" "$db_dir"
chown root:"$group" "$db_dir"
chmod 2775 "$db_dir"

if [[ ! -f "$db" ]]; then
  touch "$db"
  chown root:"$group" "$db"
  chmod 664 "$db"
fi
EOS
  )"

  run_root bash -lc "$script" -- "$REPO_DIR" "$REPO_GROUP" "$REPO_DB"
}

is_homed_user() {
  command -v homectl >/dev/null 2>&1 || return 1
  homectl inspect "$1" >/dev/null 2>&1
}

assert_repo_writable_or_explain() {
  local dir="$1"
  local user="$2"
  local group="$3"

  [[ -w "$dir" ]] && return 0

  err "Repo dir exists but is not writable: $dir"
  if [[ -n "$user" ]] && is_homed_user "$user"; then
    err "Ensure '$user' is in '$group':"
    err "  homectl inspect \"$user\" | sed -n '/Aux\\. Groups:/,/^[A-Z]/p'"
  else
    err "Join '$group' and re-login (or run: newgrp $group)."
  fi
  exit 1
}

main() {
  require_safe_repo_dir "$REPO_DIR"

  info "Provisioning repo dir: $REPO_DIR"
  info "Using repo group: $REPO_GROUP"

  scripts_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  add_user_script="$scripts_dir/repo-group-add-user.sh"

  if [[ -f "$add_user_script" && ! -x "$add_user_script" ]]; then
    info "Marking executable: $add_user_script"
    chmod +x "$add_user_script"
  fi

  # Add user membership first (may prompt once if homed and needs update)
  bash "$add_user_script" --group "$REPO_GROUP" "${USER:-}"

  # Do all privileged filesystem work in ONE run0 call to avoid multiple polkit prompts
  run_root_block

  assert_repo_writable_or_explain "$REPO_DIR" "${USER:-}" "$REPO_GROUP"

  info "OK"
}

main "$@"
