# shellcheck shell=bash

pkg::depspec_parse() {
  local raw="$1"
  local out_name="$2"
  local out_op="$3"
  local out_ver="$4"
  local s="$raw"
  s="${s%%:*}"
  s="${s//$'\r'/}"
  s="${s//[[:space:]]/}"
  local name op ver
  if [[ "$s" =~ ^([^<>=]+)([<>=]{1,2})(.+)$ ]]; then
    name="${BASH_REMATCH[1]}"
    op="${BASH_REMATCH[2]}"
    ver="${BASH_REMATCH[3]}"
  else
    name="$s"
    op=""
    ver=""
  fi
  printf -v "$out_name" '%s' "$name"
  printf -v "$out_op" '%s' "$op"
  printf -v "$out_ver" '%s' "$ver"
}

# shellcheck disable=SC1091
pkg::pkgbuild_list_deps() {
  local pkg_dir="$1"
  local tmp
  tmp="$(mktemp)"
  (
    set +u
    cd "$pkg_dir" || exit 1
    if source ./PKGBUILD >/dev/null 2>&1; then
      for kind in makedepends depends optdepends checkdepends; do
        local -a arr=()
        eval 'arr=("${'"$kind"'[@]-}")'
        local raw
        for raw in "${arr[@]}"; do
          printf '%s\n' "$raw"
        done
      done
      exit 0
    fi
    exit 1
  ) >"$tmp" 2>/dev/null || true
  if [[ -s "$tmp" ]]; then
    awk 'NF' "$tmp" \
      | while IFS= read -r raw; do
          [[ -z "$raw" ]] && continue
          raw="${raw%%:*}"
          raw="${raw//$'\r'/}"
          raw="${raw//[[:space:]]/}"
          [[ -z "$raw" ]] && continue
          printf '%s\n' "$raw"
        done \
      | awk 'NF' | sort -u
    local rc=$?
    rm -f "$tmp"
    return "$rc"
  fi
  echo "warning: failed to source PKGBUILD for deps; falling back to parse: $pkg_dir/PKGBUILD" >&2
  awk '
    BEGIN { in=0 }
    /^[[:space:]]*(depends|makedepends|optdepends|checkdepends)[[:space:]]*\+?=\s*\(/ { in=1; next }
    in && /\)/ { in=0; next }
    in {
      while (match($0, /"[^"]+"|\047[^\047]+\047/)) {
        tok=substr($0, RSTART, RLENGTH)
        gsub(/^"|\\"$/, "", tok)
        gsub(/^\047|\047$/, "", tok)
        print tok
        $0=substr($0, RSTART+RLENGTH)
      }
    }
  ' "$pkg_dir/PKGBUILD" \
    | while IFS= read -r raw; do
        [[ -z "$raw" ]] && continue
        raw="${raw%%:*}"
        raw="${raw//$'\r'/}"
        raw="${raw//[[:space:]]/}"
        [[ -z "$raw" ]] && continue
        printf '%s\n' "$raw"
      done \
    | awk 'NF' | sort -u
  local rc=$?
  rm -f "$tmp"
  return "$rc"
}

pkg::list_local_deps() {
  local pkg_dir="$1"
  local -a deps=()
  if ! mapfile -t deps < <(pkg::pkgbuild_list_deps "$pkg_dir"); then
    echo "warning: failed to extract deps for $pkg_dir" >&2
  fi
  local sep=$'\x1f'
  local dep_spec="" dep="" op="" ver=""
  for dep_spec in "${deps[@]}"; do
    [[ -z "$dep_spec" ]] && continue
    dep=""
    op=""
    ver=""
    pkg::depspec_parse "$dep_spec" dep op ver
    [[ -z "$dep" ]] && continue
    printf '%s%s%s%s%s%s%s\n' \
      "$dep_spec" "$sep" \
      "$dep" "$sep" \
      "$op" "$sep" \
      "$ver"
  done
}

# shellcheck disable=SC1091
pkg::pkgbuild_list_pkgnames() {
  local pkg_dir="$1"
  (
    set +u
    cd "$pkg_dir" || exit 1
    if source ./PKGBUILD >/dev/null 2>&1; then
      local -a names=()
      eval 'names=("${pkgname[@]-}")'
      if [[ "${#names[@]}" -eq 0 && -n "${pkgname-}" ]]; then
        printf '%s\n' "${pkgname}"
      else
        printf '%s\n' "${names[@]}"
      fi
      exit 0
    fi
    exit 1
  ) | awk 'NF'
}
