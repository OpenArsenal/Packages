#!/usr/bin/env bash
set -uo pipefail

# resolve-deps.sh - Resolve AUR dependencies and optionally import them
#
# Uses aur-depends to build a complete dependency graph, then imports
# missing dependencies via aur-imports.sh
#
# Examples:
#   ./resolve-deps.sh ktailctl                    # Show deps
#   ./resolve-deps.sh ktailctl --import           # Import deps
#   ./resolve-deps.sh ktailctl --build-order      # Show build order
#   ./resolve-deps.sh ktailctl --json             # JSON output

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ============================================================================
# Options
# ============================================================================

declare IMPORT="false"
declare BUILD_ORDER="false"
declare OUTPUT_JSON="false"
declare VERBOSE="false"
declare -a PACKAGES=()

show_usage() {
  cat <<EOF
Usage: $0 [OPTIONS] <package> [more-packages...]

Resolve AUR dependencies for packages and optionally import them.

OPTIONS:
  --import            Import missing dependencies via aur-imports.sh
  --build-order       Output packages in build order (tsorted)
  --json              Output JSON (one object per line)
  --verbose           Show resolution details
  -h, --help          Show this help

OUTPUT:
  Without --json: One package per line
  With --json: JSONL format with package metadata

EXAMPLES:
  # Show dependencies
  $0 ktailctl

  # Import dependencies
  $0 ktailctl --import

  # Get build order for multiple packages
  $0 ktailctl ollama vesktop --build-order

  # JSON output for scripting
  $0 ktailctl --json
EOF
}

# ============================================================================
# Dependency Checking
# ============================================================================

check_deps() {
  local -a missing=()
  
  command -v git >/dev/null 2>&1 || missing+=("git")
  command -v jq >/dev/null 2>&1 || missing+=("jq")
  
  if [[ "$HAS_AURUTILS" != "true" ]]; then
    log_error "aurutils is required for dependency resolution"
    log_info "Install with: paru -S aurutils"
    exit 1
  fi
  
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing dependencies: ${missing[*]}"
    exit 1
  fi
}

# ============================================================================
# Dependency Resolution
# ============================================================================

resolve_single_package() {
  local pkg="$1"
  local -a graph_output=()
  
  log_debug "Resolving dependencies for: $pkg"
  
  # Use aur-depends to get dependency graph
  # --graph outputs edges suitable for tsort
  local deps_raw=""
  if ! deps_raw=$(aur depends --graph "$pkg" 2>/dev/null); then
    log_error "Failed to resolve dependencies for: $pkg"
    return 1
  fi
  
  # tsort to get build order
  local deps_sorted=""
  if ! deps_sorted=$(echo "$deps_raw" | tsort 2>/dev/null); then
    log_error "Dependency graph has cycles for: $pkg"
    return 1
  fi
  
  echo "$deps_sorted"
}

resolve_multiple_packages() {
  local -a pkgs=("$@")
  local -a all_deps=()
  local pkg=""
  
  # Resolve each package
  for pkg in "${pkgs[@]}"; do
    local deps=""
    if ! deps=$(resolve_single_package "$pkg"); then
      log_error "Skipping $pkg due to resolution failure"
      continue
    fi
    
    # Collect all deps
    while IFS= read -r dep; do
      [[ -n "$dep" ]] && all_deps+=("$dep")
    done <<< "$deps"
  done
  
  # Deduplicate while preserving order (build order matters)
  local -a seen=()
  local -a unique=()
  local dep=""
  
  for dep in "${all_deps[@]}"; do
    if [[ ! " ${seen[*]} " =~ " ${dep} " ]]; then
      seen+=("$dep")
      unique+=("$dep")
    fi
  done
  
  printf "%s\n" "${unique[@]}"
}

# ============================================================================
# Import Logic
# ============================================================================

is_already_imported() {
  local pkg="$1"
  [[ -d "$BUILD_ROOT/$pkg" ]] && [[ -f "$BUILD_ROOT/$pkg/PKGBUILD" ]]
}

import_package() {
  local pkg="$1"
  
  if is_already_imported "$pkg"; then
    log_debug "$pkg already imported, skipping"
    return 0
  fi
  
  log_info "Importing: $pkg"
  
  if ! "$SCRIPT_DIR/aur-imports.sh" "$pkg" --infer; then
    log_error "Failed to import: $pkg"
    return 1
  fi
  
  log_success "Imported: $pkg"
}

import_dependencies() {
  local -a deps=()
  local dep=""
  
  # Read dependencies from stdin
  while IFS= read -r dep; do
    [[ -n "$dep" ]] && deps+=("$dep")
  done
  
  if [[ ${#deps[@]} -eq 0 ]]; then
    log_warning "No dependencies to import"
    return 0
  fi
  
  log_info "Importing ${#deps[@]} package(s)..."
  
  local failed=0
  for dep in "${deps[@]}"; do
    if ! import_package "$dep"; then
      ((failed++))
    fi
  done
  
  if [[ $failed -gt 0 ]]; then
    log_error "$failed package(s) failed to import"
    return 1
  fi
  
  log_success "All dependencies imported successfully"
}

# ============================================================================
# Output Formatting
# ============================================================================

output_plain() {
  local -a deps=()
  local dep=""
  
  while IFS= read -r dep; do
    [[ -n "$dep" ]] && deps+=("$dep")
  done
  
  for dep in "${deps[@]}"; do
    echo "$dep"
  done
}

output_json() {
  local -a deps=()
  local dep=""
  
  while IFS= read -r dep; do
    [[ -n "$dep" ]] && deps+=("$dep")
  done
  
  for dep in "${deps[@]}"; do
    local imported="false"
    is_already_imported "$dep" && imported="true"
    
    local installed="false"
    pacman -Qq "$dep" >/dev/null 2>&1 && installed="true"
    
    jq -n \
      --arg name "$dep" \
      --arg imported "$imported" \
      --arg installed "$installed" \
      '{
        name: $name,
        imported: ($imported == "true"),
        installed: ($installed == "true")
      }'
  done
}

# ============================================================================
# Main
# ============================================================================

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --import) IMPORT="true"; shift ;;
      --build-order) BUILD_ORDER="true"; shift ;;
      --json) OUTPUT_JSON="true"; shift ;;
      --verbose) VERBOSE="true"; DEBUG="true"; shift ;;
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
  check_deps
  
  if [[ ${#PACKAGES[@]} -eq 0 ]]; then
    log_error "No packages specified"
    show_usage
    exit 1
  fi
  
  [[ "$VERBOSE" == "true" ]] && log_info "Resolving dependencies for: ${PACKAGES[*]}"
  
  # Resolve dependencies
  local deps=""
  if ! deps=$(resolve_multiple_packages "${PACKAGES[@]}"); then
    log_error "Dependency resolution failed"
    exit 1
  fi
  
  # Import if requested
  if [[ "$IMPORT" == "true" ]]; then
    if ! echo "$deps" | import_dependencies; then
      exit 1
    fi
  fi
  
  # Output
  if [[ "$OUTPUT_JSON" == "true" ]]; then
    echo "$deps" | output_json
  else
    echo "$deps" | output_plain
  fi
}

main "$@"