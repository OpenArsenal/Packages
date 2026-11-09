# shellcheck shell=bash

spec::parse() {
  local raw="$1"
  local out_name="$2"
  local out_op="$3"
  local out_ver="$4"
  local spec parsed_name parsed_op parsed_ver

  spec="${raw//$'\r'/}"
  spec="${spec//[[:space:]]/}"

  if [[ "$spec" =~ ^([^\<\>\=]+)(\<\=|\>\=|\=|\<|\>)(.+)$ ]]; then
    parsed_name="${BASH_REMATCH[1]}"
    parsed_op="${BASH_REMATCH[2]}"
    parsed_ver="${BASH_REMATCH[3]}"
  else
    parsed_name="$spec"
    parsed_op=""
    parsed_ver=""
  fi

  printf -v "$out_name" '%s' "$parsed_name"
  printf -v "$out_op" '%s' "$parsed_op"
  printf -v "$out_ver" '%s' "$parsed_ver"
}
