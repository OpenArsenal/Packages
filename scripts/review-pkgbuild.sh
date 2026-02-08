#!/usr/bin/env bash
set -uo pipefail

# review-pkgbuild.sh - Review PKGBUILDs with diff tracking
#
# Shows diffs since last review, allows viewing in editor,
# tracks reviewed commits for future reference.
#
# Examples:
#   ./review-pkgbuild.sh ktailctl              # Review package
#   ./review-pkgbuild.sh ktailctl --comments   # Include AUR comments
#   ./review-pkgbuild.sh ktailctl --force      # Review even if no changes

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ============================================================================
# Options
# ============================================================================

declare PACKAGE_DIR=""
declare SHOW_COMMENTS="false"
declare FORCE_REVIEW="false"
declare AUTO_APPROVE="false"

show_usage() {
  cat <<EOF
Usage: $0 <package-dir> [OPTIONS]

Review PKGBUILD with diff tracking and approval workflow.

OPTIONS:
  --comments          Show AUR comments
  --force             Review even if no changes since last review
  --auto-approve      Skip interactive approval (just track)
  -h, --help          Show this help

EXIT CODES:
  0 - Approved (or already reviewed with no changes)
  1 - Rejected
  2 - Error

EXAMPLES:
  # Review package
  $0 ktailctl

  # Review with AUR comments
  $0 ktailctl --comments

  # Force re-review
  $0 ktailctl --force
EOF
}

# ============================================================================
# Dependency Checking
# ============================================================================

check_deps() {
  local -a missing=()
  
  command -v git >/dev/null 2>&1 || missing+=("git")
  
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing dependencies: ${missing[*]}"
    exit 2
  fi
}

# ============================================================================
# Review State Management
# ============================================================================

get_reviewed_commit() {
  local pkg="$1"
  local state_file="$REVIEW_STATE/$pkg"
  
  if [[ -f "$state_file" ]]; then
    cat "$state_file"
  else
    echo ""
  fi
}

set_reviewed_commit() {
  local pkg="$1"
  local commit="$2"
  
  mkdir -p "$REVIEW_STATE"
  echo "$commit" > "$REVIEW_STATE/$pkg"
}

# ============================================================================
# Git Integration
# ============================================================================

ensure_git_repo() {
  local dir="$1"
  
  if [[ ! -d "$dir/.git" ]]; then
    log_info "Initializing git repo for diff tracking..."
    (
      cd "$dir"
      git init -q
      git add .
      git commit -q -m "Initial import"
    ) >/dev/null 2>&1
  fi
}

get_current_commit() {
  local dir="$1"
  (cd "$dir" && git rev-parse HEAD 2>/dev/null) || echo ""
}

has_uncommitted_changes() {
  local dir="$1"
  (cd "$dir" && ! git diff-index --quiet HEAD -- 2>/dev/null)
}

commit_current_state() {
  local dir="$1"
  local msg="$2"
  
  (
    cd "$dir"
    git add .
    git commit -q -m "$msg" 2>/dev/null || true
  )
}

# ============================================================================
# PKGBUILD Display
# ============================================================================

show_pkgbuild() {
  local file="$1"
  
  if [[ "$USE_BAT" == "true" || "$USE_BAT" == "auto" ]] && [[ "$HAS_BAT" == "true" ]]; then
    bat --style=numbers --color=always --language=bash "$file" 2>/dev/null || cat "$file"
  else
    cat "$file"
  fi
}

show_diff() {
  local dir="$1"
  local from_commit="$2"
  local file="${3:-PKGBUILD}"
  
  if [[ -z "$from_commit" ]]; then
    log_info "No previous review found, showing full PKGBUILD"
    show_pkgbuild "$dir/$file"
    return 0
  fi
  
  local diff_output=""
  diff_output=$(cd "$dir" && git diff "$from_commit" HEAD -- "$file" 2>/dev/null) || {
    log_warning "Could not generate diff from $from_commit"
    show_pkgbuild "$dir/$file"
    return 0
  }
  
  if [[ -z "$diff_output" ]]; then
    log_info "No changes to $file since last review"
    return 0
  fi
  
  if [[ "$USE_BAT" == "true" || "$USE_BAT" == "auto" ]] && [[ "$HAS_BAT" == "true" ]]; then
    echo "$diff_output" | bat --style=plain --color=always --language=diff 2>/dev/null || echo "$diff_output"
  else
    echo "$diff_output"
  fi
}

# ============================================================================
# AUR Comments
# ============================================================================

fetch_aur_comments() {
  local pkgname="$1"
  
  if ! command -v curl >/dev/null 2>&1; then
    log_warning "curl not available, skipping comments"
    return 1
  fi
  
  log_info "Fetching AUR comments for $pkgname..."
  
  # Use AUR RPC to get package ID, then fetch comments
  local pkg_info=""
  pkg_info=$(curl -sf "https://aur.archlinux.org/rpc?v=5&type=info&arg=${pkgname}" 2>/dev/null) || {
    log_warning "Failed to fetch package info"
    return 1
  }
  
  local pkg_id=""
  pkg_id=$(echo "$pkg_info" | jq -r '.results[0].ID // empty' 2>/dev/null)
  
  if [[ -z "$pkg_id" ]]; then
    log_warning "Package not found on AUR"
    return 1
  fi
  
  # Fetch comments page and parse
  local comments=""
  comments=$(curl -sf "https://aur.archlinux.org/packages/${pkgname}/" 2>/dev/null) || {
    log_warning "Failed to fetch comments page"
    return 1
  }
  
  # Simple extraction (this is fragile but works for basic cases)
  local comment_count=0
  comment_count=$(echo "$comments" | grep -c 'class="comments"' || echo 0)
  
  if [[ $comment_count -eq 0 ]]; then
    log_info "No comments found"
    return 0
  fi
  
  log_info "Found $comment_count comment(s)"
  echo ""
  echo "=== AUR COMMENTS ==="
  echo ""
  
  # For proper comment parsing, we'd need html parsing
  # For now, suggest using paru if available
  if [[ "$HAS_PARU" == "true" ]]; then
    paru -Gc "$pkgname" 2>/dev/null || log_warning "paru comment fetch failed"
  else
    echo "Install paru for better comment viewing: paru -Gc $pkgname"
  fi
}

# ============================================================================
# Interactive Review
# ============================================================================

prompt_approval() {
  local pkg="$1"
  
  if [[ "$AUTO_APPROVE" == "true" ]]; then
    return 0
  fi
  
  local response=""
  while true; do
    read -p "Approve this PKGBUILD? [y]es/[n]o/[e]dit/[q]uit: " -n 1 -r response
    echo ""
    
    case "${response,,}" in
      y|"")
        log_success "PKGBUILD approved"
        return 0
        ;;
      n)
        log_warning "PKGBUILD rejected"
        return 1
        ;;
      e)
        "${REVIEW_EDITOR}" "$PACKAGE_DIR/PKGBUILD"
        # After editing, show diff again
        echo ""
        log_info "Changes made in editor:"
        (cd "$PACKAGE_DIR" && git diff PKGBUILD)
        echo ""
        ;;
      q)
        log_error "Review aborted"
        exit 1
        ;;
      *)
        echo "Invalid choice. Please enter y, n, e, or q."
        ;;
    esac
  done
}

# ============================================================================
# Main Review Flow
# ============================================================================

review_package() {
  local pkg_dir="$PACKAGE_DIR"
  local pkgname="$(basename "$pkg_dir")"
  
  if [[ ! -d "$pkg_dir" ]]; then
    log_error "Package directory not found: $pkg_dir"
    exit 2
  fi
  
  if [[ ! -f "$pkg_dir/PKGBUILD" ]]; then
    log_error "PKGBUILD not found in: $pkg_dir"
    exit 2
  fi
  
  log_info "Reviewing: $pkgname"
  
  # Ensure git repo exists for tracking
  ensure_git_repo "$pkg_dir"
  
  # Commit any uncommitted changes first
  if has_uncommitted_changes "$pkg_dir"; then
    log_info "Committing current state for diff tracking..."
    commit_current_state "$pkg_dir" "Pre-review snapshot"
  fi
  
  # Get current commit
  local current_commit=""
  current_commit=$(get_current_commit "$pkg_dir")
  
  if [[ -z "$current_commit" ]]; then
    log_error "Failed to get current git commit"
    exit 2
  fi
  
  # Get last reviewed commit
  local last_reviewed=""
  last_reviewed=$(get_reviewed_commit "$pkgname")
  
  # Check if review needed
  if [[ -n "$last_reviewed" && "$last_reviewed" == "$current_commit" && "$FORCE_REVIEW" != "true" ]]; then
    log_success "Already reviewed at commit $current_commit (use --force to re-review)"
    return 0
  fi
  
  # Show diff
  echo ""
  echo "=== PKGBUILD DIFF ==="
  echo ""
  show_diff "$pkg_dir" "$last_reviewed" "PKGBUILD"
  echo ""
  
  # Show .SRCINFO diff if exists
  if [[ -f "$pkg_dir/.SRCINFO" ]]; then
    echo ""
    echo "=== .SRCINFO DIFF ==="
    echo ""
    show_diff "$pkg_dir" "$last_reviewed" ".SRCINFO"
    echo ""
  fi
  
  # Show install script diff if exists
  local install_script=""
  install_script=$(grep -m1 '^install=' "$pkg_dir/PKGBUILD" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "")
  if [[ -n "$install_script" && -f "$pkg_dir/$install_script" ]]; then
    echo ""
    echo "=== INSTALL SCRIPT DIFF ==="
    echo ""
    show_diff "$pkg_dir" "$last_reviewed" "$install_script"
    echo ""
  fi
  
  # Fetch AUR comments if requested
  if [[ "$SHOW_COMMENTS" == "true" ]]; then
    echo ""
    fetch_aur_comments "$pkgname"
    echo ""
  fi
  
  # Prompt for approval
  if ! prompt_approval "$pkgname"; then
    return 1
  fi
  
  # Record approval
  set_reviewed_commit "$pkgname" "$current_commit"
  log_success "Review recorded for commit: $current_commit"
  
  return 0
}

# ============================================================================
# Main
# ============================================================================

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --comments) SHOW_COMMENTS="true"; shift ;;
      --force) FORCE_REVIEW="true"; shift ;;
      --auto-approve) AUTO_APPROVE="true"; shift ;;
      -h|--help) show_usage; exit 0 ;;
      -*)
        log_error "Unknown option: $1"
        show_usage
        exit 2
        ;;
      *)
        if [[ -z "$PACKAGE_DIR" ]]; then
          PACKAGE_DIR="$1"
        else
          log_error "Multiple package directories specified"
          show_usage
          exit 2
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
    exit 2
  fi
  
  # Make path absolute
  PACKAGE_DIR="$(cd "$PACKAGE_DIR" 2>/dev/null && pwd)" || {
    log_error "Failed to resolve package directory: $PACKAGE_DIR"
    exit 2
  }
  
  review_package
}

main "$@"