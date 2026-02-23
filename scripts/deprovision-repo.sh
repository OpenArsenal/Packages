#!/usr/bin/env bash
set -euo pipefail

: "${REPO_DIR:?REPO_DIR is required}"
: "${REPO_DB:?REPO_DB is required}"

REPO_GROUP="${REPO_GROUP:-${REPO_NAME:-}}"
if [[ -z "${REPO_GROUP}" ]]; then
  echo "REPO_GROUP (or REPO_NAME) is required to determine repo group cleanup." >&2
  exit 1
fi

REMOVE_DB="${REMOVE_DB:-1}"
REMOVE_DIR="${REMOVE_DIR:-1}"
FORCE_REMOVE_DIR="${FORCE_REMOVE_DIR:-0}"
REMOVE_GROUP="${REMOVE_GROUP:-1}"

err()  { echo "error: $*" >&2; }
info() { echo "$*"; }

run_root() { run0 "$@"; }

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

remove_user_from_group() {
  local user="$1"
  local group="$2"

  if is_homed_user "$user"; then
    local aux member_of
    if ! aux="$(homed_aux_groups "$user")"; then
      err "systemd-homed user '$user' detected, but failed to parse Aux. Groups."
      err "Cannot safely remove '$group' because homectl --member-of replaces the whole list."
      err "Run: homectl inspect \"$user\" and remove '$group' manually."
      return 1
    fi

    member_of="$(
      printf '%s\n' "$aux" \
        | grep -vxF "$group" \
        | paste -sd, - || true
    )"

    info "Removing homed user '$user' from '$group' via homectl..."
    run_root homectl update "$user" --member-of="$member_of"
    return 0
  fi

  if command -v gpasswd >/dev/null 2>&1; then
    info "Removing user '$user' from '$group' via gpasswd..."
    run_root gpasswd -d "$user" "$group" >/dev/null
    return 0
  fi

  local cur new
  cur="$(id -nG "$user" | tr ' ' '\n' | sed '/^$/d' | sort -u)"
  new="$(printf '%s\n' "$cur" | grep -vxF "$group" | paste -sd, - || true)"
  info "Removing user '$user' from '$group' via usermod -G..."
  run_root usermod -G "$new" "$user"
}

require_safe_repo_dir() {
  local dir="$1"
  if [[ -z "$dir" || "$dir" == "/" ]]; then
    err "Refusing to operate on REPO_DIR='$dir'."
    exit 1
  fi
}

db_sidecars() {
  local db="$1"
  local -a c=()

  c+=("${db}.old")

  if [[ "$db" == *.db ]]; then
    c+=(
      "${db}.tar.gz" "${db}.tar.gz.old"
      "${db}.tar.bz2" "${db}.tar.bz2.old"
    )
  fi

  if [[ "$db" == *.db.tar.gz ]]; then
    c+=("${db%.tar.gz}")
  fi
  if [[ "$db" == *.db.tar.bz2 ]]; then
    c+=("${db%.tar.bz2}")
  fi

  printf '%s\n' "${c[@]}"
}

remove_db() {
  local db="$1"

  if [[ -e "$db" ]]; then
    info "Removing repo DB: $db"
    run_root rm -f "$db"
  else
    info "Repo DB not found; skipping: $db"
  fi

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if [[ -e "$f" ]]; then
      info "Removing DB sidecar: $f"
      run_root rm -f "$f"
    fi
  done < <(db_sidecars "$db")
}

remove_repo_root_and_maybe_parent() {
  local repo_dir="$1"
  local force="$2"
  local repo_root
  repo_root="$(dirname "$REPO_DB")"

  if [[ -d "$repo_root" ]]; then
    if [[ "$force" == "1" ]]; then
      info "FORCE_REMOVE_DIR=1 -> removing directory recursively: $repo_root"
      run_root rm -rf --one-file-system "$repo_root"
    else
      info "Attempting to remove repo root dir if empty: $repo_root"
      if run_root rmdir "$repo_root" 2>/dev/null; then
        info "Removed empty directory: $repo_root"
      else
        err "Repo root dir not empty (or could not remove): $repo_root"
        err "If you really want it gone, empty it first or set FORCE_REMOVE_DIR=1 (DANGEROUS)."
        exit 1
      fi
    fi
  else
    info "Repo root dir not found; skipping: $repo_root"
  fi

  if [[ -d "$repo_dir" ]]; then
    info "Attempting to remove parent repo dir if empty: $repo_dir"
    run_root rmdir "$repo_dir" 2>/dev/null || true
  fi
}

group_gid() {
  local group="$1"
  getent group "$group" | awk -F: '{print $3}'
}

group_members_csv() {
  local group="$1"
  getent group "$group" | awk -F: '{print $4}'
}

primary_users_for_gid() {
  local gid="$1"
  awk -F: -v gid="$gid" '($4==gid){print $1}' /etc/passwd || true
}

maybe_force_clear_group_members() {
  local group="$1"
  local force="$2"

  if [[ "$force" != "1" ]]; then
    return 0
  fi

  local members_csv
  members_csv="$(group_members_csv "$group")"
  [[ -z "$members_csv" ]] && return 0

  info "FORCE_REMOVE_DIR=1 -> removing all supplementary members from group '$group': $members_csv"
  IFS=',' read -r -a member_arr <<< "$members_csv"
  for u in "${member_arr[@]}"; do
    [[ -z "${u// }" ]] && continue
    remove_user_from_group "$u" "$group"
  done
}

maybe_force_reassign_primary_users() {
  local group="$1"
  local force="$2"
  local gid
  gid="$(group_gid "$group")"

  local primary_users
  primary_users="$(primary_users_for_gid "$gid")"
  [[ -z "$primary_users" ]] && return 0

  if [[ "$force" != "1" ]]; then
    err "Refusing to delete group '$group': it is primary for user(s):"
    err "$primary_users"
    exit 1
  fi

  info "FORCE_REMOVE_DIR=1 -> reassigning primary group for user(s):"
  info "$primary_users"

  while IFS= read -r u; do
    [[ -z "$u" ]] && continue

    local newgid=""
    if getent group "$u" >/dev/null 2>&1; then
      newgid="$(getent group "$u" | awk -F: '{print $3}')"
    elif getent group users >/dev/null 2>&1; then
      newgid="$(getent group users | awk -F: '{print $3}')"
    else
      err "No suitable fallback primary group found for '$u' (need group '$u' or 'users')."
      err "Create one, or set a specific fallback group and extend the script."
      exit 1
    fi

    info "Changing primary group for '$u' to GID $newgid"
    run_root usermod -g "$newgid" "$u"
  done <<< "$primary_users"
}

delete_group_if_unused() {
  local group="$1"
  local force="$2"

  if ! getent group "$group" >/dev/null 2>&1; then
    info "Group not found; skipping: $group"
    return 0
  fi

  maybe_force_clear_group_members "$group" "$force"
  maybe_force_reassign_primary_users "$group" "$force"

  local members primary_users gid
  members="$(group_members_csv "$group")"
  gid="$(group_gid "$group")"
  primary_users="$(primary_users_for_gid "$gid")"

  if [[ -n "$members" ]]; then
    err "Refusing to delete group '$group': it still has members: $members"
    if [[ "$force" != "1" ]]; then
      err "Set FORCE_REMOVE_DIR=1 to force member removal."
    fi
    exit 1
  fi
  if [[ -n "$primary_users" ]]; then
    err "Refusing to delete group '$group': it is primary for user(s):"
    err "$primary_users"
    exit 1
  fi

  info "Deleting group: $group"
  run_root groupdel "$group"
}

main() {
  require_safe_repo_dir "$REPO_DIR"

  if [[ "$REMOVE_DB" == "1" ]]; then
    remove_db "$REPO_DB"
  fi

  if [[ "$REMOVE_DIR" == "1" ]]; then
    remove_repo_root_and_maybe_parent "$REPO_DIR" "$FORCE_REMOVE_DIR"
  fi

  if [[ "$REMOVE_GROUP" == "1" ]]; then
    delete_group_if_unused "$REPO_GROUP" "$FORCE_REMOVE_DIR"
  fi

  info "OK"
}

main "$@"
