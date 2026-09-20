# shellcheck shell=bash

declare -Ag PKG_SRCINFO_CACHE=()

pkg::metadata_cache_reset() {
  PKG_SRCINFO_CACHE=()
}

pkg::cache_srcinfo() {
  local pkg_dir="$1"

  [[ -n "${PKG_SRCINFO_CACHE[$pkg_dir]+x}" ]] && return 0

  if [[ -f "$pkg_dir/.SRCINFO" ]]; then
    PKG_SRCINFO_CACHE["$pkg_dir"]="$(<"$pkg_dir/.SRCINFO")"
    return 0
  fi

  PKG_SRCINFO_CACHE["$pkg_dir"]="$(
    cd "$pkg_dir" || exit 1
    makepkg --printsrcinfo
  )"
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
  pkg::metadata_values "$1" pkgbase | head -n1
}

pkg::metadata_outputs() {
  pkg::metadata_values "$1" pkgname | awk 'NF' | sort -u
}

pkg::metadata_provides() {
  local pkg_dir="$1"
  local arch="${CARCH:-$(uname -m)}"

  {
    pkg::metadata_values "$pkg_dir" provides
    pkg::metadata_values "$pkg_dir" "provides_$arch"
  } | awk 'NF' | sort -u
}

pkg::metadata_deps() {
  local pkg_dir="$1"
  local arch="${CARCH:-$(uname -m)}"
  local key

  for key in depends makedepends checkdepends; do
    pkg::metadata_values "$pkg_dir" "$key"
    pkg::metadata_values "$pkg_dir" "${key}_$arch"
  done | awk 'NF' | sort -u
}

pkg::metadata_version() {
  local pkg_dir="$1"
  local epoch pkgver pkgrel

  epoch="$(pkg::metadata_values "$pkg_dir" epoch | head -n1)"
  pkgver="$(pkg::metadata_values "$pkg_dir" pkgver | head -n1)"
  pkgrel="$(pkg::metadata_values "$pkg_dir" pkgrel | head -n1)"

  [[ -n "$pkgver" && -n "$pkgrel" ]] || return 1

  if [[ -n "$epoch" && "$epoch" != "0" ]]; then
    printf '%s:%s-%s\n' "$epoch" "$pkgver" "$pkgrel"
  else
    printf '%s-%s\n' "$pkgver" "$pkgrel"
  fi
}
