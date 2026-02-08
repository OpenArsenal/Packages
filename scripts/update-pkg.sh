#!/usr/bin/env bash
set -uo pipefail

# update-pkg.sh - Version detection ONLY (no building)
#
# Detects which packages need updates by comparing local PKGBUILDs with remote sources.
# Does NOT build packages.
#
# Supports feeds.json schema v1 and v2 with multiple source types:
#   - chrome, edge, vscode (browser/editor binaries)
#   - github-release, github-release-filtered, github-tags-filtered
#   - 1password-cli2, 1password-linux-stable, lmstudio
#   - vcs (VCS packages like -git, -hg, -svn)
#   - manual (no auto-detection)
#
# Examples:
#   ./scripts/update-pkg.sh --dry-run              # Check all packages
#   ./scripts/update-pkg.sh --list-outdated        # List packages needing updates
#   ./scripts/update-pkg.sh ktailctl               # Check specific package
#   ./scripts/update-pkg.sh --json                 # JSON output for scripting
#
# Optional:
#   export GITHUB_TOKEN="..."  # Reduces GitHub API rate limiting

declare -r RED='\033[0;31m'
declare -r GREEN='\033[0;32m'
declare -r YELLOW='\033[1;33m'
declare -r BLUE='\033[0;34m'
declare -r NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*" >&2; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_debug() { [[ "${DEBUG:-false}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} $*" >&2; }

# ============================================================================
# Configuration
# ============================================================================

declare -r PACKAGE_UPDATE_BOT_USER_AGENT="Package-Update-Bot/1.0"
declare -r FETCH_TIMEOUT=30

# ============================================================================
# Network Helpers
# ============================================================================

fetch() {
  local url="${1:-}"
  [[ -z "$url" ]] && return 1
  
  # Use GitHub token if available for API requests
  if [[ -n "${GITHUB_TOKEN:-}" && "$url" == https://api.github.com/* ]]; then
    curl -sSL --max-time "$FETCH_TIMEOUT" \
      -A "$PACKAGE_UPDATE_BOT_USER_AGENT" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url" 2>/dev/null
    return $?
  fi

  curl -sSL --max-time "$FETCH_TIMEOUT" -A "$PACKAGE_UPDATE_BOT_USER_AGENT" "$url" 2>/dev/null
}

# ============================================================================
# feeds.json Helpers (Schema-Aware)
# ============================================================================

feeds_json_get_schema_version() {
  local feeds_json="${1:-}"
  [[ -z "$feeds_json" ]] && echo "1" && return 0
  jq -r '.schemaVersion // 1' "$feeds_json"
}

feeds_json_list_packages() {
  local feeds_json="${1:-}"
  [[ -z "$feeds_json" ]] && return 0
  jq -r '.packages[]?.name // empty' "$feeds_json" | sed '/^$/d'
}

feeds_json_get_field() {
  local feeds_json="${1:-}"
  local pkg="${2:-}"
  local field="${3:-}"
  [[ -z "$feeds_json" || -z "$pkg" || -z "$field" ]] && return 0
  
  local schema_version
  schema_version="$(feeds_json_get_schema_version "$feeds_json")"
  
  if [[ "$schema_version" == "1" ]]; then
    # Schema v1: fields nested under .feed
    jq -r --arg name "$pkg" --arg field "$field" '
      (.packages[] | select(.name==$name) | .feed[$field]) // empty
    ' "$feeds_json"
  else
    # Schema v2: fields directly on package object
    jq -r --arg name "$pkg" --arg field "$field" '
      (.packages[] | select(.name==$name) | .[$field]) // empty
    ' "$feeds_json"
  fi
}

feeds_json_has_pkg() {
  local feeds_json="${1:-}"
  local pkg="${2:-}"
  [[ -z "$feeds_json" || -z "$pkg" ]] && return 1
  jq -e --arg name "$pkg" '.packages[] | select(.name==$name) | .name' "$feeds_json" >/dev/null 2>&1
}

# ============================================================================
# Version Normalization / Extraction
# ============================================================================

trim() {
  local s="${1:-}"
  echo "$s" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

normalize_basic_tag_to_version() {
  # Accept either single arg or stdin (for pipe usage)
  local raw=""

  if [[ $# -gt 0 ]]; then
    raw="${1:-}"
  else
    raw="$(cat || true)"
  fi

  # Normalize whitespace/newlines, strip common prefixes
  raw="${raw//$'\r'/}"
  raw="${raw//$'\n'/}"
  raw="${raw#refs/tags/}"
  raw="${raw#v}"
  raw="${raw#V}"

  printf '%s\n' "$raw"
}

apply_version_regex() {
  local raw="${1:-}"
  local version_regex="${2:-}"
  local version_format="${3:-}"
  [[ -z "$raw" || -z "$version_regex" || -z "$version_format" ]] && return 2

  python3 - "$raw" "$version_regex" "$version_format" <<'PY'
import re
import sys

raw = sys.argv[1]
rx = sys.argv[2]
fmt = sys.argv[3]

m = re.match(rx, raw)
if not m:
  sys.exit(2)

out = fmt
for i in range(1, 10):
  token = f"${i}"
  if token in out:
    val = m.group(i) if i <= m.lastindex else ""
    out = out.replace(token, val or "")
print(out)
PY
}

pick_max_version_list() {
  local -a versions=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && versions+=("$line")
  done

  if [[ ${#versions[@]} -eq 0 ]]; then
    echo ""
    return 0
  fi

  # Use vercmp if available for accurate version comparison
  if command -v vercmp >/dev/null 2>&1; then
    local max="${versions[0]}"
    local v
    for v in "${versions[@]:1}"; do
      if [[ "$(vercmp "$v" "$max")" -gt 0 ]]; then
        max="$v"
      fi
    done
    echo "$max"
    return 0
  fi

  # Fallback to sort -V
  printf "%s\n" "${versions[@]}" | sort -V | tail -n 1
}

# ============================================================================
# Upstream Version Fetchers
# ============================================================================

github_latest_release_tag() {
  local repo="${1:-}"
  local channel="${2:-stable}"
  [[ -z "$repo" ]] && return 0

  log_debug "github_latest_release_tag: repo=$repo, channel=$channel"

  local url=""
  case "$channel" in
    stable)
      url="https://api.github.com/repos/${repo}/releases/latest"
      ;;
    prerelease|any|*)
      url="https://api.github.com/repos/${repo}/releases?per_page=30"
      ;;
  esac

  local response
  response="$(fetch "$url")" || {
    log_debug "Failed to fetch from GitHub API: $url"
    return 1
  }
  
  local result
  case "$channel" in
    stable)
      result=$(echo "$response" | jq -r '.tag_name // empty')
      ;;
    prerelease)
      result=$(echo "$response" | jq -r '[.[] | select(.prerelease==true)][0].tag_name // empty')
      ;;
    any|*)
      result=$(echo "$response" | jq -r '.[0].tag_name // empty')
      ;;
  esac

  if [[ -z "$result" && "${DEBUG:-false}" == "true" ]]; then
    log_debug "No tag_name found in API response"
    log_debug "Response snippet: $(echo "$response" | jq -c . | head -c 200)..."
  fi

  echo "$result"
}

github_latest_release_tag_filtered() {
  local repo="${1:-}"
  local channel="${2:-stable}"
  local tag_regex="${3:-}"
  [[ -z "$repo" || -z "$tag_regex" ]] && return 1

  log_debug "github_latest_release_tag_filtered: repo=$repo, channel=$channel, tag_regex=$tag_regex"

  local releases
  releases="$(fetch "https://api.github.com/repos/${repo}/releases?per_page=50")" || {
    log_debug "Failed to fetch releases from GitHub API"
    return 1
  }

  local total_releases
  total_releases=$(echo "$releases" | jq -r '.[] | .tag_name' | wc -l)
  log_debug "Found $total_releases total releases"

  local result
  case "$channel" in
    stable)
      result=$(echo "$releases" | jq -r --arg re "$tag_regex" '
        [.[] | select(.prerelease==false) | select(.tag_name | test($re))][0].tag_name // empty
      ')
      ;;
    prerelease)
      result=$(echo "$releases" | jq -r --arg re "$tag_regex" '
        [.[] | select(.prerelease==true) | select(.tag_name | test($re))][0].tag_name // empty
      ')
      ;;
    any|*)
      result=$(echo "$releases" | jq -r --arg re "$tag_regex" '
        [.[] | select(.tag_name | test($re))][0].tag_name // empty
      ')
      ;;
  esac

  if [[ -z "$result" && "${DEBUG:-false}" == "true" ]]; then
    log_debug "No releases matched regex '$tag_regex'"
    log_debug "Sample releases (first 5):"
    echo "$releases" | jq -r '.[] | .tag_name' | head -5 | while read -r tag; do
      log_debug "  - $tag (prerelease: $(echo "$releases" | jq -r --arg t "$tag" '.[] | select(.tag_name==$t) | .prerelease'))"
    done
  fi

  echo "$result"
}

github_tags_filtered_versions() {
  local repo="${1:-}"
  local tag_regex="${2:-}"
  local version_regex="${3:-}"
  local version_format="${4:-}"
  [[ -z "$repo" ]] && return 0

  log_debug "github_tags_filtered_versions: repo=$repo, tag_regex=$tag_regex"

  local tags_json
  tags_json="$(fetch "https://api.github.com/repos/${repo}/tags?per_page=100")" || {
    log_debug "Failed to fetch tags from GitHub API"
    return 1
  }

  local tag_count
  tag_count=$(echo "$tags_json" | jq -r '.[] | .name' | wc -l)
  log_debug "Found $tag_count total tags"

  local matching_tags
  matching_tags=$(echo "$tags_json" | jq -r --arg re "$tag_regex" '
    .[] | .name | select(test($re))
  ')
  
  local matching_count
  matching_count=$(echo "$matching_tags" | grep -c . || echo "0")
  log_debug "Found $matching_count tags matching regex '$tag_regex'"

  if [[ "$matching_count" -eq 0 && "${DEBUG:-false}" == "true" ]]; then
    log_debug "Sample tags from repo (first 5):"
    echo "$tags_json" | jq -r '.[] | .name' | head -5 | while read -r tag; do
      log_debug "  - $tag"
    done
  fi

  echo "$matching_tags" | while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    local raw
    raw="$(normalize_basic_tag_to_version "$tag")"

    if [[ -n "$version_regex" && -n "$version_format" ]]; then
      apply_version_regex "$raw" "$version_regex" "$version_format" 2>/dev/null || true
    else
      echo "$raw"
    fi
  done
}

get_chrome_version_json() {
  local channel="${1:-stable}"
  local encoded_filter="endtime%3Dnone%2Cfraction%3E%3D0.5"
  local encoded_order="version%20desc"
  local url="https://versionhistory.googleapis.com/v1/chrome/platforms/linux/channels/${channel}/versions/all/releases?filter=${encoded_filter}&order_by=${encoded_order}"

  local response
  response="$(fetch "$url")" || return 1
  echo "$response" | jq -r '.releases[0].version // empty'
}

get_edge_version() {
  local repomd_url="${1:-}"
  [[ -z "$repomd_url" ]] && return 1
  
  local base="${repomd_url%/repodata/repomd.xml}"

  local primary_href
  primary_href="$(fetch "$repomd_url" \
    | xmllint --xpath 'string(//*[local-name()="data" and @type="primary"]/*[local-name()="location"]/@href)' - 2>/dev/null)"

  [[ -z "$primary_href" ]] && return 1

  fetch "${base}/${primary_href}" \
    | gunzip 2>/dev/null \
    | xmllint --xpath "string((//*[local-name()='entry'][@name='microsoft-edge-stable']/@ver)[last()])" - 2>/dev/null
}

get_vscode_version() {
  normalize_basic_tag_to_version "$(github_latest_release_tag "microsoft/vscode" "stable")"
}

get_1password_cli2_version_json() {
  local url="${1:-}"
  [[ -z "$url" ]] && return 1
  
  local response
  response="$(fetch "$url")" || return 1
  echo "$response" | jq -r '.version // empty'
}

get_1password_linux_stable_version() {
  local url="${1:-}"
  [[ -z "$url" ]] && return 1
  
  local html
  html="$(fetch "$url")" || return 1

  echo "$html" \
    | tr '\n' ' ' \
    | sed -n -E 's/.*Updated to ([0-9]+(\.[0-9]+)+([\-][0-9]+)?).*/\1/p' \
    | head -1
}

get_lmstudio_version() {
  log_debug "get_lmstudio_version: Fetching from lmstudio.ai/download"
  
  local html
  html="$(curl -sSL --max-time 5 "https://lmstudio.ai/download" 2>/dev/null)" || {
    log_debug "Failed to fetch lmstudio.ai/download"
    return 1
  }

  log_debug "HTML fetched, length: ${#html} bytes"

  local result
  result=$(printf '%s' "$html" | python3 - <<'PY' 2>/dev/null || true
import re, sys
html = sys.stdin.read()
m = re.search(r'\\"linux\\":\{\\"x64\\":\{\\"version\\":\\"([0-9.]+)\\",\\"build\\":\\"([0-9]+)\\"', html)
if not m:
  sys.exit(2)
print(f"{m.group(1)}.{m.group(2)}")
PY
)

  if [[ -z "$result" && "${DEBUG:-false}" == "true" ]]; then
    log_debug "Regex did not match. HTML snippet (first 500 chars):"
    printf '%s' "$html" | head -c 500 | sed 's/^/  /' >&2
    echo "" >&2
  fi

  echo "$result"
}

# ============================================================================
# Main Version Detection Dispatcher
# ============================================================================

fetch_upstream_version_for_pkg() {
  local feeds_json="${1:-}"
  local pkg="${2:-}"
  [[ -z "$feeds_json" || -z "$pkg" ]] && return 0

  local type repo channel url tag_regex version_regex version_format

  type="$(feeds_json_get_field "$feeds_json" "$pkg" "type")"
  repo="$(feeds_json_get_field "$feeds_json" "$pkg" "repo")"
  channel="$(feeds_json_get_field "$feeds_json" "$pkg" "channel")"
  url="$(feeds_json_get_field "$feeds_json" "$pkg" "url")"
  tag_regex="$(feeds_json_get_field "$feeds_json" "$pkg" "tagRegex")"
  version_regex="$(feeds_json_get_field "$feeds_json" "$pkg" "versionRegex")"
  version_format="$(feeds_json_get_field "$feeds_json" "$pkg" "versionFormat")"

  [[ -z "$channel" ]] && channel="stable"

  log_debug "Package: $pkg | Type: $type | Repo: $repo | Channel: $channel"

  case "$type" in
    github-release)
      local tag
      tag="$(normalize_basic_tag_to_version "$(github_latest_release_tag "$repo" "$channel" 2>/dev/null)")"
      if [[ -n "$tag" && -n "$version_regex" && -n "$version_format" ]]; then
        apply_version_regex "$tag" "$version_regex" "$version_format" 2>/dev/null || echo "$tag"
      else
        echo "$tag"
      fi
      ;;
    github-release-filtered)
      local tag
      tag="$(normalize_basic_tag_to_version "$(github_latest_release_tag_filtered "$repo" "$channel" "$tag_regex" 2>/dev/null)")"
      if [[ -n "$tag" && -n "$version_regex" && -n "$version_format" ]]; then
        apply_version_regex "$tag" "$version_regex" "$version_format" 2>/dev/null || echo "$tag"
      else
        echo "$tag"
      fi
      ;;
    github-tags-filtered)
      local versions
      versions="$(github_tags_filtered_versions "$repo" "$tag_regex" "$version_regex" "$version_format" 2>/dev/null)"
      pick_max_version_list <<<"$versions"
      ;;
    vcs)
      # VCS packages: optionally check repo for latest tag
      if [[ -n "$repo" ]]; then
        local tag
        tag="$(normalize_basic_tag_to_version "$(github_latest_release_tag "$repo" "stable" 2>/dev/null)")"
        if [[ -n "$tag" && -n "$version_regex" && -n "$version_format" ]]; then
          apply_version_regex "$tag" "$version_regex" "$version_format" 2>/dev/null || echo "$tag"
        else
          echo "$tag"
        fi
      else
        echo ""
      fi
      ;;
    chrome)
      get_chrome_version_json "$channel" 2>/dev/null
      ;;
    edge)
      get_edge_version "$url" 2>/dev/null
      ;;
    vscode)
      get_vscode_version 2>/dev/null
      ;;
    1password-cli2)
      get_1password_cli2_version_json "$url" 2>/dev/null
      ;;
    1password-linux-stable)
      get_1password_linux_stable_version "$url" 2>/dev/null
      ;;
    lmstudio)
      get_lmstudio_version 2>/dev/null
      ;;
    manual)
      echo ""
      ;;
    "")
      log_debug "Empty type for $pkg, treating as manual"
      echo ""
      ;;
    *)
      log_warning "Unknown feed type '$type' for $pkg (treating as manual)"
      echo ""
      ;;
  esac
}

# ============================================================================
# PKGBUILD Helpers
# ============================================================================

get_current_pkgver() {
  local pkgbuild_path="${1:-}"
  [[ ! -f "$pkgbuild_path" ]] && echo "" && return 0
  grep -E '^pkgver=' "$pkgbuild_path" | head -1 | cut -d'=' -f2- \
    | sed "s/^[\"']*//; s/[\"']*$//"
}

is_vcs_pkg() {
  local feeds_json="${1:-}"
  local pkg="${2:-}"
  local type
  type="$(feeds_json_get_field "$feeds_json" "$pkg" "type")"
  [[ "$type" == "vcs" ]] && return 0
  [[ "$pkg" =~ -(git|hg|svn|bzr)$ ]] && return 0
  return 1
}

update_pkgbuild_version() {
  local pkgbuild_path="${1:-}"
  local new_version="${2:-}"

  local clean_version
  clean_version="$(trim "$new_version")"
  clean_version="${clean_version//-/_}"

  if [[ ! -w "$(dirname "$pkgbuild_path")" ]]; then
    log_warning "Not writable: $(dirname "$pkgbuild_path")"
    return 1
  fi

  # Backup
  if ! cp "$pkgbuild_path" "${pkgbuild_path}.backup" 2>/dev/null; then
    log_warning "Failed to write backup: ${pkgbuild_path}.backup"
    return 1
  fi

  # Update pkgver
  if ! sed -i -E "s/^pkgver=.*/pkgver='${clean_version//&/\\&}'/" "$pkgbuild_path"; then
    log_warning "Failed to update pkgver in $pkgbuild_path"
    return 1
  fi

  # Reset pkgrel to 1
  if ! sed -i -E "s/^pkgrel=.*/pkgrel=1/" "$pkgbuild_path"; then
    log_warning "Failed to update pkgrel in $pkgbuild_path"
    return 1
  fi

  return 0
}

update_checksums() {
  local pkg_dir="${1:-}"
  ( cd "$pkg_dir" && updpkgsums ) >/dev/null 2>&1
}

# ============================================================================
# Version Comparison & Status
# ============================================================================

compare_versions() {
  local current="${1:-}"
  local upstream="${2:-}"
  
  log_debug "compare_versions: current='$current' upstream='$upstream'"
  
  # Use vercmp if available for accurate comparison
  if command -v vercmp >/dev/null 2>&1; then
    local vercmp_result
    vercmp_result="$(vercmp "$upstream" "$current")"
    log_debug "vercmp '$upstream' '$current' returned: $vercmp_result"
    
    case "$vercmp_result" in
      -1) 
        log_debug "  → upstream < current (local is newer)"
        return 1
        ;;
      0)
        log_debug "  → upstream == current (up to date)"
        return 2
        ;;
      1)
        log_debug "  → upstream > current (update available)"
        return 0
        ;;
    esac
  else
    log_debug "vercmp not available, using string comparison"
    # Fallback to string comparison
    if [[ "$upstream" == "$current" ]]; then
      log_debug "  → strings equal (up to date)"
      return 2  # Equal
    elif [[ "$upstream" > "$current" ]]; then
      log_debug "  → upstream > current (update available)"
      return 0  # Update available
    else
      log_debug "  → upstream < current (local newer)"
      return 1  # Local newer
    fi
  fi
}

status_for() {
  local current="${1:-}"
  local upstream="${2:-}"
  local has_feed="${3:-}"
  local is_vcs="${4:-}"
  local is_manual="${5:-}"

  if [[ "$has_feed" != "true" ]]; then
    echo "NO_FEED"
    return 0
  fi

  if [[ "$is_manual" == "true" ]]; then
    echo "MANUAL"
    return 0
  fi

  if [[ "$is_vcs" == "true" ]]; then
    echo "VCS"
    return 0
  fi

  if [[ -z "$upstream" ]]; then
    echo "UNKNOWN"
    return 0
  fi

  if [[ -z "$current" ]]; then
    echo "UPDATE"
    return 0
  fi

  # Call compare_versions once and capture return code
  compare_versions "$current" "$upstream"
  local cmp_result=$?
  
  log_debug "status_for: cmp_result=$cmp_result"
  
  case $cmp_result in
    0)  
      log_debug "  → returning UPDATE"
      echo "UPDATE"
      ;;
    2)  
      log_debug "  → returning OK"
      echo "OK"
      ;;
    1)  
      log_debug "  → returning NEWER"
      echo "NEWER"
      ;;
    *)  
      log_debug "  → returning UNKNOWN (unexpected result: $cmp_result)"
      echo "UNKNOWN"
      ;;
  esac
}

# ============================================================================
# Output Formatting
# ============================================================================

print_table_header() {
  printf "\n%-30s %-18s %-18s %-10s\n" "PACKAGE" "CURRENT" "UPSTREAM" "STATUS"
  printf "%-30s %-18s %-18s %-10s\n" \
    "------------------------------" "------------------" "------------------" "----------"
}

# ============================================================================
# CLI Options
# ============================================================================

declare FEEDS_JSON="$FEEDS_JSON"
declare LIST_OUTDATED="false"
declare OUTPUT_JSON="false"
declare APPLY_UPDATES="false"
declare DEBUG="false"
declare -a SPECIFIC_PACKAGES=()

show_usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [packages...]

Check which packages need updates (version detection only by default).
Use --apply to actually update PKGBUILDs.

This script does NOT build packages. Use build-packages.sh for building.

OPTIONS:
  --feeds <path>        Path to feeds.json (default: $FEEDS_JSON)
  --apply               Actually update PKGBUILDs (pkgver + checksums)
  --list-outdated       Only output package names needing updates
  --json                Output JSON for scripting
  --debug               Extra diagnostics
  -h, --help            Show this help

If packages are specified, only those packages are checked.
Otherwise, all packages in feeds.json are checked.

EXAMPLES:
  # Check all packages (dry-run)
  $0

  # Actually update PKGBUILDs
  $0 --apply

  # Check specific packages
  $0 ktailctl ollama

  # Update specific packages
  $0 --apply ktailctl ollama

  # Get list for piping to build-packages.sh
  $0 --list-outdated | xargs ./build-packages.sh

  # Full workflow
  $0 --apply
  $0 --list-outdated | xargs ./build-packages.sh
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --feeds)
        FEEDS_JSON="$2"
        shift 2
        ;;
      --apply) APPLY_UPDATES="true"; shift ;;
      --list-outdated) LIST_OUTDATED="true"; shift ;;
      --json) OUTPUT_JSON="true"; shift ;;
      --debug) DEBUG="true"; shift ;;
      --dry-run) shift ;;  # Accept but ignore (for compatibility)
      -h|--help) show_usage; exit 0 ;;
      -*)
        log_error "Unknown option: $1"
        show_usage
        exit 1
        ;;
      *)
        SPECIFIC_PACKAGES+=("$1")
        shift
        ;;
    esac
  done
}

# ============================================================================
# Package Checking
# ============================================================================

check_single_package() {
  local pkg="$1"
  local pkg_dir="$PKG_DIR/$pkg"
  local pkgbuild="$pkg_dir/PKGBUILD"
  
  if [[ ! -d "$pkg_dir" ]]; then
    if [[ "$LIST_OUTDATED" != "true" && "$OUTPUT_JSON" != "true" ]]; then
      log_error "$pkg: Package directory not found"
    fi
    return 1
  fi
  
  if [[ ! -f "$pkgbuild" ]]; then
    if [[ "$LIST_OUTDATED" != "true" && "$OUTPUT_JSON" != "true" ]]; then
      log_error "$pkg: PKGBUILD not found"
    fi
    return 1
  fi
  
  # Get feed info
  local has_feed="false"
  feeds_json_has_pkg "$FEEDS_JSON" "$pkg" && has_feed="true"
  
  if [[ "$has_feed" != "true" ]]; then
    if [[ "$LIST_OUTDATED" != "true" && "$OUTPUT_JSON" != "true" ]]; then
      log_warning "$pkg: Not found in feeds.json"
    fi
    return 1
  fi
  
  local type
  type="$(feeds_json_get_field "$FEEDS_JSON" "$pkg" "type")"
  
  local is_manual="false"
  [[ "$type" == "manual" ]] && is_manual="true"
  
  local is_vcs="false"
  is_vcs_pkg "$FEEDS_JSON" "$pkg" && is_vcs="true"
  
  # Get versions
  local current upstream
  current="$(get_current_pkgver "$pkgbuild")"
  upstream=""
  
  if [[ "$has_feed" == "true" ]]; then
    upstream="$(trim "$(fetch_upstream_version_for_pkg "$FEEDS_JSON" "$pkg")")"
    
    # Debug: If we couldn't get upstream version, explain why
    if [[ -z "$upstream" && "$is_manual" != "true" && "${DEBUG:-false}" == "true" ]]; then
      log_debug "$pkg: Failed to detect remote version"
      log_debug "  Type: $type"
      log_debug "  This could be due to:"
      log_debug "    - Network/API issue"
      log_debug "    - GitHub rate limiting (set GITHUB_TOKEN)"
      log_debug "    - Regex not matching tag format"
      log_debug "    - API response format changed"
      log_debug "  Try: DEBUG=true $0 $pkg"
    fi
  fi
  
  # Determine status
  local status
  status="$(status_for "$current" "$upstream" "$has_feed" "$is_vcs" "$is_manual")"
  
  # Output based on mode
  if [[ "$LIST_OUTDATED" == "true" ]]; then
    if [[ "$status" == "UPDATE" ]]; then
      echo "$pkg"
    fi
  elif [[ "$OUTPUT_JSON" == "true" ]]; then
    jq -n \
      --arg pkg "$pkg" \
      --arg current "${current:-}" \
      --arg upstream "${upstream:-}" \
      --arg status "$status" \
      '{
        package: $pkg,
        current_version: $current,
        upstream_version: $upstream,
        status: $status
      }'
  else
    # Human-readable output
    local upstream_display="$upstream"
    if [[ "$is_manual" == "true" ]]; then
      upstream_display="n/a"
    elif [[ "$is_vcs" == "true" ]]; then
      if [[ -n "$upstream" ]]; then
        upstream_display="${upstream} (stable)"
      else
        upstream_display="VCS"
      fi
    elif [[ -z "$upstream_display" ]]; then
      upstream_display="n/a"
    fi
    
    case "$status" in
      UPDATE)
        # Apply updates if --apply flag is set
        if [[ "$APPLY_UPDATES" == "true" ]]; then
          log_info "$pkg: Updating ${current:-n/a} → $upstream_display"
          
          if update_pkgbuild_version "$pkgbuild" "$upstream"; then
            log_info "$pkg: Updated PKGBUILD"
            
            # Update checksums
            if update_checksums "$pkg_dir"; then
              log_success "$pkg: Updated checksums"
            else
              log_warning "$pkg: Failed to update checksums (run updpkgsums manually)"
            fi
            
            return 0
          else
            log_error "$pkg: Failed to update PKGBUILD"
            return 1
          fi
        else
          log_info "$pkg: ${current:-n/a} → $upstream_display (update available)"
          return 0
        fi
        ;;
      OK)
        log_success "$pkg: up-to-date ($current)"
        return 1
        ;;
      NEWER)
        log_warning "$pkg: local version ($current) is newer than remote ($upstream)"
        return 1
        ;;
      MANUAL)
        log_info "$pkg: Manual package, skipping version check"
        return 1
        ;;
      VCS)
        if [[ -n "$upstream" ]]; then
          log_info "$pkg: VCS package (stable: $upstream)"
        fi
        return 1
        ;;
      UNKNOWN)
        log_warning "$pkg: Could not detect remote version"
        return 1
        ;;
      *)
        return 1
        ;;
    esac
  fi
}

check_all_packages() {
  if [[ ! -f "$FEEDS_JSON" ]]; then
    log_error "feeds.json not found: $FEEDS_JSON"
    return 1
  fi
  
  local -a all_packages=()
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && all_packages+=("$pkg")
  done < <(feeds_json_list_packages "$FEEDS_JSON" 2>/dev/null | sort -u)
  
  if [[ ${#all_packages[@]} -eq 0 ]]; then
    log_error "No packages found in feeds.json"
    return 1
  fi
  
  if [[ "$LIST_OUTDATED" != "true" && "$OUTPUT_JSON" != "true" ]]; then
    print_table_header
  fi
  
  local pkg=""
  local outdated_count=0
  local updated_count=0
  
  for pkg in "${all_packages[@]}"; do
    if check_single_package "$pkg"; then
      ((outdated_count++))
      if [[ "$APPLY_UPDATES" == "true" ]]; then
        ((updated_count++))
      fi
    fi
  done
  
  if [[ "$LIST_OUTDATED" != "true" && "$OUTPUT_JSON" != "true" ]]; then
    echo ""
    if [[ "$APPLY_UPDATES" == "true" ]]; then
      if [[ $updated_count -eq 0 ]]; then
        log_success "No packages needed updating"
      else
        log_success "Updated $updated_count package(s)"
        log_info "Build with: ./build-packages.sh --list-outdated | xargs ./build-packages.sh"
      fi
    else
      if [[ $outdated_count -eq 0 ]]; then
        log_success "All packages are up-to-date"
      else
        log_info "$outdated_count package(s) need updates"
        log_info "Apply updates: $0 --apply"
        log_info "Then build: ./build-packages.sh --all"
      fi
    fi
  fi
  
  return 0
}

# ============================================================================
# Main
# ============================================================================

main() {
  parse_args "$@"
  
  # Check dependencies
  local -a missing=()
  command -v jq >/dev/null 2>&1 || missing+=("jq")
  command -v curl >/dev/null 2>&1 || missing+=("curl")
  command -v python3 >/dev/null 2>&1 || missing+=("python")
  command -v xmllint >/dev/null 2>&1 || missing+=("libxml2")
  
  # Only check for updpkgsums if --apply is set
  if [[ "$APPLY_UPDATES" == "true" ]]; then
    command -v updpkgsums >/dev/null 2>&1 || missing+=("pacman-contrib")
  fi
  
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing dependencies: ${missing[*]}"
    log_info "Install with: sudo pacman -S ${missing[*]}"
    exit 1
  fi
  
  if [[ ! -f "$FEEDS_JSON" ]]; then
    log_error "feeds.json not found: $FEEDS_JSON"
    exit 1
  fi
  
  if [[ ${#SPECIFIC_PACKAGES[@]} -gt 0 ]]; then
    # Check specific packages
    local pkg=""
    for pkg in "${SPECIFIC_PACKAGES[@]}"; do
      check_single_package "$pkg"
    done
  else
    # Check all packages
    check_all_packages
  fi
}

main "$@"