# shellcheck shell=bash

# Copy recipe inputs, not ignored build output. Use working-tree contents so
# local edits and untracked source patches are included in the candidate.
pkg::stage_update_recipe() {
  local dir="$1" stage="$2" file
  for file in PKGBUILD .SRCINFO .nvchecker.toml; do
    if [[ -L "$dir/$file" ]]; then
      echo "error: refusing to stage symlinked recipe metadata: $dir/$file" >&2
      return 1
    fi
  done
  mkdir -p -- "$stage" || return 1

  if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    (
      cd "$dir" || exit 1
      git ls-files -z --cached --others --exclude-standard -- . >"$stage/.update-inputs" || exit 1
      while IFS= read -r -d '' file; do
        [[ -e "$file" || -L "$file" ]] || continue
        cp -a --parents -- "$file" "$stage" || exit 1
      done <"$stage/.update-inputs"
      rm -f -- "$stage/.update-inputs"
    ) || return 1
    # Explicitly selected recipes may be ignored by the enclosing Git tree.
    for file in PKGBUILD .SRCINFO .nvchecker.toml; do
      [[ -f "$dir/$file" ]] || continue
      cp -a -- "$dir/$file" "$stage/$file" || return 1
    done
  else
    cp -a -- "$dir/." "$stage/" || return 1
  fi
}

# Return 0 for resolvable exact dependencies, 1 to defer, and 2 on
# inspection errors. Check the generated candidate, not its old metadata.
pkg::update_exact_deps_available() {
  local stage="$1" original="$2"
  local deps raw dep op ver self_version provider rc
  local indexed=false
  deps="$(pkg::metadata_deps "$stage")" || return 2
  while IFS= read -r raw; do
    [[ -n "$raw" ]] || continue
    dep="" op="" ver=""
    spec::parse "$raw" dep op ver
    [[ "$op" == '=' ]] || continue

    # Split outputs must agree with the version of the candidate itself.
    if pkg::dir_outputs_name "$stage" "$dep"; then
      self_version="$(pkg::metadata_version "$stage")" || return 2
      if repo::version_satisfies "$self_version" "$op" "$ver"; then
        continue
      fi
      echo "Deferred ${original##*/}: incompatible split-package dependency $raw" >&2
      return 1
    else
      rc=$?
      (( rc == 1 )) || return 2
    fi

    # Use the same sync-repository resolver as the build planner. Do not
    # refresh databases or install packages during update preflight.
    if pkg::pacman_can_resolve "$raw"; then
      continue
    fi
    if [[ -n "${REPO_DIR:-}" ]]; then
      repo::ensure_index "$REPO_DIR" || return 2
      if repo::is_dep_satisfied "$REPO_DIR" "$dep" "$op" "$ver"; then
        continue
      fi
    fi

    if [[ "$indexed" == false ]]; then
      pkg::index_packages "$PACKAGES_DIR" || return 2
      indexed=true
    fi
    local matched=false
    while IFS= read -r provider; do
      [[ -n "$provider" && "$provider" != "$original" ]] || continue
      if pkg::provider_matches_version "$provider" "$dep" "$op" "$ver"; then
        matched=true
        break
      else
        rc=$?
        (( rc == 1 )) || return 2
      fi
    done <<<"${PKG_PROVIDER_CANDIDATES[$dep]-}"
    [[ "$matched" == true ]] && continue

    echo "Deferred ${original##*/}: exact dependency unavailable: $raw" >&2
    echo "  Existing PKGBUILD and .SRCINFO left unchanged; retry when the dependency is available." >&2
    return 1
  done <<<"$deps"
  return 0
}

pkg::apply_release_update() (
  local dir="$1"
  shift
  local tmp stage field rc build_tmp="" info_tmp=""

  # These recipes pin Chromium source revisions as well as pkgver.
  local helper
  for helper in update-ffmpeg-ref.sh; do
    [[ -f "$dir/$helper" ]] || continue
    if pkgctl version check --verbose "$dir"; then
      exit 0
    else
      rc=$?
    fi
    if (( rc == 2 )); then
      printf 'Manual update required: %s\n' "${dir##*/}"
      printf '  Run: bash %q --latest\n' "$dir/$helper"
      printf '  This synchronizes the tracked version, source revision, checksums and .SRCINFO.\n'
      exit 0
    fi
    exit "$rc"
  done

  tmp="$(mktemp -d)" || exit 1
  trap 'rm -rf -- "$tmp"; [[ -z "$build_tmp" ]] || rm -f -- "$build_tmp"; [[ -z "$info_tmp" ]] || rm -f -- "$info_tmp"' EXIT
  stage="$tmp/${dir##*/}"

  pkg::stage_update_recipe "$dir" "$stage" || exit 1
  # pkgctl can partially edit a recipe even when checksum generation fails.
  # Only ever run it against the private candidate.
  if pkgctl "$@" "$stage"; then
    :
  else
    rc=$?
    echo "error: update failed for ${dir##*/}; preserving existing metadata" >&2
    exit "$rc"
  fi

  if ! (cd "$stage" && makepkg --printsrcinfo) >"$tmp/srcinfo"; then
    echo "error: failed to refresh .SRCINFO for: ${dir##*/}; preserving existing metadata" >&2
    exit 1
  fi
  for field in pkgbase pkgver pkgrel pkgname; do
    if ! grep -Eq "^[[:space:]]*${field} = [^[:space:]]+" "$tmp/srcinfo"; then
      echo "error: invalid generated .SRCINFO (missing $field): ${dir##*/}; preserving existing metadata" >&2
      exit 1
    fi
  done
  mv -f -- "$tmp/srcinfo" "$stage/.SRCINFO" || exit 1

  if pkg::update_exact_deps_available "$stage" "$dir"; then
    :
  else
    rc=$?
    if (( rc == 1 )); then
      # A deferred package is not a task failure; continue the selection.
      exit 0
    fi
    echo "error: unable to validate exact dependencies for ${dir##*/}; preserving existing metadata" >&2
    exit 1
  fi

  # Prepare both files alongside their destinations before replacing either.
  build_tmp="$(mktemp "$dir/.PKGBUILD.update.XXXXXX")" || exit 1
  info_tmp="$(mktemp "$dir/.SRCINFO.tmp.XXXXXX")" || exit 1
  cat -- "$stage/PKGBUILD" >"$build_tmp" || exit 1
  cat -- "$stage/.SRCINFO" >"$info_tmp" || exit 1
  chmod --reference="$dir/PKGBUILD" "$build_tmp" || exit 1
  chmod 644 -- "$info_tmp" || exit 1
  mv -f -- "$build_tmp" "$dir/PKGBUILD" || exit 1
  mv -f -- "$info_tmp" "$dir/.SRCINFO" || exit 1
)
