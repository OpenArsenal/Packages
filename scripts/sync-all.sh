#!/usr/bin/env bash
set -uo pipefail

# sync-all.sh - Full update orchestration
#
# Orchestrates the complete update workflow:
# 1. Check Arch news
# 2. Find updates (via update-pkg.sh --dry-run)
# 3. Review changes (if requested)
# 4. Resolve dependencies
# 5. Build updated packages
# 6. Update local repository
# 7. Install via pacman -Syu
#
# This is your "update everything" command.
#
# Examples:
#   ./sync-all.sh                    # Full auto update
#   ./sync-all.sh --review           # With PKGBUILD review
#   ./sync-all.sh --no-install       # Build but don't install

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ============================================================================
# Options
# ============================================================================

declare REVIEW_MODE="false"
declare CHROOT_MODE="false"
declare NO_INSTALL="false"
declare CHECK_NEWS="$ENABLE_NEWS_CHECK"
declare SPECIFIC_PACKAGES=()

show_usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [packages...]

Complete update workflow: check news, find updates, build, install.

OPTIONS:
  --review                Review PKGBUILDs before building
  --chroot                Build in clean chroot
  --no-install            Build packages but don't install
  --skip-news             Skip Arch news check
  -h, --help              Show this help

WORKFLOW:
  1. Check Arch Linux news (if enabled)
  2. Detect updates for all packages in feeds.json
  3. Review PKGBUILDs (if --review)
  4. Resolve and import AUR dependencies
  5. Build packages (with dependency order)
  6. Update local repository
  7. Install via pacman -Syu (unless --no-install)

If packages are specified, only those packages are updated.

EXAMPLES:
  # Full auto update
  $0

  # Update with review
  $0 --review

  # Update specific packages
  $0 ktailctl ollama

  # Build in chroot, don't install
  $0 --chroot --no-install
EOF
}

# ============================================================================
# Logging
# ============================================================================

declare -r SESSION_LOG="$LOG_DIR/sync-all-$(date +%Y%m%d-%H%M%S).log"

log_session() {
  local level="$1"
  shift
  
  # Log to both console and file
  case "$level" in
    INFO) log_info "$@" ;;
    SUCCESS) log_success "$@" ;;
    WARNING) log_warning "$@" ;;
    ERROR) log_error "$@" ;;
  esac
  
  # Also to session log
  echo "[$(date +%H:%M:%S)] [$level] $*" >> "$SESSION_LOG"
}

# ============================================================================
# Step 1: Check News
# ============================================================================

step_check_news() {
  if [[ "$CHECK_NEWS" != "true" ]]; then
    log_session INFO "Skipping news check (disabled)"
    return 0
  fi
  
  log_session INFO "Step 1: Checking Arch Linux news..."
  
  if ! "$SCRIPT_DIR/check-news.sh" --no-mark-read; then
    log_session WARNING "Failed to check news (continuing anyway)"
  fi
  
  # Ask user if they want to continue after seeing news
  if [[ -t 0 ]]; then
    echo ""
    read -p "Continue with update? [Y/n]: " -n 1 -r
    echo ""
    if [[ "$REPLY" =~ ^[Nn]$ ]]; then
      log_session INFO "Update cancelled by user"
      exit 0
    fi
  fi
}

# ============================================================================
# Step 2: Detect Updates
# ============================================================================

step_detect_updates() {
  log_session INFO "Step 2: Detecting updates..."
  
  local -a update_args=("--dry-run")
  
  if [[ ${#SPECIFIC_PACKAGES[@]} -gt 0 ]]; then
    update_args+=("${SPECIFIC_PACKAGES[@]}")
  fi
  
  # Run update-pkg.sh in dry-run mode
  local updates_output=""
  updates_output=$("$SCRIPT_DIR/update-pkg.sh" "${update_args[@]}" 2>&1 || echo "")
  
  # Parse output to find packages needing updates
  local -a packages_to_update=()
  while IFS= read -r line; do
    # Look for lines like: "[INFO] package: X.Y.Z -> A.B.C"
    if [[ "$line" =~ \[INFO\][[:space:]]+([^:]+):[[:space:]]+[0-9] ]]; then
      local pkg="${BASH_REMATCH[1]}"
      [[ -n "$pkg" ]] && packages_to_update+=("$pkg")
    fi
  done <<< "$updates_output"
  
  if [[ ${#packages_to_update[@]} -eq 0 ]]; then
    log_session SUCCESS "No updates available"
    return 1
  fi
  
  log_session INFO "Found ${#packages_to_update[@]} package(s) to update:"
  for pkg in "${packages_to_update[@]}"; do
    log_session INFO "  - $pkg"
  done
  
  # Export for other steps
  printf "%s\n" "${packages_to_update[@]}" > "$SESSION_LOG.packages"
  
  return 0
}

# ============================================================================
# Step 3: Review
# ============================================================================

step_review_packages() {
  if [[ "$REVIEW_MODE" != "true" ]]; then
    log_session INFO "Step 3: Skipping review (not requested)"
    return 0
  fi
  
  log_session INFO "Step 3: Reviewing PKGBUILDs..."
  
  local -a packages=()
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && packages+=("$pkg")
  done < "$SESSION_LOG.packages"
  
  local rejected=0
  local pkg=""
  
  for pkg in "${packages[@]}"; do
    local pkg_dir="$BUILD_ROOT/$pkg"
    
    if [[ ! -d "$pkg_dir" ]]; then
      log_session WARNING "Package directory not found: $pkg_dir"
      continue
    fi
    
    echo ""
    log_session INFO "Reviewing: $pkg"
    
    if ! "$SCRIPT_DIR/review-pkgbuild.sh" "$pkg_dir"; then
      log_session WARNING "PKGBUILD rejected: $pkg"
      ((rejected++))
      
      # Remove from update list
      sed -i "/^${pkg}$/d" "$SESSION_LOG.packages"
    fi
  done
  
  if [[ $rejected -gt 0 ]]; then
    log_session WARNING "$rejected package(s) rejected during review"
    
    # Check if any packages remain
    if [[ ! -s "$SESSION_LOG.packages" ]]; then
      log_session INFO "No packages approved for update"
      return 1
    fi
  fi
  
  log_session SUCCESS "Review complete"
}

# ============================================================================
# Step 4: Resolve Dependencies
# ============================================================================

step_resolve_dependencies() {
  log_session INFO "Step 4: Resolving dependencies..."
  
  local -a packages=()
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && packages+=("$pkg")
  done < "$SESSION_LOG.packages"
  
  if [[ ${#packages[@]} -eq 0 ]]; then
    return 0
  fi
  
  # Resolve dependencies for all packages
  local all_deps=""
  if ! all_deps=$("$SCRIPT_DIR/resolve-deps.sh" --import --build-order "${packages[@]}" 2>&1); then
    log_session ERROR "Dependency resolution failed"
    return 1
  fi
  
  # Save build order
  echo "$all_deps" > "$SESSION_LOG.build-order"
  
  log_session SUCCESS "Dependencies resolved and imported"
}

# ============================================================================
# Step 5: Build Packages
# ============================================================================

step_build_packages() {
  log_session INFO "Step 5: Building packages..."
  
  if [[ ! -f "$SESSION_LOG.build-order" ]]; then
    log_session ERROR "Build order file not found"
    return 1
  fi
  
  local -a build_order=()
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && build_order+=("$pkg")
  done < "$SESSION_LOG.build-order"
  
  if [[ ${#build_order[@]} -eq 0 ]]; then
    log_session WARNING "No packages to build"
    return 0
  fi
  
  log_session INFO "Building ${#build_order[@]} package(s) in order..."
  
  local built=0
  local failed=0
  local pkg=""
  
  for pkg in "${build_order[@]}"; do
    log_session INFO "Building: $pkg"
    
    local -a build_args=("$pkg" "--no-prompt" "--repo" "$REPO_DIR")
    
    if [[ "$CHROOT_MODE" == "true" ]]; then
      build_args+=("--chroot")
    fi
    
    if "$SCRIPT_DIR/update-pkg.sh" "${build_args[@]}" >> "$SESSION_LOG" 2>&1; then
      log_session SUCCESS "Built: $pkg"
      ((built++))
    else
      log_session ERROR "Build failed: $pkg"
      ((failed++))
    fi
  done
  
  log_session INFO "Build summary: $built succeeded, $failed failed"
  
  if [[ $failed -gt 0 ]]; then
    log_session WARNING "Some builds failed (see log: $SESSION_LOG)"
  fi
  
  if [[ $built -eq 0 ]]; then
    return 1
  fi
}

# ============================================================================
# Step 6: Update Repository
# ============================================================================

step_update_repository() {
  log_session INFO "Step 6: Syncing pacman repository..."
  
  if ! sudo pacman -Sy; then
    log_session ERROR "Failed to sync repository"
    return 1
  fi
  
  log_session SUCCESS "Repository synced"
}

# ============================================================================
# Step 7: Install Updates
# ============================================================================

step_install_updates() {
  if [[ "$NO_INSTALL" == "true" ]]; then
    log_session INFO "Step 7: Skipping install (--no-install)"
    return 0
  fi
  
  log_session INFO "Step 7: Installing updates..."
  
  echo ""
  log_info "Running: sudo pacman -Syu"
  echo ""
  
  if ! sudo pacman -Syu; then
    log_session ERROR "Installation failed"
    return 1
  fi
  
  log_session SUCCESS "Updates installed"
}

# ============================================================================
# Cleanup
# ============================================================================

cleanup_session() {
  # Clean up temporary files
  rm -f "$SESSION_LOG.packages" "$SESSION_LOG.build-order" 2>/dev/null || true
}

# ============================================================================
# Main Workflow
# ============================================================================

run_workflow() {
  log_session INFO "=== Sync-All Workflow Started ==="
  log_session INFO "Session log: $SESSION_LOG"
  
  local step_failed="false"
  
  # Step 1: Check news
  step_check_news || step_failed="true"
  
  if [[ "$step_failed" == "true" ]]; then
    return 1
  fi
  
  # Step 2: Detect updates
  if ! step_detect_updates; then
    # No updates available
    return 0
  fi
  
  # Step 3: Review (if requested)
  if ! step_review_packages; then
    # User rejected all packages
    return 0
  fi
  
  # Step 4: Resolve dependencies
  step_resolve_dependencies || step_failed="true"
  
  if [[ "$step_failed" == "true" ]]; then
    log_session ERROR "Workflow failed at dependency resolution"
    return 1
  fi
  
  # Step 5: Build packages
  step_build_packages || step_failed="true"
  
  if [[ "$step_failed" == "true" ]]; then
    log_session WARNING "Workflow completed with build failures"
  fi
  
  # Step 6: Update repository
  step_update_repository
  
  # Step 7: Install updates
  step_install_updates
  
  log_session INFO "=== Sync-All Workflow Complete ==="
  
  echo ""
  log_info "Session log saved to: $SESSION_LOG"
}

# ============================================================================
# Main
# ============================================================================

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --review) REVIEW_MODE="true"; shift ;;
      --chroot) CHROOT_MODE="true"; shift ;;
      --no-install) NO_INSTALL="true"; shift ;;
      --skip-news) CHECK_NEWS="false"; shift ;;
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

main() {
  parse_args "$@"
  
  # Setup trap for cleanup
  trap cleanup_session EXIT
  
  # Ensure log directory exists
  mkdir -p "$LOG_DIR"
  
  # Run workflow
  run_workflow
}

main "$@"