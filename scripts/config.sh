#!/usr/bin/env bash
# config.sh - Central configuration for package management scripts
# Source this file in all scripts: source "$(dirname "$0")/config.sh"

# Prevent multiple sourcing
[[ -n "${PKG_MGMT_CONFIG_LOADED:-}" ]] && return 0
declare -gr PKG_MGMT_CONFIG_LOADED=1

# ============================================================================
# Core Paths
# ============================================================================

# Build root - where all package directories live
declare -r BUILD_ROOT="${BUILD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Feeds configuration
declare -r FEEDS_JSON="${FEEDS_JSON:-$BUILD_ROOT/feeds.json}"

# Match aurutils convention for consistency
declare -r AURDEST="$BUILD_ROOT"

# ============================================================================
# Repository Configuration
# ============================================================================

# Local repository name
declare -r REPO_NAME="${REPO_NAME:-custom}"

# Repository directory
declare -r REPO_DIR="${REPO_DIR:-/var/cache/pacman/$REPO_NAME}"

# Repository database file
declare -r REPO_DB="$REPO_DIR/$REPO_NAME.db.tar.gz"

# Repository files database (optional)
declare -r REPO_FILES="$REPO_DIR/$REPO_NAME.files.tar.gz"

# ============================================================================
# Build Configuration
# ============================================================================

# Chroot directory for clean builds
declare -r CHROOT_DIR="${CHROOT_DIR:-$HOME/.cache/pkg-mgmt/chroot}"

# Default makepkg flags (can be overridden)
declare -r MAKEPKG_FLAGS="${MAKEPKG_FLAGS:--scf --noconfirm --needed}"

# Sign packages by default?
declare -r SIGN_PACKAGES="${SIGN_PACKAGES:-false}"

# GPG key for signing (if enabled)
declare -r SIGN_KEY="${SIGN_KEY:-}"

# ============================================================================
# Review & Tracking
# ============================================================================

# Review state directory
declare -r REVIEW_STATE="${REVIEW_STATE:-$HOME/.local/share/pkg-mgmt/reviewed}"

# Editor for reviewing PKGBUILDs
declare -r REVIEW_EDITOR="${REVIEW_EDITOR:-${EDITOR:-vim}}"

# Pager for viewing diffs
declare -r REVIEW_PAGER="${REVIEW_PAGER:-${PAGER:-less}}"

# Use bat for syntax highlighting if available
declare -r USE_BAT="${USE_BAT:-auto}"

# ============================================================================
# Lock & State Management
# ============================================================================

# Lock file directory
declare -r LOCK_DIR="${LOCK_DIR:-/tmp/pkg-mgmt-locks}"

# Lock timeout in seconds
declare -r LOCK_TIMEOUT="${LOCK_TIMEOUT:-300}"

# Log directory
declare -r LOG_DIR="${LOG_DIR:-$HOME/.cache/pkg-mgmt/logs}"

# ============================================================================
# Feature Flags
# ============================================================================

# Enable chroot builds by default?
declare -r ENABLE_CHROOT="${ENABLE_CHROOT:-false}"

# Enable PKGBUILD review by default?
declare -r ENABLE_REVIEW="${ENABLE_REVIEW:-true}"

# Check Arch news before upgrades?
declare -r ENABLE_NEWS_CHECK="${ENABLE_NEWS_CHECK:-true}"

# Automatically resolve and import AUR dependencies?
declare -r AUTO_RESOLVE_DEPS="${AUTO_RESOLVE_DEPS:-true}"

# Use aur-vercmp for version comparison if available?
declare -r USE_AUR_VERCMP="${USE_AUR_VERCMP:-true}"

# ============================================================================
# External Tools
# ============================================================================

# Check for optional tools
declare -r HAS_AURUTILS="$(command -v aur >/dev/null 2>&1 && echo true || echo false)"
declare -r HAS_PARU="$(command -v paru >/dev/null 2>&1 && echo true || echo false)"
declare -r HAS_BAT="$(command -v bat >/dev/null 2>&1 && echo true || echo false)"
declare -r HAS_DEVTOOLS="$(command -v arch-nspawn >/dev/null 2>&1 && echo true || echo false)"

# ============================================================================
# Logging Colors
# ============================================================================

declare -r RED='\033[0;31m'
declare -r GREEN='\033[0;32m'
declare -r YELLOW='\033[1;33m'
declare -r BLUE='\033[0;34m'
declare -r MAGENTA='\033[0;35m'
declare -r CYAN='\033[0;36m'
declare -r NC='\033[0m'

# ============================================================================
# Helper Functions
# ============================================================================

log_debug() { 
  [[ "${DEBUG:-false}" == "true" ]] && echo -e "${CYAN}[DEBUG]${NC} $*" >&2
}

log_info() { 
  echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() { 
  echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_warning() { 
  echo -e "${YELLOW}[WARNING]${NC} $*" >&2
}

log_error() { 
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Ensure directories exist
ensure_dirs() {
  mkdir -p "$LOCK_DIR" "$LOG_DIR" "$REVIEW_STATE" 2>/dev/null || true
}

# Initialize on load
ensure_dirs