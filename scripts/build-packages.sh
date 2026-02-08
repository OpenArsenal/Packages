#!/usr/bin/env bash
set -uo pipefail

# build-packages.sh - Build packages using makepkg (ONE JOB: BUILD)
#
# This script does ONLY building. It does NOT:
# - Check versions (that's update-pkg.sh --dry-run)
# - Install packages (that's pacman)
# - Manage repository (that's repo-mgmt.sh)
#
# It DOES:
# - Run makepkg in each package directory
# - Show ALL output (no silent failures)
# - Stage artifacts in a central location
# - Log everything
# - Handle errors gracefully
#
# Examples:
#   ./build-packages.sh ktailctl ollama        # Build these packages
#   ./build-packages.sh --all                   # Build all in feeds.json
#   ./build-packages.sh --failed                # Retry failed builds

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ============================================================================
# Configuration
# ============================================================================

# Staging area for built packages
declare -r STAGING_DIR="${STAGING_DIR:-$HOME/.cache/pkg-mgmt/staging}"

# Build logs
declare -r BUILD_LOG_DIR="${BUILD_LOG_DIR:-$LOG_DIR/builds}"

# Failed builds tracking
declare -r FAILED_BUILDS="$HOME/.cache/pkg-mgmt/failed-builds.txt"

# ============================================================================
# Options
# ============================================================================

declare BUILD_ALL="false"
declare RETRY_FAILED="false"
declare CLEAN_BUILD="false"
declare SIGN_PACKAGES="$SIGN_PACKAGES"
declare -a PACKAGES=()

show_usage() {
  cat <<EOF
Usage: $0 [OPTIONS] <package> [packages...]

Build packages using makepkg with full output and logging.

This script ONLY builds. Use other scripts for:
  - Version checking: update-pkg.sh --dry-run
  - Installation: pacman -U or pacman -Syu
  - Repository: repo-mgmt.sh add

OPTIONS:
  --all               Build all packages in feeds.json
  --failed            Retry failed builds
  --clean             Clean src/pkg before building
  --sign              Sign packages with GPG
  -h, --help          Show this help

STAGING AREA:
  Built packages are moved to: $STAGING_DIR
  
BUILD LOGS:
  Per-package logs saved to: $BUILD_LOG_DIR

EXAMPLES:
  # Build specific packages
  $0 ktailctl ollama

  # Build everything
  $0 --all

  # Retry failed builds
  $0 --failed

  # Clean build
  $0 --clean google-chrome-canary-bin
EOF
}

# ============================================================================
# Setup
# ============================================================================

setup_directories() {
  mkdir -p "$STAGING_DIR" "$BUILD_LOG_DIR"
}

# ============================================================================
# Build State Tracking
# ============================================================================

mark_build_failed() {
  local pkg="$1"
  local timestamp="$(date +%Y-%m-%d_%H:%M:%S)"
  
  echo "$timestamp $pkg" >> "$FAILED_BUILDS"
}

mark_build_succeeded() {
  local pkg="$1"
  
  # Remove from failed builds if present
  if [[ -f "$FAILED_BUILDS" ]]; then
    sed -i "/[[:space:]]${pkg}$/d" "$FAILED_BUILDS"
  fi
}

get_failed_builds() {
  if [[ ! -f "$FAILED_BUILDS" ]]; then
    return
  fi
  
  # Get unique package names from failed builds file
  awk '{print $2}' "$FAILED_BUILDS" | sort -u
}

# ============================================================================
# Package Building
# ============================================================================

build_single_package() {
  local pkg="$1"
  local pkg_dir="$BUILD_ROOT/$pkg"
  
  if [[ ! -d "$pkg_dir" ]]; then
    log_error "Package directory not found: $pkg_dir"
    return 1
  fi
  
  if [[ ! -f "$pkg_dir/PKGBUILD" ]]; then
    log_error "PKGBUILD not found in: $pkg_dir"
    return 1
  fi
  
  local build_log="$BUILD_LOG_DIR/${pkg}-$(date +%Y%m%d-%H%M%S).log"
  
  log_info "Building: $pkg"
  log_info "  Directory: $pkg_dir"
  log_info "  Log file: $build_log"
  
  # Clean if requested
  if [[ "$CLEAN_BUILD" == "true" ]]; then
    log_info "  Cleaning src/ and pkg/"
    rm -rf "$pkg_dir/src" "$pkg_dir/pkg" "$pkg_dir"/*.pkg.tar.* 2>/dev/null || true
  fi
  
  # Prepare makepkg arguments
  local -a makepkg_args=(
    -s              # Install/check dependencies
    -f              # Force (overwrite existing package)
    -c              # Clean up afterward
    --noconfirm     # Don't ask for confirmation
    --needed        # Don't reinstall up-to-date dependencies
  )
  
  if [[ "$SIGN_PACKAGES" == "true" ]]; then
    makepkg_args+=(--sign)
    if [[ -n "$SIGN_KEY" ]]; then
      makepkg_args+=(--key "$SIGN_KEY")
    fi
  fi
  
  log_info "  Running: makepkg ${makepkg_args[*]}"
  echo ""
  
  # Run makepkg with FULL output visible
  # Use tee to show output AND save to log
  (
    cd "$pkg_dir"
    
    # This is the KEY difference: we DON'T redirect output
    # User sees everything, AND it's logged
    if makepkg "${makepkg_args[@]}" 2>&1 | tee "$build_log"; then
      return 0
    else
      return 1
    fi
  )
  
  local build_status=$?
  
  echo ""
  
  if [[ $build_status -ne 0 ]]; then
    log_error "Build FAILED: $pkg"
    log_error "  See log: $build_log"
    mark_build_failed "$pkg"
    return 1
  fi
  
  # Find built packages
  local -a built_files=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && built_files+=("$f")
  done < <(find "$pkg_dir" -maxdepth 1 -name "*.pkg.tar.*" -type f -newer "$pkg_dir/PKGBUILD")
  
  if [[ ${#built_files[@]} -eq 0 ]]; then
    log_error "Build succeeded but no package files found for: $pkg"
    mark_build_failed "$pkg"
    return 1
  fi
  
  log_success "Built: $pkg (${#built_files[@]} package(s))"
  
  # Stage artifacts
  log_info "Staging artifacts to: $STAGING_DIR"
  local f=""
  for f in "${built_files[@]}"; do
    local basename="$(basename "$f")"
    
    if mv "$f" "$STAGING_DIR/$basename"; then
      log_info "  → $basename"
    else
      log_error "Failed to stage: $basename"
      mark_build_failed "$pkg"
      return 1
    fi
  done
  
  mark_build_succeeded "$pkg"
  
  # Summary
  echo ""
  log_success "Successfully built: $pkg"
  log_info "  Artifacts: $STAGING_DIR"
  log_info "  Log: $build_log"
  echo ""
  
  return 0
}

# ============================================================================
# Batch Building
# ============================================================================

build_multiple_packages() {
  local -a packages=("$@")
  
  if [[ ${#packages[@]} -eq 0 ]]; then
    log_error "No packages to build"
    return 1
  fi
  
  log_info "Building ${#packages[@]} package(s)..."
  echo ""
  
  local total=${#packages[@]}
  local current=0
  local succeeded=0
  local failed=0
  
  local -a failed_pkgs=()
  local pkg=""
  
  for pkg in "${packages[@]}"; do
    ((current++))
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Building package $current of $total: $pkg"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    if build_single_package "$pkg"; then
      ((succeeded++))
    else
      ((failed++))
      failed_pkgs+=("$pkg")
    fi
    
    echo ""
  done
  
  # Summary
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "Build Summary"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "Total:     $total"
  log_success "Succeeded: $succeeded"
  
  if [[ $failed -gt 0 ]]; then
    log_error "Failed:    $failed"
    echo ""
    log_error "Failed packages:"
    for pkg in "${failed_pkgs[@]}"; do
      log_error "  - $pkg"
    done
    echo ""
    log_info "Retry with: $0 --failed"
  fi
  
  echo ""
  log_info "Staged artifacts: $STAGING_DIR"
  log_info "Build logs: $BUILD_LOG_DIR"
  echo ""
  
  if [[ $failed -gt 0 ]]; then
    return 1
  fi
  
  return 0
}

# ============================================================================
# Package Discovery
# ============================================================================

get_all_packages() {
  if [[ ! -f "$FEEDS_JSON" ]]; then
    log_error "feeds.json not found: $FEEDS_JSON"
    return 1
  fi
  
  jq -r '.packages[]?.name // empty' "$FEEDS_JSON" | sort -u
}

# ============================================================================
# Main
# ============================================================================

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) BUILD_ALL="true"; shift ;;
      --failed) RETRY_FAILED="true"; shift ;;
      --clean) CLEAN_BUILD="true"; shift ;;
      --sign) SIGN_PACKAGES="true"; shift ;;
      -h|--help) show_usage; exit 0 ;;
      -*)
        log_error "Unknown option: $1"
        show_usage
        exit 1
        ;;
      *)
        PACKAGES+=("$1")
        shift
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  setup_directories
  
  local -a packages_to_build=()
  
  if [[ "$RETRY_FAILED" == "true" ]]; then
    log_info "Retrying failed builds..."
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] && packages_to_build+=("$pkg")
    done < <(get_failed_builds)
    
    if [[ ${#packages_to_build[@]} -eq 0 ]]; then
      log_success "No failed builds to retry"
      return 0
    fi
    
  elif [[ "$BUILD_ALL" == "true" ]]; then
    log_info "Building all packages from feeds.json..."
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] && packages_to_build+=("$pkg")
    done < <(get_all_packages)
    
  elif [[ ${#PACKAGES[@]} -gt 0 ]]; then
    packages_to_build=("${PACKAGES[@]}")
    
  else
    log_error "No packages specified"
    show_usage
    exit 1
  fi
  
  build_multiple_packages "${packages_to_build[@]}"
}

main "$@"