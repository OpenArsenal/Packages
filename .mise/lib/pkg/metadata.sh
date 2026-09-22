# shellcheck shell=bash

pkg::srcinfo() {
  local pkg_dir="$1"

  if [[ -f "$pkg_dir/.SRCINFO" ]]; then
    cat "$pkg_dir/.SRCINFO"
    return
  fi

  (
    cd "$pkg_dir" || exit 1
    makepkg --printsrcinfo
  )
}

pkg::metadata_values() {
  local pkg_dir="$1"
  local key="$2"

  pkg::srcinfo "$pkg_dir" | awk -v key="$key" '
    {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      prefix=key " = "
      if (index(line, prefix) == 1) {
        print substr(line, length(prefix) + 1)
      }
    }
  '
}

pkg::metadata_pkgbase() {
  pkg::metadata_values "$1" pkgbase | head -n1
}

pkg::metadata_outputs() {
  pkg::metadata_values "$1" pkgname | awk 'NF' | sort -u
}

pkg::metadata_provides() {
  pkg::metadata_values "$1" provides | awk 'NF' | sort -u
}

pkg::metadata_deps() {
  local pkg_dir="$1"
  local key

  for key in depends makedepends checkdepends; do
    pkg::metadata_values "$pkg_dir" "$key"
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

pkg::spec_parse() {
  local raw="$1"
  local out_name="$2"
  local out_op="$3"
  local out_ver="$4"
  local spec name op ver

  spec="${raw//$'\r'/}"
  spec="${spec//[[:space:]]/}"

  if [[ "$spec" =~ ^([^\<\>\=]+)(\<\=|\>\=|\=|\<|\>)(.+)$ ]]; then
    name="${BASH_REMATCH[1]}"
    op="${BASH_REMATCH[2]}"
    ver="${BASH_REMATCH[3]}"
  else
    name="$spec"
    op=""
    ver=""
  fi

  printf -v "$out_name" '%s' "$name"
  printf -v "$out_op" '%s' "$op"
  printf -v "$out_ver" '%s' "$ver"
}
