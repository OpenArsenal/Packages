# shellcheck shell=bash

spec::parse() {
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
