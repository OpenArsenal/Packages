#!/usr/bin/env bash
set -euo pipefail

REPO_GROUP="${REPO_GROUP:-openarsenal}"
TARGET_USER=""
PRINT_ONLY="0"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--group NAME] [--print] [user]

Adds [user] (default: current user) to the repo group.

Behavior:
- Non-homed users → usermod -aG
- systemd-homed users → homectl update --member-of=...

Options:
  --group NAME   Override repo group
  --print        Print homectl command only (no changes)
  -h, --help     Show this help

Env:
  REPO_GROUP     Default group if --group not provided
EOF
}

info() { echo "$*"; }
err()  { echo "error: $*" >&2; }

run_root() { run0 "$@"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "missing required command: $1"
    exit 127
  }
}

group_exists() {
  getent group "$1" >/dev/null 2>&1
}

ensure_group_exists() {
  local group="$1"

  group_exists "$group" && return 0

  info "Creating group: $group"
  if run_root groupadd "$group"; then
    return 0
  fi

  if group_exists "$group"; then
    info "Group '$group' already exists (detected after groupadd); continuing."
    return 0
  fi

  err "Failed to create group '$group'."
  err "Try: run0 groupadd '$group'"
  exit 1
}

is_homed_user() {
  command -v homectl >/dev/null 2>&1 || return 1
  homectl inspect "$1" >/dev/null 2>&1
}

homed_aux_groups() {
  local user="$1"

  homectl inspect "$user" | awk '
    BEGIN { in_section=0; saw=0 }
    /^[[:space:]]*Aux\.[[:space:]]Groups:/ {
      in_section=1; saw=1
      sub(/^[[:space:]]*Aux\.[[:space:]]Groups:[[:space:]]*/, "", $0)
      if (length($0)) print $0
      next
    }
    in_section==1 && /^[[:space:]]*[A-Z][A-Za-z[:space:]]*:/ { in_section=0 }
    in_section==1 {
      gsub(/^[[:space:]]+/, "", $0)
      if (length($0)) print $0
    }
    END { if (saw==0) exit 3 }
  ' | sed '/^$/d' | sort -u
}

list_contains() { grep -qxF "$1"; }

member_of_from_aux_plus() {
  local group="$1"
  { cat; printf '%s\n' "$group"; } \
    | sed '/^$/d' \
    | sort -u \
    | paste -sd, -
}

add_user_non_homed() {
  local user="$1"
  local group="$2"

  info "Adding '$user' to group '$group' using usermod..."
  run_root usermod -aG "$group" "$user"
}

add_user_homed() {
  local user="$1"
  local group="$2"

  local aux
  if ! aux="$(homed_aux_groups "$user")"; then
    err "Failed to parse Aux. Groups for homed user '$user'."
    err "Run: homectl inspect \"$user\""
    exit 1
  fi

  if printf '%s\n' "$aux" | list_contains "$group"; then
    info "Homed user '$user' already in '$group'; nothing to do."
    return 0
  fi

  local member_of
  member_of="$(printf '%s\n' "$aux" | member_of_from_aux_plus "$group")"

  if [[ "$PRINT_ONLY" == "1" ]]; then
    info "Run:"
    info "  run0 homectl update \"$user\" --member-of=\"$member_of\""
    return 0
  fi

  info "Adding homed user '$user' to '$group' via homectl..."
  set +e
  run_root homectl update "$user" --member-of="$member_of"
  local rc=$?
  set -e

  aux="$(homed_aux_groups "$user" || true)"
  if printf '%s\n' "$aux" | list_contains "$group"; then
    [[ $rc -ne 0 ]] && info "homectl returned rc=$rc but membership is present."
    info "OK. '$user' is now in '$group' (systemd-homed)."
    info "Note: some sessions may require re-login."
    return 0
  fi

  err "Failed to add '$user' to '$group'."
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --group)
        REPO_GROUP="${2:-}"
        shift 2
        ;;
      --print)
        PRINT_ONLY="1"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        TARGET_USER="$1"
        shift
        ;;
    esac
  done

  TARGET_USER="${TARGET_USER:-${USER:-}}"

  if [[ -z "$TARGET_USER" ]]; then
    err "No user specified and \$USER is empty."
    exit 2
  fi
}

main() {
  need_cmd getent
  need_cmd run0

  parse_args "$@"

  ensure_group_exists "$REPO_GROUP"

  if is_homed_user "$TARGET_USER"; then
    need_cmd homectl
    add_user_homed "$TARGET_USER" "$REPO_GROUP"
    exit 0
  fi

  add_user_non_homed "$TARGET_USER" "$REPO_GROUP"

  info "OK. Group entry now:"
  getent group "$REPO_GROUP" || true
}

main "$@"
