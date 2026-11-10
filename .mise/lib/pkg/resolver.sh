# shellcheck shell=bash

declare -Ag PKG_PROVIDER_DIR=()
declare -Ag PKG_PROVIDER_CANDIDATES=()
declare -Ag PKG_STATE=()
declare -Ag PKG_FORCE_DIR=()
declare -ag PKG_PLAN=()

pkg::resolver_reset() {
  PKG_PROVIDER_DIR=()
  PKG_PROVIDER_CANDIDATES=()
  PKG_STATE=()
  PKG_FORCE_DIR=()
  PKG_PLAN=()
}

pkg::index_register() {
  local name="$1"
  local pkg_dir="$2"
  local overwrite="${3:-false}"

  [[ -n "$name" ]] || return 0

  if [[ "$overwrite" == "true" || -z "${PKG_PROVIDER_DIR[$name]+x}" ]]; then
    PKG_PROVIDER_DIR["$name"]="$pkg_dir"
  fi

  # Collect every candidate while preserving single-provider identity precedence.
  PKG_PROVIDER_CANDIDATES["$name"]+="${pkg_dir}"$'\n'
}

pkg::index_packages() {
  local packages_dir="$1"
  local pkg_dir name raw provide_name provide_op provide_ver pkgbase outputs provides

  pkg::resolver_reset
  shopt -s nullglob

  # Repository directory names are explicit identities and always win.
  for pkg_dir in "$packages_dir"/*; do
    [[ -f "$pkg_dir/PKGBUILD" ]] || continue
    pkg::cache_srcinfo "$pkg_dir" || { shopt -u nullglob; return 1; }
    pkg::index_register "${pkg_dir##*/}" "$pkg_dir" true
  done

  # pkgbase/pkgname aliases fill only names that do not identify a directory.
  for pkg_dir in "$packages_dir"/*; do
    [[ -f "$pkg_dir/PKGBUILD" ]] || continue

    pkgbase="$(pkg::metadata_pkgbase "$pkg_dir")" || {
      echo "error: unable to read pkgbase for: $pkg_dir" >&2
      shopt -u nullglob
      return 1
    }
    outputs="$(pkg::metadata_outputs "$pkg_dir")" || {
      echo "error: unable to list package outputs for: $pkg_dir" >&2
      shopt -u nullglob
      return 1
    }

    pkg::index_register "$pkgbase" "$pkg_dir"
    while IFS= read -r name; do
      pkg::index_register "$name" "$pkg_dir"
    done <<<"$outputs"
  done

  # provides= entries are lowest-priority aliases.
  for pkg_dir in "$packages_dir"/*; do
    [[ -f "$pkg_dir/PKGBUILD" ]] || continue

    provides="$(pkg::metadata_provides "$pkg_dir")" || {
      echo "error: unable to list package providers for: $pkg_dir" >&2
      shopt -u nullglob
      return 1
    }

    while IFS= read -r raw; do
      provide_name=""
      provide_op=""
      provide_ver=""
      spec::parse "$raw" provide_name provide_op provide_ver
      pkg::index_register "$provide_name" "$pkg_dir"
    done <<<"$provides"
  done

  shopt -u nullglob
}

pkg::dir_outputs_name() {
  local pkg_dir="$1"
  local wanted="$2"
  local output outputs

  outputs="$(pkg::metadata_outputs "$pkg_dir")" || return 2
  while IFS= read -r output; do
    [[ "$output" == "$wanted" ]] && return 0
  done <<<"$outputs"

  return 1
}

# A versioned dependency is satisfied locally only by a real package output or
# an explicitly versioned provides= entry that meets the constraint.
pkg::provider_matches_version() {
  local pkg_dir="$1" wanted="$2" op="$3" ver="$4"
  local actual raw provide_name provide_op provide_ver provides

  if pkg::dir_outputs_name "$pkg_dir" "$wanted"; then
    actual="$(pkg::metadata_version "$pkg_dir")" || return 2
    if repo::version_satisfies "$actual" "$op" "$ver"; then
      return 0
    fi
  else
    local rc=$?
    (( rc == 1 )) || return "$rc"
  fi

  provides="$(pkg::metadata_provides "$pkg_dir")" || return 2
  while IFS= read -r raw; do
    provide_name=""
    provide_op=""
    provide_ver=""
    spec::parse "$raw" provide_name provide_op provide_ver
    if [[ "$provide_name" == "$wanted" && "$provide_op" == '=' && -n "$provide_ver" ]] &&
      repo::version_satisfies "$provide_ver" "$op" "$ver"; then
      return 0
    fi
  done <<<"$provides"

  return 1
}

pkg::find_local_provider() {
  local dep="$1" op="$2" ver="$3" candidate

  if [[ -z "$op" || -z "$ver" ]]; then
    candidate="${PKG_PROVIDER_DIR[$dep]-}"
    [[ -n "$candidate" ]] || return 1
    printf '%s\n' "$candidate"
    return 0
  fi

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if pkg::provider_matches_version "$candidate" "$dep" "$op" "$ver"; then
      printf '%s\n' "$candidate"
      return 0
    else
      local rc=$?
      (( rc == 1 )) || return "$rc"
    fi
  done <<<"${PKG_PROVIDER_CANDIDATES[$dep]-}"

  return 1
}

# Selected --force providers must be planned before their consumers, even
# when the repository still satisfies the dependency with an older build.
# Iterate the indexed candidates, not arbitrary package names: virtual
# provides= aliases need the same treatment as actual package outputs.
pkg::find_forced_local_provider() {
  local dep="$1" op="$2" ver="$3" candidate rc

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    [[ "${PKG_FORCE_DIR[$candidate]-false}" == "true" ]] || continue

    # Registration in PKG_PROVIDER_CANDIDATES already establishes that an
    # unversioned dependency is provided, including an unversioned alias.
    if [[ -z "$op" || -z "$ver" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi

    if pkg::provider_matches_version "$candidate" "$dep" "$op" "$ver"; then
      printf '%s\n' "$candidate"
      return 0
    else
      rc=$?
      (( rc == 1 )) || return "$rc"
    fi
  done <<<"${PKG_PROVIDER_CANDIDATES[$dep]-}"

  return 1
}

# A forced local package with an actual output matching this dependency
# replaces the published version during this build run. It must satisfy the
# consumer's constraint even when the *old* published version currently does.
# Do not treat provides= aliases as replacements: another package may remain
# installed and continue to satisfy a virtual dependency independently.
pkg::check_forced_output_replacements() {
  local dep="$1" op="$2" ver="$3"
  local candidate replacement_version rc
  local -A checked=()

  [[ -n "$op" && -n "$ver" ]] || return 0

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    [[ "${PKG_FORCE_DIR[$candidate]-false}" == "true" ]] || continue
    [[ -z "${checked[$candidate]+x}" ]] || continue
    checked["$candidate"]=1

    if pkg::dir_outputs_name "$candidate" "$dep"; then
      replacement_version="$(pkg::metadata_version "$candidate")" || {
        echo "error: unable to inspect forced replacement version for: $dep" >&2
        return 2
      }
      if ! repo::version_satisfies "$replacement_version" "$op" "$ver"; then
        echo "error: forced replacement of '$dep' by ${candidate##*/} ($replacement_version) is incompatible with dependency '$dep$op$ver'" >&2
        return 2
      fi
    else
      rc=$?
      if (( rc != 1 )); then
        echo "error: unable to inspect forced replacement output: $candidate" >&2
        return "$rc"
      fi
    fi
  done <<<"${PKG_PROVIDER_CANDIDATES[$dep]-}"

  return 0
}

pkg::all_outputs_in_repo() {
  local pkg_dir="$1"
  local version output outputs
  local found=false

  version="$(pkg::metadata_version "$pkg_dir")" || {
    echo "error: unable to determine package version for: $pkg_dir" >&2
    return 2
  }
  outputs="$(pkg::metadata_outputs "$pkg_dir")" || {
    echo "error: unable to list package outputs for: $pkg_dir" >&2
    return 2
  }

  while IFS= read -r output; do
    [[ -n "$output" ]] || continue
    found=true
    repo::is_dep_satisfied "$REPO_DIR" "$output" ">=" "$version" || return 1
  done <<<"$outputs"

  if [[ "$found" != true ]]; then
    echo "error: package declares no outputs: $pkg_dir" >&2
    return 2
  fi
}

pkg::plan_deps() {
  local pkg_dir="$1"
  local pkg_label="$2"
  local raw dep op ver provider_dir dependencies

  dependencies="$(pkg::metadata_deps "$pkg_dir")" || {
    echo "error: unable to list dependencies for: $pkg_label" >&2
    return 1
  }
  while IFS= read -r raw; do
    [[ -n "$raw" ]] || continue

    dep=""
    op=""
    ver=""
    spec::parse "$raw" dep op ver
    [[ -n "$dep" ]] || continue

    if pkg::dir_outputs_name "$pkg_dir" "$dep"; then
      continue
    else
      local rc=$?
      if (( rc != 1 )); then
        echo "error: unable to inspect outputs for: $pkg_dir" >&2
        return 1
      fi
    fi

    # A forced local output may replace the version currently satisfying this
    # dependency in the repository. Reject incompatible plans before any build,
    # regardless of the order in which recipes were explicitly selected.
    pkg::check_forced_output_replacements "$dep" "$op" "$ver" || return 1

    # All explicit --force selections were marked before dependency traversal.
    # Plan a compatible selected provider first even if the published
    # repository still contains an older build that satisfies this dependency.
    if provider_dir="$(pkg::find_forced_local_provider "$dep" "$op" "$ver")"; then
      if [[ "$provider_dir" != "$pkg_dir" ]]; then
        pkg::plan_dir "$provider_dir" || return 1
      fi
      continue
    else
      local rc=$?
      if (( rc != 1 )); then
        echo "error: unable to inspect forced local provider for: $raw" >&2
        return 1
      fi
    fi

    if repo::is_dep_satisfied "$REPO_DIR" "$dep" "$op" "$ver"; then
      continue
    fi

    if provider_dir="$(pkg::find_local_provider "$dep" "$op" "$ver")"; then
      :
    else
      local rc=$?
      if (( rc != 1 )); then
        echo "error: unable to inspect local providers for: $raw" >&2
        return 1
      fi
      provider_dir=""
    fi
    if [[ -n "$provider_dir" ]]; then
      if [[ "$provider_dir" == "$pkg_dir" ]]; then
        continue
      fi

      # The repository did not satisfy this dependency's constraint. The
      # compatible local recipe must be built, even if a newer but
      # incompatible output already exists in the repository.
      PKG_FORCE_DIR["$provider_dir"]="true"
      pkg::plan_dir "$provider_dir" || return 1
      continue
    fi

    if pkg::pacman_can_resolve "$raw"; then
      continue
    fi

    echo "error: unresolved dependency for $pkg_label: $raw" >&2
    return 1
  done <<<"$dependencies"
}

pkg::plan_dir() {
  local pkg_dir="$1"
  local key

  pkg::validate_dir "$pkg_dir" || return

  key="$pkg_dir"

  case "${PKG_STATE[$key]-}" in
    done) return 0 ;;
    # A previously satisfied selection can become necessary when a later
    # dependency requires a version not available from the repository.
    satisfied)
      [[ "${PKG_FORCE_DIR[$key]-false}" == "true" ]] || return 0
      ;;
    visiting)
      echo "error: dependency cycle detected at package: ${pkg_dir##*/}" >&2
      return 1
      ;;
  esac

  PKG_STATE["$key"]="visiting"

  if [[ "${PKG_FORCE_DIR[$key]-false}" != "true" ]]; then
    if pkg::all_outputs_in_repo "$pkg_dir"; then
      PKG_STATE["$key"]="satisfied"
      return 0
    else
      local rc=$?
      if (( rc != 1 )); then
        unset "PKG_STATE[$key]"
        return "$rc"
      fi
    fi
  fi

  if ! pkg::plan_deps "$pkg_dir" "$key"; then
    unset "PKG_STATE[$key]"
    return 1
  fi
  PKG_PLAN+=("$pkg_dir")
  PKG_STATE["$key"]="done"
}

pkg::plan_selected() {
  local packages_dir="$1"
  local force_selected="$2"
  shift 2
  local entry pkg_dir
  local -a selected_dirs=()

  case "$force_selected" in
    true|false) ;;
    *)
      echo "error: invalid force flag: $force_selected" >&2
      return 2
      ;;
  esac

  # A failed repository index must not be mistaken for unsatisfied
  # dependencies, causing builds to start against unreadable repository state.
  repo::ensure_index "$REPO_DIR" || return 1
  pkg::index_packages "$packages_dir" || return 1

  # Resolve and mark every explicit selection before traversing dependencies.
  # This guarantees --force applies even when one selected package is visited
  # first as another selected package's dependency.
  for entry in "$@"; do
    if [[ -d "$entry" || ( "$entry" != */* && -d "$packages_dir/$entry" ) ]]; then
      pkg_dir="$(pkg::resolve_dir "$entry" "$packages_dir")" || return 1
    else
      pkg_dir="${PKG_PROVIDER_DIR[$entry]-}"
      [[ -n "$pkg_dir" ]] || {
        echo "error: no local package provides: $entry" >&2
        return 1
      }
    fi

    selected_dirs+=("$pkg_dir")

    if [[ "$force_selected" == "true" ]]; then
      PKG_FORCE_DIR["$pkg_dir"]="true"
    fi
  done

  for pkg_dir in "${selected_dirs[@]}"; do
    pkg::plan_dir "$pkg_dir" || return 1
  done
}

pkg::print_plan() {
  local pkg_dir

  for pkg_dir in "${PKG_PLAN[@]}"; do
    printf '%s\t%s\n' "${pkg_dir##*/}" "$pkg_dir"
  done
}

pkg::build_plan() {
  local pkg_dir marker
  local published=false

  if declare -F chroot::enable_repo >/dev/null 2>&1; then
    chroot::enable_repo || {
      echo "error: unable to configure the build chroot repository" >&2
      return 1
    }
  fi

  for pkg_dir in "${PKG_PLAN[@]}"; do
    # shortcut: assumes one writer to REPO_DIR; use staged outputs for parallel builds.
    marker="$(mktemp)" || return 1
    if ! pkg::build_dir "$pkg_dir" || ! pkg::publish_outputs "$pkg_dir" "$marker"; then
      rm -f -- "$marker"
      return 1
    fi
    rm -f -- "$marker" || return 1
    published=true

    if declare -F chroot::enable_repo >/dev/null 2>&1; then
      chroot::enable_repo || {
        echo "error: unable to refresh the build chroot repository" >&2
        return 1
      }
    fi
  done

  if [[ "$published" == "true" ]] && declare -F repo::refresh_sync_db >/dev/null 2>&1; then
    : "${REPO_NAME:?REPO_NAME not set}"

    if ! repo::refresh_sync_db "$REPO_NAME"; then
      echo "error: packages were published, but the host sync database refresh failed" >&2
      return 1
    fi
  fi
}

pkg::build_selected() {
  local packages_dir="$1"
  local force_selected="$2"
  shift 2

  pkg::plan_selected "$packages_dir" "$force_selected" "$@" || return 1
  pkg::build_plan
}
