#!/usr/bin/env bash
set -uo pipefail

# install-updates.sh - SIMPLIFIED: Install from staged artifacts or repo
#
# OLD BEHAVIOR: Built packages AND installed them (too much)
# NEW BEHAVIOR: Only installs pre-built packages (one job)
#
# This script assumes packages are ALREADY built by build-packages.sh
# and staged in ~/.cache/pkg-mgmt/staging/ OR in the local repo
#
# Examples:
#   ./install-updates.sh --from-staging      # Install staged artifacts
#   ./install-updates.sh --from-repo         # Install from custom repo
#   ./install-updates.sh --auto              # Auto-detect best source

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ============================================================================
# Configuration
# ============================================================================

declare -r STAGING_DIR="${STAGING_DIR:-$HOME/.cache/pkg-mgmt/staging}"

# ============================================================================
# Options
# ============================================================================

declare INSTALL_FROM="auto"  # auto | staging | repo
declare DRY_RUN="false"
declare SPECIFIC_PACKAGES=()

show_usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [packages...]

Install pre-built packages from staging area or local repository.

NOTE: This script does NOT build packages.
      Use build-packages.sh first, then install.

OPTIONS:
  --from-staging      Install from staging area ($STAGING_DIR)
  --from-repo         Install from local repository (pacman -S custom/pkg)
  --auto              Auto-detect (staging first, then repo) [default]
  --dry-run           Show what would be installed
  -h, --help          Show this help

WORKFLOW:
  1. build-packages.sh ktailctl ollama    # Build packages
  2. ./install-updates.sh                 # Install built packages

  OR:

  1. build-packages.sh --all              # Build everything
  2. repo-mgmt.sh add staging/*.pkg.tar.zst   # Add to repo
  3. sudo pacman -Syu                     # Install from repo

EXAMPLES:
  # Install from staging
  $0 --from-staging

  # Install specific packages from repo
  $0 --from-repo ktailctl ollama

  # Auto-detect best source
  $0
EOF
}

# ============================================================================
# Package Discovery
# ============================================================================

get_installed_packages() {
  pacman -Qq 2>/dev/null
}

find_staged_packages() {
  if [[ ! -d "$STAGING_DIR" ]]; then
    return 0
  fi
  
  find "$STAGING_DIR" -maxdepth 1 -name "*.pkg.tar.*" -type f 2>/dev/null
}

extract_pkgname_from_file() {
  local file="$1"
  local basename="$(basename "$file")"
  
  # Extract pkgname from filename: pkgname-version-arch.pkg.tar.zst
  # This is fragile but works for most cases
  echo "$basename" | sed -E 's/-[0-9].+$//'
}

get_repo_packages() {
  if [[ ! -f "$REPO_DB" ]]; then
    return 0
  fi
  
  bsdtar -xOf "$REPO_DB" 2>/dev/null | awk '/^%NAME%$/ { getline; print }'
}

# ============================================================================
# Installation
# ============================================================================

install_from_staging() {
  local -a pkg_files=()
  
  if [[ ${#SPECIFIC_PACKAGES[@]} -gt 0 ]]; then
    # Install specific packages
    local pkg=""
    for pkg in "${SPECIFIC_PACKAGES[@]}"; do
      local -a matches=()
      while IFS= read -r f; do
        [[ -n "$f" ]] && matches+=("$f")
      done < <(find "$STAGING_DIR" -maxdepth 1 -name "${pkg}-*.pkg.tar.*" -type f 2>/dev/null)
      
      if [[ ${#matches[@]} -eq 0 ]]; then
        log_error "No staged package found for: $pkg"
        continue
      fi
      
      # Get newest if multiple matches
      local newest=""
      newest=$(ls -t "${matches[@]}" | head -1)
      pkg_files+=("$newest")
    done
  else
    # Install all staged packages
    while IFS= read -r f; do
      [[ -n "$f" ]] && pkg_files+=("$f")
    done < <(find_staged_packages)
  fi
  
  if [[ ${#pkg_files[@]} -eq 0 ]]; then
    log_warning "No packages found in staging area"
    return 1
  fi
  
  log_info "Installing ${#pkg_files[@]} package(s) from staging..."
  
  for f in "${pkg_files[@]}"; do
    log_info "  - $(basename "$f")"
  done
  
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "DRY-RUN: Would run: sudo pacman -U ${pkg_files[*]}"
    return 0
  fi
  
  # Use pacman -U to install from files
  echo ""
  if ! sudo pacman -U --needed "${pkg_files[@]}"; then
    log_error "Installation failed"
    return 1
  fi
  
  log_success "Installation complete"
  
  # Optionally clean staging after successful install
  read -p "Remove installed packages from staging? [y/N]: " -n 1 -r
  echo ""
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    for f in "${pkg_files[@]}"; do
      rm -f "$f"
      log_info "Removed: $(basename "$f")"
    done
  fi
}

install_from_repo() {
  local -a pkg_names=()
  
  if [[ ${#SPECIFIC_PACKAGES[@]} -gt 0 ]]; then
    pkg_names=("${SPECIFIC_PACKAGES[@]}")
  else
    # Get all packages from repo that are also installed
    local -a installed=()
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] && installed+=("$pkg")
    done < <(get_installed_packages)
    
    local -a repo_pkgs=()
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] && repo_pkgs+=("$pkg")
    done < <(get_repo_packages)
    
    # Intersect: packages in repo AND installed
    for pkg in "${repo_pkgs[@]}"; do
      if [[ " ${installed[*]} " =~ " ${pkg} " ]]; then
        pkg_names+=("$pkg")
      fi
    done
  fi
  
  if [[ ${#pkg_names[@]} -eq 0 ]]; then
    log_warning "No packages to install from repository"
    return 1
  fi
  
  log_info "Installing ${#pkg_names[@]} package(s) from repository..."
  
  # Prefix with repo name for explicit repo selection
  local -a repo_refs=()
  for pkg in "${pkg_names[@]}"; do
    repo_refs+=("$REPO_NAME/$pkg")
    log_info "  - $pkg"
  done
  
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "DRY-RUN: Would run: sudo pacman -S ${repo_refs[*]}"
    return 0
  fi
  
  # Use pacman -S with repo prefix
  echo ""
  if ! sudo pacman -S --needed "${repo_refs[@]}"; then
    log_error "Installation failed"
    return 1
  fi
  
  log_success "Installation complete"
}

install_auto() {
  # Try staging first, then fall back to repo
  
  log_info "Auto-detecting installation source..."
  
  local -a staged=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && staged+=("$f")
  done < <(find_staged_packages)
  
  if [[ ${#staged[@]} -gt 0 ]]; then
    log_info "Found ${#staged[@]} package(s) in staging"
    install_from_staging
  elif [[ -f "$REPO_DB" ]]; then
    log_info "No staged packages, using repository"
    install_from_repo
  else
    log_error "No installation source found"
    log_info "Build packages first: build-packages.sh --all"
    return 1
  fi
}

# ============================================================================
# Main
# ============================================================================

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from-staging) INSTALL_FROM="staging"; shift ;;
      --from-repo) INSTALL_FROM="repo"; shift ;;
      --auto) INSTALL_FROM="auto"; shift ;;
      --dry-run) DRY_RUN="true"; shift ;;
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
  
  case "$INSTALL_FROM" in
    staging)
      install_from_staging
      ;;
    repo)
      install_from_repo
      ;;
    auto)
      install_auto
      ;;
    *)
      log_error "Invalid installation source: $INSTALL_FROM"
      exit 1
      ;;
  esac
}

main "$@"