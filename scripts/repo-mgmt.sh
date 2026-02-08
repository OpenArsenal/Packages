#!/usr/bin/env bash
set -uo pipefail

# repo-mgmt.sh - Manage local pacman repository
#
# Handles all repository operations: initialization, adding packages,
# removal, listing, cleanup, and verification.
#
# Examples:
#   ./repo-mgmt.sh init                          # Initialize repo
#   ./repo-mgmt.sh add package.pkg.tar.zst       # Add package
#   ./repo-mgmt.sh remove ktailctl               # Remove package
#   ./repo-mgmt.sh list --upgrades               # List upgradable packages
#   ./repo-mgmt.sh cleanup --keep-n 2            # Keep only 2 versions

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ============================================================================
# Global Options
# ============================================================================

declare DRY_RUN="false"
declare VERBOSE="false"

# ============================================================================
# Usage
# ============================================================================

show_usage() {
  cat <<EOF
Usage: $0 <command> [options]

Manage local pacman repository at: $REPO_DIR

COMMANDS:
  init [path]                 Initialize repository (creates DB)
  add <pkg.tar.zst> [...]     Add package(s) to repository
  remove <pkgname> [...]      Remove package(s) from repository
  list [--upgrades]           List packages (or just upgradable)
  cleanup [--keep-n N]        Remove old package versions
  verify                      Verify repository consistency
  status                      Show repository statistics

GLOBAL OPTIONS:
  --dry-run                   Show what would happen
  --verbose                   Extra logging
  -h, --help                  Show this help

EXAMPLES:
  # Initialize repository
  $0 init

  # Add newly built packages
  $0 add google-chrome-*.pkg.tar.zst

  # List packages needing upgrades
  $0 list --upgrades

  # Keep only latest 2 versions of each package
  $0 cleanup --keep-n 2

  # Verify repo integrity
  $0 verify
EOF
}

# ============================================================================
# Repository Initialization
# ============================================================================

cmd_init() {
  local repo_path="${1:-$REPO_DIR}"
  
  log_info "Initializing repository at: $repo_path"
  
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "DRY-RUN: Would create directory: $repo_path"
    log_info "DRY-RUN: Would create database: $repo_path/$REPO_NAME.db.tar.gz"
    return 0
  fi
  
  # Create directory
  if [[ ! -d "$repo_path" ]]; then
    if ! mkdir -p "$repo_path"; then
      log_error "Failed to create directory: $repo_path"
      return 1
    fi
    log_success "Created directory: $repo_path"
  else
    log_info "Directory already exists: $repo_path"
  fi
  
  # Create empty database if doesn't exist
  local db_file="$repo_path/$REPO_NAME.db.tar.gz"
  if [[ ! -f "$db_file" ]]; then
    if ! repo-add "$db_file" >/dev/null 2>&1; then
      log_error "Failed to create database: $db_file"
      return 1
    fi
    log_success "Created database: $db_file"
  else
    log_info "Database already exists: $db_file"
  fi
  
  # Check pacman.conf
  if ! grep -q "^\[${REPO_NAME}\]" /etc/pacman.conf 2>/dev/null; then
    log_warning "Repository not found in /etc/pacman.conf"
    log_info "Add this section to /etc/pacman.conf:"
    cat <<EOF

[$REPO_NAME]
SigLevel = Optional TrustAll
Server = file://$repo_path
EOF
  fi
  
  log_success "Repository initialized"
}

# ============================================================================
# Add Packages
# ============================================================================

cmd_add() {
  local -a packages=("$@")
  
  if [[ ${#packages[@]} -eq 0 ]]; then
    log_error "No packages specified"
    return 1
  fi
  
  # Verify all files exist first
  local pkg=""
  for pkg in "${packages[@]}"; do
    if [[ ! -f "$pkg" ]]; then
      log_error "Package file not found: $pkg"
      return 1
    fi
  done
  
  log_info "Adding ${#packages[@]} package(s) to repository"
  
  if [[ "$DRY_RUN" == "true" ]]; then
    for pkg in "${packages[@]}"; do
      log_info "DRY-RUN: Would add: $(basename "$pkg")"
    done
    return 0
  fi
  
  # Add to database
  if ! repo-add "$REPO_DB" "${packages[@]}"; then
    log_error "Failed to add packages to database"
    return 1
  fi
  
  # Move packages to repo directory
  for pkg in "${packages[@]}"; do
    local basename="$(basename "$pkg")"
    local dest="$REPO_DIR/$basename"
    
    if [[ "$pkg" != "$dest" ]]; then
      if ! mv "$pkg" "$dest"; then
        log_error "Failed to move: $pkg -> $dest"
        continue
      fi
      log_debug "Moved: $basename"
    fi
  done
  
  log_success "Packages added successfully"
  
  # Sync pacman database
  log_info "Run 'sudo pacman -Sy' to sync repository"
}

# ============================================================================
# Remove Packages
# ============================================================================

cmd_remove() {
  local -a pkgnames=("$@")
  
  if [[ ${#pkgnames[@]} -eq 0 ]]; then
    log_error "No package names specified"
    return 1
  fi
  
  log_info "Removing ${#pkgnames[@]} package(s) from repository"
  
  if [[ "$DRY_RUN" == "true" ]]; then
    for pkgname in "${pkgnames[@]}"; do
      log_info "DRY-RUN: Would remove: $pkgname"
    done
    return 0
  fi
  
  # Remove from database
  if ! repo-remove "$REPO_DB" "${pkgnames[@]}"; then
    log_error "Failed to remove packages from database"
    return 1
  fi
  
  # Remove package files
  for pkgname in "${pkgnames[@]}"; do
    # Find all versions of this package
    local -a files=()
    while IFS= read -r f; do
      [[ -n "$f" ]] && files+=("$f")
    done < <(find "$REPO_DIR" -maxdepth 1 -name "${pkgname}-*.pkg.tar.*" 2>/dev/null)
    
    if [[ ${#files[@]} -eq 0 ]]; then
      log_warning "No package files found for: $pkgname"
      continue
    fi
    
    for f in "${files[@]}"; do
      if ! rm -f "$f"; then
        log_error "Failed to remove: $f"
      else
        log_debug "Removed: $(basename "$f")"
      fi
    done
  done
  
  log_success "Packages removed successfully"
}

# ============================================================================
# List Packages
# ============================================================================

cmd_list() {
  local show_upgrades="false"
  local output_format="plain"
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --upgrades) show_upgrades="true"; shift ;;
      --json) output_format="json"; shift ;;
      --table) output_format="table"; shift ;;
      *) shift ;;
    esac
  done
  
  if [[ "$HAS_AURUTILS" == "true" && "$show_upgrades" == "true" ]]; then
    # Use aur-repo for upgrade detection
    aur repo --database "$REPO_NAME" --upgrades
    return $?
  fi
  
  # Fallback: list from database
  if [[ ! -f "$REPO_DB" ]]; then
    log_error "Repository database not found: $REPO_DB"
    return 1
  fi
  
  case "$output_format" in
    json)
      bsdtar -xOf "$REPO_DB" | awk '
        /^%NAME%$/ { getline; name=$0 }
        /^%VERSION%$/ { getline; version=$0; if (name) print "{\"name\":\""name"\",\"version\":\""version"\"}" }
      '
      ;;
    table)
      printf "%-30s %s\n" "PACKAGE" "VERSION"
      printf "%-30s %s\n" "$(printf '%.0s-' {1..30})" "$(printf '%.0s-' {1..20})"
      bsdtar -xOf "$REPO_DB" | awk '
        /^%NAME%$/ { getline; name=$0 }
        /^%VERSION%$/ { getline; version=$0; if (name) printf "%-30s %s\n", name, version }
      '
      ;;
    *)
      bsdtar -xOf "$REPO_DB" | awk '
        /^%NAME%$/ { getline; name=$0 }
        /^%VERSION%$/ { getline; version=$0; if (name) print name, version }
      '
      ;;
  esac
}

# ============================================================================
# Cleanup Old Versions
# ============================================================================

cmd_cleanup() {
  local keep_n=1
  local remove_orphans="false"
  local vacuum="false"
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep-n) keep_n="${2:?missing count}"; shift 2 ;;
      --remove-orphans) remove_orphans="true"; shift ;;
      --vacuum) vacuum="true"; shift ;;
      *) shift ;;
    esac
  done
  
  log_info "Cleaning up repository (keep $keep_n versions)"
  
  # Get list of packages in repo
  local -a pkgnames=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && pkgnames+=("$line")
  done < <(bsdtar -xOf "$REPO_DB" 2>/dev/null | awk '/^%NAME%$/ { getline; print }' | sort -u)
  
  if [[ ${#pkgnames[@]} -eq 0 ]]; then
    log_warning "No packages found in repository"
    return 0
  fi
  
  local removed_count=0
  local pkgname=""
  
  for pkgname in "${pkgnames[@]}"; do
    # Find all versions of this package
    local -a versions=()
    while IFS= read -r f; do
      [[ -n "$f" ]] && versions+=("$f")
    done < <(find "$REPO_DIR" -maxdepth 1 -name "${pkgname}-*.pkg.tar.*" -printf '%T@ %p\n' 2>/dev/null | \
             sort -rn | awk '{print $2}')
    
    local count=${#versions[@]}
    if [[ $count -le $keep_n ]]; then
      continue
    fi
    
    # Remove old versions (keep_n newest)
    local i=0
    for f in "${versions[@]}"; do
      ((i++))
      if [[ $i -le $keep_n ]]; then
        continue
      fi
      
      if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY-RUN: Would remove old version: $(basename "$f")"
      else
        if rm -f "$f"; then
          log_debug "Removed old version: $(basename "$f")"
          ((removed_count++))
        fi
      fi
    done
  done
  
  if [[ "$DRY_RUN" != "true" && $removed_count -gt 0 ]]; then
    log_success "Removed $removed_count old package version(s)"
  fi
  
  # Remove orphans (packages not in feeds.json)
  if [[ "$remove_orphans" == "true" ]]; then
    if [[ ! -f "$FEEDS_JSON" ]]; then
      log_warning "feeds.json not found, skipping orphan removal"
    else
      local -a feed_pkgs=()
      while IFS= read -r name; do
        [[ -n "$name" ]] && feed_pkgs+=("$name")
      done < <(jq -r '.packages[]?.name // empty' "$FEEDS_JSON" 2>/dev/null)
      
      for pkgname in "${pkgnames[@]}"; do
        if [[ ! " ${feed_pkgs[*]} " =~ " ${pkgname} " ]]; then
          log_info "Orphan detected (not in feeds.json): $pkgname"
          if [[ "$DRY_RUN" != "true" ]]; then
            cmd_remove "$pkgname"
          fi
        fi
      done
    fi
  fi
  
  # Vacuum (compress database)
  if [[ "$vacuum" == "true" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "DRY-RUN: Would vacuum database"
    else
      log_info "Vacuuming database..."
      # repo-add with no packages just rebuilds the DB compactly
      repo-add "$REPO_DB" >/dev/null 2>&1
      log_success "Database vacuumed"
    fi
  fi
}

# ============================================================================
# Verify Repository
# ============================================================================

cmd_verify() {
  log_info "Verifying repository: $REPO_DB"
  
  local errors=0
  
  # Check database exists
  if [[ ! -f "$REPO_DB" ]]; then
    log_error "Database not found: $REPO_DB"
    return 1
  fi
  
  # Check database is readable
  if ! bsdtar -tf "$REPO_DB" >/dev/null 2>&1; then
    log_error "Database is corrupted or unreadable"
    return 1
  fi
  
  # Get packages from database
  local -a db_pkgs=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && db_pkgs+=("$line")
  done < <(bsdtar -xOf "$REPO_DB" 2>/dev/null | awk '
    /^%NAME%$/ { getline; name=$0 }
    /^%VERSION%$/ { getline; version=$0; if (name) print name "-" version }
  ')
  
  log_info "Database contains ${#db_pkgs[@]} package(s)"
  
  # Check each package has corresponding file
  local pkg=""
  for pkg in "${db_pkgs[@]}"; do
    local found="false"
    local -a matches=()
    
    while IFS= read -r f; do
      [[ -n "$f" ]] && matches+=("$f")
    done < <(find "$REPO_DIR" -maxdepth 1 -name "${pkg}-*.pkg.tar.*" 2>/dev/null)
    
    if [[ ${#matches[@]} -eq 0 ]]; then
      log_error "Missing package file for: $pkg"
      ((errors++))
    elif [[ ${#matches[@]} -gt 1 ]]; then
      log_warning "Multiple files found for: $pkg"
    else
      log_debug "OK: $pkg"
    fi
  done
  
  if [[ $errors -eq 0 ]]; then
    log_success "Repository verification passed"
    return 0
  else
    log_error "Repository verification failed ($errors errors)"
    return 1
  fi
}

# ============================================================================
# Repository Status
# ============================================================================

cmd_status() {
  if [[ ! -f "$REPO_DB" ]]; then
    log_error "Repository not initialized"
    return 1
  fi
  
  local pkg_count=0
  pkg_count=$(bsdtar -xOf "$REPO_DB" 2>/dev/null | grep -c '^%NAME%$' || echo 0)
  
  local file_count=0
  file_count=$(find "$REPO_DIR" -maxdepth 1 -name "*.pkg.tar.*" 2>/dev/null | wc -l)
  
  local db_size=""
  db_size=$(du -h "$REPO_DB" 2>/dev/null | awk '{print $1}')
  
  local repo_size=""
  repo_size=$(du -sh "$REPO_DIR" 2>/dev/null | awk '{print $1}')
  
  cat <<EOF
Repository Status
=================
Name:     $REPO_NAME
Path:     $REPO_DIR
Database: $REPO_DB

Packages in DB:    $pkg_count
Package files:     $file_count
Database size:     $db_size
Repository size:   $repo_size
EOF
}

# ============================================================================
# Main Command Dispatch
# ============================================================================

main() {
  if [[ $# -eq 0 ]]; then
    show_usage
    exit 1
  fi
  
  # Parse global options
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN="true"; shift ;;
      --verbose) VERBOSE="true"; DEBUG="true"; shift ;;
      -h|--help) show_usage; exit 0 ;;
      -*) shift ;;  # Skip unknown options (will be handled by subcommands)
      *) break ;;
    esac
  done
  
  local cmd="${1:-}"
  shift || true
  
  case "$cmd" in
    init) cmd_init "$@" ;;
    add) cmd_add "$@" ;;
    remove) cmd_remove "$@" ;;
    list) cmd_list "$@" ;;
    cleanup) cmd_cleanup "$@" ;;
    verify) cmd_verify "$@" ;;
    status) cmd_status "$@" ;;
    "")
      log_error "No command specified"
      show_usage
      exit 1
      ;;
    *)
      log_error "Unknown command: $cmd"
      show_usage
      exit 1
      ;;
  esac
}

main "$@"