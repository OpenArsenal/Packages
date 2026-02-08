#!/usr/bin/env bash
set -uo pipefail

# compare-versions.sh - Compare version detection across tools
#
# Cross-checks version detection from:
# - feeds.json (our version detection)
# - paru -Qua (AUR helper)
# - aur-vercmp (aurutils)
# - Local repository
# - Installed packages
#
# Examples:
#   ./compare-versions.sh                    # Compare all
#   ./compare-versions.sh --fix-feeds        # Auto-update feeds.json
#   ./compare-versions.sh --package ktailctl # Check specific package

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ============================================================================
# Options
# ============================================================================

declare FIX_FEEDS="false"
declare SPECIFIC_PKG=""
declare OUTPUT_JSON="false"

show_usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Compare version detection across multiple tools to find discrepancies.

SOURCES COMPARED:
  - feeds.json version detection
  - paru -Qua (if installed)
  - aur-vercmp (if installed)
  - Local repository
  - Installed package versions

OPTIONS:
  --fix-feeds             Auto-update feeds.json with corrections
  --package <name>        Check specific package only
  --json                  Output JSON
  -h, --help              Show this help

EXAMPLES:
  # Compare all packages
  $0

  # Check specific package
  $0 --package ktailctl

  # Find and fix discrepancies
  $0 --fix-feeds
EOF
}

# ============================================================================
# Version Detection
# ============================================================================

get_feeds_version() {
  local pkg="$1"
  
  if [[ ! -f "$FEEDS_JSON" ]]; then
    return 1
  fi
  
  # Check if package is in feeds.json
  local has_pkg=""
  has_pkg=$(jq -r --arg pkg "$pkg" '.packages[]? | select(.name == $pkg) | .name' "$FEEDS_JSON" 2>/dev/null)
  
  if [[ -z "$has_pkg" ]]; then
    return 1
  fi
  
  # Simulate version check by running update-pkg.sh in dry-run mode
  # This is expensive but accurate
  local check_output=""
  check_output=$("$SCRIPT_DIR/update-pkg.sh" --dry-run "$pkg" 2>&1 || echo "")
  
  # Parse output for version information
  # Format: "package: X.Y.Z -> A.B.C" or "package: up-to-date (X.Y.Z)"
  local remote_ver=""
  remote_ver=$(echo "$check_output" | grep -oP '(?<=-> )[0-9][^ ]+' || echo "")
  
  if [[ -z "$remote_ver" ]]; then
    # Try to extract "up-to-date" version
    remote_ver=$(echo "$check_output" | grep -oP '(?<=up-to-date \()[^)]+' || echo "")
  fi
  
  echo "$remote_ver"
}

get_paru_version() {
  local pkg="$1"
  
  if [[ "$HAS_PARU" != "true" ]]; then
    return 1
  fi
  
  # Get upgrade info from paru
  local paru_output=""
  paru_output=$(paru -Qua 2>/dev/null | grep "^$pkg " || echo "")
  
  if [[ -z "$paru_output" ]]; then
    # Package not flagged for upgrade by paru
    return 1
  fi
  
  # Parse: "pkgname oldver -> newver"
  echo "$paru_output" | awk '{print $NF}'
}

get_repo_version() {
  local pkg="$1"
  
  if [[ ! -f "$REPO_DB" ]]; then
    return 1
  fi
  
  # Extract version from repo database
  bsdtar -xOf "$REPO_DB" 2>/dev/null | awk -v pkg="$pkg" '
    /^%NAME%$/ { getline; name=$0 }
    /^%VERSION%$/ { getline; version=$0; if (name == pkg) print version }
  '
}

get_installed_version() {
  local pkg="$1"
  
  pacman -Q "$pkg" 2>/dev/null | awk '{print $2}'
}

# ============================================================================
# Comparison Logic
# ============================================================================

compare_package() {
  local pkg="$1"
  
  local feeds_ver="" paru_ver="" repo_ver="" installed_ver=""
  
  log_debug "Checking: $pkg"
  
  feeds_ver=$(get_feeds_version "$pkg" 2>/dev/null || echo "")
  paru_ver=$(get_paru_version "$pkg" 2>/dev/null || echo "")
  repo_ver=$(get_repo_version "$pkg" 2>/dev/null || echo "")
  installed_ver=$(get_installed_version "$pkg" 2>/dev/null || echo "")
  
  # Determine if there's a discrepancy
  local has_discrepancy="false"
  local -a versions=()
  
  [[ -n "$feeds_ver" ]] && versions+=("$feeds_ver")
  [[ -n "$paru_ver" ]] && versions+=("$paru_ver")
  [[ -n "$repo_ver" ]] && versions+=("$repo_ver")
  
  # Check if all non-empty versions agree
  if [[ ${#versions[@]} -gt 1 ]]; then
    local first="${versions[0]}"
    local v=""
    for v in "${versions[@]}"; do
      if [[ "$v" != "$first" ]]; then
        has_discrepancy="true"
        break
      fi
    done
  fi
  
  # Output results
  if [[ "$OUTPUT_JSON" == "true" ]]; then
    jq -n \
      --arg pkg "$pkg" \
      --arg feeds "$feeds_ver" \
      --arg paru "$paru_ver" \
      --arg repo "$repo_ver" \
      --arg installed "$installed_ver" \
      --arg discrepancy "$has_discrepancy" \
      '{
        package: $pkg,
        feeds_detected: $feeds,
        paru_detected: $paru,
        repo_version: $repo,
        installed_version: $installed,
        has_discrepancy: ($discrepancy == "true")
      }'
  else
    printf "%-30s" "$pkg"
    printf " Feeds:%-12s" "${feeds_ver:-N/A}"
    printf " Paru:%-12s" "${paru_ver:-N/A}"
    printf " Repo:%-12s" "${repo_ver:-N/A}"
    printf " Installed:%-12s" "${installed_ver:-N/A}"
    
    if [[ "$has_discrepancy" == "true" ]]; then
      printf " ${YELLOW}[DISCREPANCY]${NC}"
    fi
    
    echo ""
  fi
  
  echo "$has_discrepancy"
}

# ============================================================================
# Fix Feeds
# ============================================================================

fix_feeds_for_package() {
  local pkg="$1"
  
  log_warning "Auto-fix not yet implemented for: $pkg"
  
  # TODO: Update feeds.json with correct version
  # This requires understanding which source is authoritative
  # For now, just report
}

# ============================================================================
# Main Comparison
# ============================================================================

compare_all_packages() {
  if [[ ! -f "$FEEDS_JSON" ]]; then
    log_error "feeds.json not found: $FEEDS_JSON"
    return 1
  fi
  
  # Get packages from feeds.json
  local -a packages=()
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && packages+=("$pkg")
  done < <(jq -r '.packages[]?.name // empty' "$FEEDS_JSON" 2>/dev/null | sort -u)
  
  if [[ ${#packages[@]} -eq 0 ]]; then
    log_error "No packages found in feeds.json"
    return 1
  fi
  
  log_info "Comparing ${#packages[@]} package(s)..."
  
  if [[ "$OUTPUT_JSON" != "true" ]]; then
    echo ""
    printf "%-30s %-14s %-14s %-14s %-14s %s\n" \
      "PACKAGE" "FEEDS" "PARU" "REPO" "INSTALLED" "STATUS"
    printf "%.0s-" {1..120}
    echo ""
  fi
  
  local discrepancy_count=0
  local pkg=""
  
  for pkg in "${packages[@]}"; do
    local has_discrepancy=""
    has_discrepancy=$(compare_package "$pkg")
    
    if [[ "$has_discrepancy" == "true" ]]; then
      ((discrepancy_count++))
      
      if [[ "$FIX_FEEDS" == "true" ]]; then
        fix_feeds_for_package "$pkg"
      fi
    fi
  done
  
  if [[ "$OUTPUT_JSON" != "true" ]]; then
    echo ""
    
    if [[ $discrepancy_count -eq 0 ]]; then
      log_success "All versions match across tools"
    else
      log_warning "Found $discrepancy_count discrepancy(ies)"
      
      if [[ "$FIX_FEEDS" != "true" ]]; then
        log_info "Run with --fix-feeds to attempt automatic correction"
      fi
    fi
  fi
}

# ============================================================================
# Main
# ============================================================================

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fix-feeds) FIX_FEEDS="true"; shift ;;
      --package) SPECIFIC_PKG="${2:?missing package name}"; shift 2 ;;
      --json) OUTPUT_JSON="true"; shift ;;
      -h|--help) show_usage; exit 0 ;;
      -*)
        log_error "Unknown option: $1"
        show_usage
        exit 1
        ;;
      *)
        log_error "Unexpected argument: $1"
        show_usage
        exit 1
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  
  if [[ -n "$SPECIFIC_PKG" ]]; then
    compare_package "$SPECIFIC_PKG" >/dev/null
  else
    compare_all_packages
  fi
}

main "$@"