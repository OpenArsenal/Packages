# shellcheck shell=bash

declare -Ag PKG_SRCINFO_CACHE=()

pkg::metadata_cache_reset() {
  PKG_SRCINFO_CACHE=()
}

pkg::cache_srcinfo() {
  local pkg_dir="$1"
  local srcinfo

  [[ -n "${PKG_SRCINFO_CACHE[$pkg_dir]+x}" ]] && return 0

  if [[ -f "$pkg_dir/.SRCINFO" ]]; then
    srcinfo="$(<"$pkg_dir/.SRCINFO")" || return 1
  else
    # A failed makepkg can emit partial output. Cache only after success,
    # otherwise a later read could treat the incomplete data as valid.
    srcinfo="$(
      cd "$pkg_dir" || exit 1
      makepkg --printsrcinfo
    )" || return 1
  fi

  PKG_SRCINFO_CACHE["$pkg_dir"]="$srcinfo"
}

pkg::srcinfo() {
  local pkg_dir="$1"

  pkg::cache_srcinfo "$pkg_dir" || return
  printf '%s\n' "${PKG_SRCINFO_CACHE[$pkg_dir]}"
}

pkg::metadata_values() {
  local pkg_dir="$1"
  local key="$2"

  pkg::cache_srcinfo "$pkg_dir" || return

  awk -v key="$key" '
    {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      prefix=key " = "
      if (index(line, prefix) == 1) {
        print substr(line, length(prefix) + 1)
      }
    }
  ' <<<"${PKG_SRCINFO_CACHE[$pkg_dir]}"
}

pkg::metadata_pkgbase() {
  local values
  values="$(pkg::metadata_values "$1" pkgbase)" || return 1
  printf '%s\n' "${values%%$'\n'*}"
}

pkg::metadata_outputs() {
  local values
  values="$(pkg::metadata_values "$1" pkgname)" || return 1
  printf '%s\n' "$values" | awk 'NF' | sort -u
}

pkg::metadata_provides() {
  local pkg_dir="$1"
  local arch="${CARCH:-$(uname -m)}"
  local generic arch_specific

  generic="$(pkg::metadata_values "$pkg_dir" provides)" || return 1
  arch_specific="$(pkg::metadata_values "$pkg_dir" "provides_$arch")" || return 1
  printf '%s\n%s\n' "$generic" "$arch_specific" | awk 'NF' | sort -u
}

pkg::metadata_deps() {
  local pkg_dir="$1"
  local arch="${CARCH:-$(uname -m)}"
  local key values collected=""

  # Check every field read. A failed early read must not be concealed by
  # successful reads of later dependency categories.
  for key in depends makedepends checkdepends; do
    values="$(pkg::metadata_values "$pkg_dir" "$key")" || return 1
    collected+="$values"$'\n'
    values="$(pkg::metadata_values "$pkg_dir" "${key}_$arch")" || return 1
    collected+="$values"$'\n'
  done
  printf '%s' "$collected" | awk 'NF' | sort -u
}

pkg::metadata_version() {
  local pkg_dir="$1"
  local epoch pkgver pkgrel

  epoch="$(pkg::metadata_values "$pkg_dir" epoch)" || return 1
  pkgver="$(pkg::metadata_values "$pkg_dir" pkgver)" || return 1
  pkgrel="$(pkg::metadata_values "$pkg_dir" pkgrel)" || return 1
  epoch="${epoch%%$'\n'*}"
  pkgver="${pkgver%%$'\n'*}"
  pkgrel="${pkgrel%%$'\n'*}"

  [[ -n "$pkgver" && -n "$pkgrel" ]] || return 1

  if [[ -n "$epoch" && "$epoch" != "0" ]]; then
    printf '%s:%s-%s\n' "$epoch" "$pkgver" "$pkgrel"
  else
    printf '%s-%s\n' "$pkgver" "$pkgrel"
  fi
}
