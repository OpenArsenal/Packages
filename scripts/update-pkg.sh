#!/usr/bin/bash
set -eu

# update-pkg.sh - Arch Linux package update detection
#
# Compares local PKGBUILD versions against upstream to identify updates.
# Does NOT build packages - only detects version differences.
#
# Usage: ./update-pkg.sh [OPTIONS] [PACKAGES...]
#   --apply           Update PKGBUILDs with new versions and checksums
#   --list-outdated   Output package names only (one per line)
#   --json            Machine-readable JSON output
#
# Requirements:
#   - bash 4.0+ (standard on Arch Linux)
#   - Arch tools: makepkg, updpkgsums
#   - Dependencies: jq, curl, python3, xmllint
#
# Environment (from .envrc):
#   PKGBUILDS_ROOT    Package build directory
#   FEEDS_JSON        Path to feeds configuration
#   BUILD_ROOT        Build scratch space
#   GITHUB_TOKEN      Optional, reduces API rate limiting
#   DEBUG             Set to 1 for diagnostic output
#
# Exit codes: 0=success, 1=error, 2=invalid usage
#
# Note: This script targets Arch Linux specifically and does not aim
#       for POSIX sh portability.

# Constants - naming convention instead of readonly
PACKAGE_UPDATE_BOT_USER_AGENT="Package-Update-Bot/1.0"
FETCH_TIMEOUT=30

err() { printf '%s: %s\n' "${0##*/}" "$*" >&2; }
die() { err "$*"; exit 1; }
debug() { [ "${DEBUG:-}" = "1" ] && err "DEBUG: $*" || true; }

validate_env() {
  local missing=""
  [ -z "${PKGBUILDS_ROOT:-}" ] && missing="${missing}PKGBUILDS_ROOT "
  [ -z "${BUILD_ROOT:-}" ] && missing="${missing}BUILD_ROOT "
  [ -z "${FEEDS_JSON:-}" ] && missing="${missing}FEEDS_JSON "
  
  if [ -n "$missing" ]; then
    die "Missing environment: $missing
Run 'direnv allow' or manually source .envrc"
  fi
  
  [ ! -d "${PKGBUILDS_ROOT}" ] && die "PKGBUILDS_ROOT not found: ${PKGBUILDS_ROOT}"
  [ ! -f "${FEEDS_JSON}" ] && die "FEEDS_JSON not found: ${FEEDS_JSON}"
}

validate_env

PROJECT_ROOT="${PKGBUILDS_ROOT}"
DEFAULT_FEEDS_JSON="${FEEDS_JSON}"

# =============================================================================
# Network fetching with optional GitHub authentication
# =============================================================================

fetch() {
  local url="${1:-}"
  [ -z "$url" ] && return 1
  
  debug "fetch: $url"
  
  if [ -n "${GITHUB_TOKEN:-}" ] && [[ "$url" =~ ^https://api\.github\.com/ ]]; then
    curl -sSL --max-time "$FETCH_TIMEOUT" \
      -A "$PACKAGE_UPDATE_BOT_USER_AGENT" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url" 2>/dev/null
    return $?
  fi

  curl -sSL --max-time "$FETCH_TIMEOUT" \
    -A "$PACKAGE_UPDATE_BOT_USER_AGENT" \
    "$url" 2>/dev/null
}

# =============================================================================
# feeds.json queries - supports schema v1 and v2
# =============================================================================

feeds_json_get_schema_version() {
  local feeds_json="${1:-}"
  [ -z "$feeds_json" ] && echo "1" && return 0
  jq -r '.schemaVersion // 1' "$feeds_json"
}

feeds_json_list_packages() {
  local feeds_json="${1:-}"
  [ -z "$feeds_json" ] && return 0
  jq -r '.packages[]?.name // empty' "$feeds_json" | sed '/^$/d'
}

feeds_json_get_field() {
  local feeds_json="${1:-}"
  local pkg="${2:-}"
  local field="${3:-}"
  [ -z "$feeds_json" ] || [ -z "$pkg" ] || [ -z "$field" ] && return 0
  
  local schema_version
  schema_version="$(feeds_json_get_schema_version "$feeds_json")"
  
  if [ "$schema_version" = "1" ]; then
    jq -r --arg name "$pkg" --arg field "$field" \
      '(.packages[] | select(.name==$name) | .feed[$field]) // empty' "$feeds_json"
  else
    jq -r --arg name "$pkg" --arg field "$field" \
      '(.packages[] | select(.name==$name) | .[$field]) // empty' "$feeds_json"
  fi
}

feeds_json_has_pkg() {
  local feeds_json="${1:-}"
  local pkg="${2:-}"
  [ -z "$feeds_json" ] || [ -z "$pkg" ] && return 1
  jq -e --arg name "$pkg" '.packages[] | select(.name==$name) | .name' "$feeds_json" >/dev/null 2>&1
}

# =============================================================================
# Version extraction - handles prefixes like 'v', 'release-'
# =============================================================================

trim() {
  local str="${1:-}"
  str="${str#"${str%%[![:space:]]*}"}"
  str="${str%"${str##*[![:space:]]}"}"
  echo "$str"
}

extract_version() {
  local raw="${1:-}"
  local version_regex="${2:-.+}"
  local version_format="${3:-}"
  
  [ -z "$raw" ] && return 0
  
  if [ -z "$version_format" ]; then
    trim "$raw"
    return 0
  fi
  
  python3 - "$raw" "$version_regex" "$version_format" <<'PYTHON_EOF'
import sys, re
raw = sys.argv[1]
regex = sys.argv[2]
fmt = sys.argv[3]

match = re.search(regex, raw)
if match:
    groups = match.groups()
    if groups:
        result = fmt
        for i, g in enumerate(groups, 1):
            result = result.replace(f'${i}', g or '')
        print(result.strip())
    else:
        print(match.group(0).strip())
else:
    print(raw.strip())
PYTHON_EOF
}

# =============================================================================
# Version comparison - uses vercmp if available, else sort -V
# =============================================================================

pick_max_version_list() {
  local versions=""
  local line=""
  
  while IFS= read -r line; do
    [ -n "$line" ] && versions="${versions}${versions:+
}${line}"
  done

  [ -z "$versions" ] && return 0

  if command -v vercmp >/dev/null 2>&1; then
    local max
    max="$(echo "$versions" | head -n 1)"
    
    echo "$versions" | while IFS= read -r v; do
      [ -n "$v" ] && [ "$(vercmp "$v" "$max" 2>/dev/null || echo 0)" -gt 0 ] && max="$v"
    done | tail -n 1
    [ -n "$max" ] && echo "$max"
  else
    printf "%s\n" "$versions" | sort -V | tail -n 1
  fi
}

# =============================================================================
# GitHub API queries
# =============================================================================

github_latest_release_tag() {
  local repo="${1:-}"
  local channel="${2:-stable}"
  
  [ -z "$repo" ] && return 0
  
  debug "github_latest_release_tag: repo=$repo, channel=$channel"
  
  local url="https://api.github.com/repos/${repo}/releases"
  local releases
  releases="$(fetch "$url")" || return 1
  
  local tag
  case "$channel" in
    beta)
      tag="$(echo "$releases" | jq -r 'map(select(.prerelease==true)) | .[0].tag_name // empty')"
      ;;
    latest|*)
      tag="$(echo "$releases" | jq -r '.[0].tag_name // empty')"
      ;;
  esac
  
  [ -n "$tag" ] && echo "$tag"
}

github_tags_filter() {
  local repo="${1:-}"
  local tag_filter="${2:-}"
  local version_regex="${3:-.+}"
  local version_format="${4:-}"
  
  [ -z "$repo" ] || [ -z "$tag_filter" ] && return 0
  
  local url="https://api.github.com/repos/${repo}/tags"
  local tags
  tags="$(fetch "$url")" || return 1
  
  echo "$tags" | \
    jq -r --arg filter "$tag_filter" '.[] | .name | select(test($filter))' | \
    while IFS= read -r tag; do
      [ -n "$tag" ] && extract_version "$tag" "$version_regex" "$version_format"
    done | pick_max_version_list
}

# =============================================================================
# Browser version detection
# =============================================================================

chrome_stable_linux() {
  local url="https://versionhistory.googleapis.com/v1/chrome/platforms/linux/channels/stable/versions"
  local json
  json="$(fetch "$url")" || return 1
  echo "$json" | jq -r '.versions[0].version // empty'
}

edge_stable_linux() {
  local url="https://edgeupdates.microsoft.com/api/products"
  local json
  json="$(fetch "$url")" || return 1
  
  echo "$json" | jq -r '
    .[] |
    select(.Product=="Stable") |
    .Releases[] |
    select(.Platform=="Linux" and .Architecture=="x64") |
    .ProductVersion' | head -n 1
}

vscode_stable() {
  local url="https://update.code.visualstudio.com/api/releases/stable"
  fetch "$url" | head -n 1 | tr -d '"'
}

# =============================================================================
# Custom API endpoints
# =============================================================================

onepassword_cli2() {
  local url="https://app-updates.agilebits.com/check/1/0/CLI2/en/2.0.0/N"
  local xml
  xml="$(fetch "$url")" || return 1
  echo "$xml" | xmllint --xpath 'string(//enclosure/@sparkle:version)' - 2>/dev/null
}

onepassword_linux_stable() {
  local url="https://downloads.1password.com/linux/tar/stable/x86_64/version.json"
  local json
  json="$(fetch "$url")" || return 1
  echo "$json" | jq -r '.version // empty'
}

lmstudio_latest() {
  local url="https://s3.amazonaws.com/releases.lmstudio.ai/linux/x86/latest.json"
  local json
  json="$(fetch "$url")" || return 1
  echo "$json" | jq -r '.version // empty'
}

# =============================================================================
# Source router - dispatch to appropriate detection function
# =============================================================================

detect_remote_version() {
  local pkg="${1:-}"
  [ -z "$pkg" ] && return 0
  
  local feeds_json="${DEFAULT_FEEDS_JSON}"
  local source_type
  source_type="$(feeds_json_get_field "$feeds_json" "$pkg" "sourceType")"
  
  [ -z "$source_type" ] || [ "$source_type" = "null" ] && return 0
  
  case "$source_type" in
    github-release)
      local repo channel
      repo="$(feeds_json_get_field "$feeds_json" "$pkg" "repo")"
      channel="$(feeds_json_get_field "$feeds_json" "$pkg" "channel")"
      github_latest_release_tag "$repo" "${channel:-stable}"
      ;;
      
    github-release-filtered|github-tags-filtered)
      local repo tag_filter version_regex version_format
      repo="$(feeds_json_get_field "$feeds_json" "$pkg" "repo")"
      tag_filter="$(feeds_json_get_field "$feeds_json" "$pkg" "tagFilter")"
      version_regex="$(feeds_json_get_field "$feeds_json" "$pkg" "versionRegex")"
      version_format="$(feeds_json_get_field "$feeds_json" "$pkg" "versionFormat")"
      github_tags_filter "$repo" "$tag_filter" "${version_regex:-.+}" "$version_format"
      ;;
      
    chrome)
      chrome_stable_linux
      ;;
      
    edge)
      edge_stable_linux
      ;;
      
    vscode)
      vscode_stable
      ;;
      
    1password-cli2)
      onepassword_cli2
      ;;
      
    1password-linux-stable)
      onepassword_linux_stable
      ;;
      
    lmstudio)
      lmstudio_latest
      ;;
      
    vcs|manual)
      return 0
      ;;
      
    *)
      debug "Unknown sourceType for $pkg: $source_type"
      return 0
      ;;
  esac
}

# =============================================================================
# Local PKGBUILD version extraction
# =============================================================================

get_local_pkgbuild_version() {
  local pkg="${1:-}"
  [ -z "$pkg" ] && return 0
  
  local pkgbuild_path="${PROJECT_ROOT}/${pkg}/PKGBUILD"
  [ ! -f "$pkgbuild_path" ] && return 0
  
  (
    # shellcheck disable=SC1090
    source "$pkgbuild_path" 2>/dev/null && echo "${pkgver:-}"
  )
}

# =============================================================================
# PKGBUILD update operations
# =============================================================================

update_pkgbuild_version() {
  local pkgbuild_path="${1:-}"
  local new_version="${2:-}"
  
  [ -z "$pkgbuild_path" ] || [ -z "$new_version" ] && return 1
  [ ! -f "$pkgbuild_path" ] && return 1
  
  local clean_version
  clean_version="$(trim "$new_version")"
  clean_version="$(printf '%s' "$clean_version" | tr '-' '_')"
  
  sed -i.bak "s/^pkgver=.*/pkgver=${clean_version}/" "$pkgbuild_path"
  sed -i "s/^pkgrel=.*/pkgrel=1/" "$pkgbuild_path"
  
  rm -f "${pkgbuild_path}.bak"
}

update_pkgbuild_checksums() {
  local pkg_dir="${1:-}"
  [ -z "$pkg_dir" ] || [ ! -d "$pkg_dir" ] && return 1
  
  (
    cd "$pkg_dir" || return 1
    updpkgsums 2>&1 | grep -v "^==> " || true
  )
}

# =============================================================================
# Package comparison and reporting
# =============================================================================

check_package_update() {
  local pkg="${1:-}"
  [ -z "$pkg" ] && return 0
  
  local feeds_json="${DEFAULT_FEEDS_JSON}"
  
  if ! feeds_json_has_pkg "$feeds_json" "$pkg"; then
    debug "$pkg: not in feeds.json"
    return 0
  fi
  
  local source_type
  source_type="$(feeds_json_get_field "$feeds_json" "$pkg" "sourceType")"
  
  if [ "$source_type" = "vcs" ] || [ "$source_type" = "manual" ]; then
    debug "$pkg: skipped (sourceType=$source_type)"
    return 0
  fi
  
  local local_ver remote_ver
  local_ver="$(get_local_pkgbuild_version "$pkg")"
  remote_ver="$(detect_remote_version "$pkg")"
  
  [ -z "$local_ver" ] && debug "$pkg: no local version" && return 0
  [ -z "$remote_ver" ] && debug "$pkg: no remote version" && return 0
  
  if command -v vercmp >/dev/null 2>&1; then
    local cmp
    cmp="$(vercmp "$remote_ver" "$local_ver" 2>/dev/null || echo 0)"
    
    if [ "$cmp" -gt 0 ]; then
      echo "$pkg|$local_ver|$remote_ver|outdated"
    elif [ "$cmp" -lt 0 ]; then
      echo "$pkg|$local_ver|$remote_ver|ahead"
    else
      echo "$pkg|$local_ver|$remote_ver|current"
    fi
  else
    if [ "$local_ver" = "$remote_ver" ]; then
      echo "$pkg|$local_ver|$remote_ver|current"
    else
      echo "$pkg|$local_ver|$remote_ver|outdated"
    fi
  fi
}

apply_update() {
  local pkg="${1:-}"
  local new_version="${2:-}"
  
  [ -z "$pkg" ] || [ -z "$new_version" ] && return 1
  
  local pkg_dir="${PROJECT_ROOT}/${pkg}"
  local pkgbuild_path="${pkg_dir}/PKGBUILD"
  
  [ ! -f "$pkgbuild_path" ] && err "$pkg: PKGBUILD not found" && return 1
  
  update_pkgbuild_version "$pkgbuild_path" "$new_version" || {
    err "$pkg: failed to update version"
    return 1
  }
  
  update_pkgbuild_checksums "$pkg_dir" || {
    err "$pkg: failed to update checksums"
    return 1
  }
  
  printf "Updated %s: %s\n" "$pkg" "$new_version"
}

# =============================================================================
# Output formatters
# =============================================================================

format_table_output() {
  local tmpfile
  tmpfile="$(mktemp)"
  trap 'rm -f "$tmpfile"' RETURN
  
  cat > "$tmpfile"
  
  local has_outdated=0
  while IFS='|' read -r pkg local_ver remote_ver status; do
    [ "$status" = "outdated" ] && has_outdated=1
    printf "%-25s %-15s %-15s %s\n" "$pkg" "$local_ver" "$remote_ver" "$status"
  done < "$tmpfile"
  
  return $has_outdated
}

format_json_output() {
  local tmpfile
  tmpfile="$(mktemp)"
  trap 'rm -f "$tmpfile"' RETURN
  
  cat > "$tmpfile"
  
  printf '{"packages":['
  
  local first=1
  while IFS='|' read -r pkg local_ver remote_ver status; do
    [ $first -eq 0 ] && printf ','
    printf '\n  {"name":"%s","local":"%s","remote":"%s","status":"%s"}' \
      "$pkg" "$local_ver" "$remote_ver" "$status"
    first=0
  done < "$tmpfile"
  
  printf '\n]}\n'
}

format_list_outdated() {
  while IFS='|' read -r pkg _ _ status; do
    [ "$status" = "outdated" ] && echo "$pkg"
  done
}

# =============================================================================
# Main execution
# =============================================================================

usage() {
  cat <<'EOF'
Usage: update-pkg.sh [OPTIONS] [PACKAGES...]

Check for package updates by comparing local PKGBUILD versions with upstream.

Options:
  --apply           Update PKGBUILDs with new versions and checksums
  --list-outdated   Output only outdated package names (one per line)
  --json            Output results as JSON
  --help            Show this help

Environment:
  DEBUG=1           Enable diagnostic output to stderr
  GITHUB_TOKEN      Reduce GitHub API rate limiting

Examples:
  ./update-pkg.sh                           # Check all packages
  ./update-pkg.sh ktailctl google-chrome    # Check specific packages
  ./update-pkg.sh --list-outdated           # List outdated packages
  ./update-pkg.sh --apply ktailctl          # Update specific package

Exit codes:
  0  Success (may have outdated packages)
  1  Error occurred
  2  Invalid usage
EOF
  exit "${1:-0}"
}

main() {
  local mode="check"
  local output="table"
  local packages=()
  
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply)
        mode="apply"
        shift
        ;;
      --list-outdated)
        output="list"
        shift
        ;;
      --json)
        output="json"
        shift
        ;;
      --help|-h)
        usage 0
        ;;
      -*)
        err "Unknown option: $1"
        usage 2
        ;;
      *)
        packages+=("$1")
        shift
        ;;
    esac
  done
  
  if [ ${#packages[@]} -eq 0 ]; then
    mapfile -t packages < <(feeds_json_list_packages "$DEFAULT_FEEDS_JSON")
  fi
  
  [ ${#packages[@]} -eq 0 ] && die "No packages found"
  
  local results_file
  results_file="$(mktemp)"
  trap 'rm -f "$results_file"' EXIT
  
  for pkg in "${packages[@]}"; do
    if [ "$mode" = "apply" ]; then
      local result
      result="$(check_package_update "$pkg")"
      
      if [ -n "$result" ]; then
        local status remote_ver
        status="$(echo "$result" | cut -d'|' -f4)"
        remote_ver="$(echo "$result" | cut -d'|' -f3)"
        
        if [ "$status" = "outdated" ]; then
          apply_update "$pkg" "$remote_ver"
        fi
      fi
    else
      check_package_update "$pkg"
    fi
  done > "$results_file"
  
  if [ "$mode" = "check" ]; then
    case "$output" in
      list)
        format_list_outdated < "$results_file"
        ;;
      json)
        format_json_output < "$results_file"
        ;;
      table)
        format_table_output < "$results_file"
        ;;
    esac
  fi
}

main "$@"