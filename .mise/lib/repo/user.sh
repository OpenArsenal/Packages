# shellcheck shell=bash

repo::group_exists() {
  getent group "$1" >/dev/null 2>&1
}

repo::ensure_group() {
  local group="$1"

  repo::group_exists "$group" && return 0

  echo "Creating group: $group"
  if run0 groupadd "$group"; then
    return 0
  fi

  if repo::group_exists "$group"; then
    echo "Group '$group' already exists; continuing."
    return 0
  fi

  echo "error: failed to create group: $group" >&2
  return 1
}

repo::is_homed_user() {
  command -v homectl >/dev/null 2>&1 || return 1
  homectl inspect "$1" >/dev/null 2>&1
}

repo::homed_aux_groups() {
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

repo::list_contains() {
  grep -qxF "$1"
}

repo::member_of_from_aux_plus() {
  local group="$1"
  { cat; printf '%s\n' "$group"; } |
    sed '/^$/d' |
    sort -u |
    paste -sd, -
}

repo::add_user_to_group() {
  local user="$1"
  local group="$2"

  if repo::is_homed_user "$user"; then
    local aux member_of

    aux="$(repo::homed_aux_groups "$user")" || {
      echo "error: failed to parse Aux. Groups for homed user: $user" >&2
      return 1
    }

    if printf '%s\n' "$aux" | repo::list_contains "$group"; then
      echo "Homed user '$user' already belongs to '$group'."
      return 0
    fi

    member_of="$(printf '%s\n' "$aux" | repo::member_of_from_aux_plus "$group")"
    echo "Adding homed user '$user' to '$group'..."
    run0 homectl update "$user" --member-of="$member_of"

    aux="$(repo::homed_aux_groups "$user")" || return 1
    printf '%s\n' "$aux" | repo::list_contains "$group"
    return
  fi

  echo "Adding '$user' to '$group'..."
  run0 usermod -aG "$group" "$user"
}

repo::remove_user_from_group() {
  local user="$1"
  local group="$2"

  if repo::is_homed_user "$user"; then
    local aux member_of

    aux="$(repo::homed_aux_groups "$user")" || {
      echo "error: failed to parse Aux. Groups for homed user: $user" >&2
      return 1
    }

    member_of="$(
      printf '%s\n' "$aux" |
        grep -vxF "$group" |
        paste -sd, - || true
    )"

    echo "Removing homed user '$user' from '$group'..."
    run0 homectl update "$user" --member-of="$member_of"
    return
  fi

  if command -v gpasswd >/dev/null 2>&1; then
    echo "Removing '$user' from '$group'..."
    run0 gpasswd -d "$user" "$group" >/dev/null
    return
  fi

  local current next
  current="$(id -nG "$user" | tr ' ' '\n' | sed '/^$/d' | sort -u)"
  next="$(printf '%s\n' "$current" | grep -vxF "$group" | paste -sd, - || true)"
  run0 usermod -G "$next" "$user"
}

repo::group_members() {
  getent group "$1" | awk -F: '{print $4}'
}

repo::users_with_primary_group() {
  local group="$1"
  local gid

  gid="$(getent group "$group" | awk -F: '{print $3}')"
  [[ -n "$gid" ]] || return 0

  getent passwd | awk -F: -v gid="$gid" '$4 == gid { print $1 }'
}

repo::reassign_primary_users() {
  local group="$1"
  local new_group="${2:-users}"
  local user

  repo::group_exists "$new_group" || {
    echo "error: target primary group does not exist: $new_group" >&2
    return 1
  }

  while IFS= read -r user; do
    [[ -n "$user" ]] || continue
    echo "Reassigning '$user' primary group to '$new_group'..."
    run0 usermod -g "$new_group" "$user"
  done < <(repo::users_with_primary_group "$group")
}

repo::delete_group_if_unused() {
  local group="$1"
  local force_members="$2"
  local force_primary="$3"

  repo::group_exists "$group" || {
    echo "Group '$group' not found; skipping."
    return 0
  }

  local primary_count members user
  primary_count="$(repo::users_with_primary_group "$group" | wc -l | tr -d ' ')"
  members="$(repo::group_members "$group" || true)"

  if (( primary_count > 0 )); then
    [[ "$force_primary" == "1" ]] || {
      echo "error: group '$group' is the primary group for $primary_count user(s)" >&2
      return 1
    }
    repo::reassign_primary_users "$group" users
  fi

  if [[ -n "$members" ]]; then
    [[ "$force_members" == "1" ]] || {
      echo "error: group '$group' has supplementary members: $members" >&2
      return 1
    }

    IFS=',' read -r -a member_list <<<"$members"
    for user in "${member_list[@]}"; do
      [[ -n "$user" ]] || continue
      repo::remove_user_from_group "$user" "$group"
    done
  fi

  echo "Deleting group: $group"
  run0 groupdel "$group"
}
