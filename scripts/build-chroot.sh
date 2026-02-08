#!/usr/bin/env bash
set -uo pipefail

# build-chroot.sh - Build packages in clean chroot
#
# Uses devtools (arch-nspawn) to build packages in isolation,
# ensuring clean and reproducible builds.
#
# Examples:
#   ./build-chroot.sh ktailctl                    # Build in chroot
#   ./build-chroot.sh ktailctl --update           # Update chroot first
#   ./build-chroot.sh ktailctl --repo custom      # Include custom repo

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ============================================================================
# Options
# ============================================================================

declare PACKAGE_DIR=""
declare UPDATE_CHROOT="false"
declare CLEAN_FIRST="false"
declare BIND_REPO="true"

show_usage() {
  cat <<EOF
Usage: $0 <package-dir> [OPTIONS]

Build package in a clean chroot for reproducibility.

REQUIREMENTS:
  - devtools package (provides arch-nspawn, makechrootpkg)
  - Root access (for chroot operations)

OPTIONS:
  --update            Update chroot before building
  --clean             Remove chroot and rebuild
  --no-bind-repo      Don't bind local repo into chroot
  -h, --help          Show this help

CHROOT LOCATION:
  $CHROOT_DIR

EXAMPLES:
  # Build package in chroot
  $0 ktailctl

  # Update chroot first, then build
  $0 ktailctl --update

  # Clean rebuild of chroot
  $0 ktailctl --clean
EOF
}

# ============================================================================
# Dependency Checking
# ============================================================================

check_deps() {
  if [[ "$HAS_DEVTOOLS" != "true" ]]; then
    log_error "devtools not installed (provides arch-nspawn, makechrootpkg)"
    log_info "Install with: sudo pacman -S devtools"
    exit 1
  fi
  
  if [[ "$EUID" -ne 0 ]] && ! sudo -n true 2>/dev/null; then
    log_error "This script requires sudo access for chroot operations"
    exit 1
  fi
}

# ============================================================================
# Chroot Management
# ============================================================================

init_chroot() {
  local chroot_dir="$CHROOT_DIR"
  
  if [[ -d "$chroot_dir/root" ]]; then
    log_info "Chroot already exists: $chroot_dir"
    return 0
  fi
  
  log_info "Creating chroot: $chroot_dir"
  
  # Create base chroot
  if ! sudo mkarchroot "$chroot_dir/root" base-devel; then
    log_error "Failed to create chroot"
    return 1
  fi
  
  log_success "Chroot created"
}

update_chroot() {
  local chroot_dir="$CHROOT_DIR"
  
  if [[ ! -d "$chroot_dir/root" ]]; then
    log_error "Chroot not initialized"
    return 1
  fi
  
  log_info "Updating chroot..."
  
  if ! sudo arch-nspawn "$chroot_dir/root" pacman -Syu --noconfirm; then
    log_error "Failed to update chroot"
    return 1
  fi
  
  log_success "Chroot updated"
}

clean_chroot() {
  local chroot_dir="$CHROOT_DIR"
  
  if [[ ! -d "$chroot_dir" ]]; then
    log_info "Chroot doesn't exist, nothing to clean"
    return 0
  fi
  
  log_warning "Removing chroot: $chroot_dir"
  
  if ! sudo rm -rf "$chroot_dir"; then
    log_error "Failed to remove chroot"
    return 1
  fi
  
  log_success "Chroot removed"
}

# ============================================================================
# Repository Binding
# ============================================================================

setup_repo_bind() {
  local chroot_dir="$CHROOT_DIR"
  
  if [[ ! -d "$REPO_DIR" ]]; then
    log_warning "Local repo not found: $REPO_DIR"
    return 1
  fi
  
  # Create pacman.conf with local repo
  local chroot_pacman_conf="$chroot_dir/pacman.conf"
  
  log_info "Configuring chroot to use local repo..."
  
  # Copy base pacman.conf from chroot
  sudo cp "$chroot_dir/root/etc/pacman.conf" "$chroot_pacman_conf"
  
  # Add local repo (before core repos for priority)
  sudo tee -a "$chroot_pacman_conf" >/dev/null <<EOF

[$REPO_NAME]
SigLevel = Optional TrustAll
Server = file:///repo
EOF
  
  log_success "Chroot pacman.conf configured"
}

# ============================================================================
# Build Process
# ============================================================================

build_in_chroot() {
  local pkg_dir="$PACKAGE_DIR"
  local pkgname="$(basename "$pkg_dir")"
  
  if [[ ! -f "$pkg_dir/PKGBUILD" ]]; then
    log_error "PKGBUILD not found in: $pkg_dir"
    return 1
  fi
  
  log_info "Building $pkgname in chroot..."
  
  # Prepare chroot
  if [[ "$CLEAN_FIRST" == "true" ]]; then
    clean_chroot || return 1
    init_chroot || return 1
  elif [[ ! -d "$CHROOT_DIR/root" ]]; then
    init_chroot || return 1
  fi
  
  if [[ "$UPDATE_CHROOT" == "true" ]]; then
    update_chroot || return 1
  fi
  
  # Setup repo binding if requested
  local makechrootpkg_args=()
  if [[ "$BIND_REPO" == "true" ]]; then
    setup_repo_bind
    makechrootpkg_args+=(-D "$REPO_DIR:/repo")
    makechrootpkg_args+=(-C "$CHROOT_DIR/pacman.conf")
  fi
  
  # Build
  log_info "Starting build (this may take a while)..."
  
  (
    cd "$pkg_dir"
    
    if ! sudo makechrootpkg -c -r "$CHROOT_DIR" "${makechrootpkg_args[@]}"; then
      log_error "Build failed in chroot"
      exit 1
    fi
  )
  
  local build_status=$?
  
  if [[ $build_status -ne 0 ]]; then
    log_error "Chroot build failed for: $pkgname"
    return 1
  fi
  
  log_success "Built successfully: $pkgname"
  
  # Show built packages
  local -a built_pkgs=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && built_pkgs+=("$f")
  done < <(find "$pkg_dir" -maxdepth 1 -name "*.pkg.tar.*" -newer "$pkg_dir/PKGBUILD" 2>/dev/null)
  
  if [[ ${#built_pkgs[@]} -gt 0 ]]; then
    log_info "Built packages:"
    for pkg in "${built_pkgs[@]}"; do
      echo "  - $(basename "$pkg")"
    done
  fi
}

# ============================================================================
# Main
# ============================================================================

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --update) UPDATE_CHROOT="true"; shift ;;
      --clean) CLEAN_FIRST="true"; shift ;;
      --no-bind-repo) BIND_REPO="false"; shift ;;
      -h|--help) show_usage; exit 0 ;;
      -*)
        log_error "Unknown option: $1"
        show_usage
        exit 1
        ;;
      *)
        if [[ -z "$PACKAGE_DIR" ]]; then
          PACKAGE_DIR="$1"
        else
          log_error "Multiple package directories specified"
          show_usage
          exit 1
        fi
        shift
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  check_deps
  
  if [[ -z "$PACKAGE_DIR" ]]; then
    log_error "No package directory specified"
    show_usage
    exit 1
  fi
  
  # Make path absolute
  PACKAGE_DIR="$(cd "$PACKAGE_DIR" 2>/dev/null && pwd)" || {
    log_error "Failed to resolve package directory: $PACKAGE_DIR"
    exit 1
  }
  
  build_in_chroot
}

main "$@"