#!/bin/sh
set -eu

# aur-imports.sh - Import AUR packages and update feeds.json
#
# Clones AUR packages into pkgs/ directory and adds/updates feeds.json entries.
#
# Requirements:
#   - Environment from .envrc (PKGBUILDS_ROOT, PKG_DIR, FEEDS_JSON)
#   - Dependencies: git, jq, python3
#
# Usage:
#   ./scripts/aur-imports.sh <aur-url-or-name> [options]
#   ./scripts/aur-imports.sh google-chrome-canary-bin --infer
#   ./scripts/aur-imports.sh https://aur.archlinux.org/ktailctl.git --infer
#   ./scripts/aur-imports.sh somepkg --type manual
#
# Options:
#   --feeds <path>      Override feeds.json path
#   --type <type>       Feed type (manual|vcs|github-release|github-release-filtered|...)
#   --repo <owner/repo> GitHub repo for github-* types
#   --channel <name>    stable|any|prerelease (default: stable)
#   --url <url>         For feed types requiring explicit URL
#   --infer             Infer GitHub repo from PKGBUILD (recommended)
#   --force             Overwrite existing directory
#   -h, --help          Show help

err() { printf '%s: %s\n' "${0##*/}" "$*" >&2; }
die() { err "$*"; exit 1; }

validate_env() {
  missing=""
  [ -z "${PKGBUILDS_ROOT:-}" ] && missing="${missing}PKGBUILDS_ROOT "
  [ -z "${PKG_DIR:-}" ] && missing="${missing}PKG_DIR "
  [ -z "${FEEDS_JSON:-}" ] && missing="${missing}FEEDS_JSON "
  
  if [ -n "$missing" ]; then
    die "Missing environment: $missing
Run 'direnv allow' or manually source .envrc"
  fi
  
  [ ! -d "${PKGBUILDS_ROOT}" ] && die "PKGBUILDS_ROOT not found: ${PKGBUILDS_ROOT}"
}

validate_env

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${PKGBUILDS_ROOT}"
PACKAGES_DIR="${PKG_DIR}"
FEEDS_JSON_DEFAULT="${FEEDS_JSON}"

check_deps() {
  missing=""
  command -v git >/dev/null 2>&1 || missing="${missing}git "
  command -v jq >/dev/null 2>&1 || missing="${missing}jq "
  command -v python3 >/dev/null 2>&1 || missing="${missing}python3 "
  
  if [ -n "$missing" ]; then
    die "Missing dependencies: $missing
Install with: sudo pacman -S $missing"
  fi
}

show_usage() {
  cat <<'EOF'
Usage: aur-imports.sh [OPTIONS] <aur-url-or-name> [more...]

OPTIONS:
  --feeds <path>      feeds.json path (default: from .envrc)
  --type <type>       Feed type (manual|vcs|github-release|...)
  --repo <owner/repo> GitHub repo for github-* types
  --channel <name>    stable|any|prerelease (default: stable)
  --url <url>         For feed types requiring explicit URL
  --infer             Infer GitHub repo from PKGBUILD (recommended)
  --force             Overwrite existing directory
  -h, --help          Show help

Examples:
  ./scripts/aur-imports.sh google-chrome-canary-bin --infer
  ./scripts/aur-imports.sh https://aur.archlinux.org/ktailctl.git --infer
  ./scripts/aur-imports.sh somepkg --type manual

Packages are cloned into: ${PKG_DIR}
Feed configuration: ${FEEDS_JSON}
EOF
}

aur_url_from_name() {
  name="$1"
  echo "https://aur.archlinux.org/${name}.git"
}

aur_name_from_url_or_name() {
  input="$1"
  
  # Check if it's a URL
  case "$input" in
    http*://*)
      # Extract basename and remove .git suffix using POSIX tools
      base="${input##*/}"
      base="${base%.git}"
      echo "$base"
      return 0
      ;;
  esac
  
  echo "$input"
}

infer_github_repo_from_pkgbuild() {
  pkgbuild_path="$1"
  
  [ ! -f "$pkgbuild_path" ] && echo "" && return 0
  
  content=$(cat "$pkgbuild_path" 2>/dev/null) || { echo ""; return 0; }
  
  python3 - "$content" <<'PY'
import re
import sys

content = sys.argv[1]

# Strategy 1: Look for explicit repo= variable
repo_match = re.search(r'^[^\#]*\brepo\s*=\s*["\']?(https?://github\.com/([^/\s"\']+)/([^/\s"\'\.]+))', content, re.MULTILINE)
if repo_match:
    print(f"{repo_match.group(2)}/{repo_match.group(3)}")
    sys.exit(0)

# Strategy 2: Look for git+ sources
git_source_match = re.search(r'git\+https?://github\.com/([^/\s"\']+)/([^/\s"\'\.]+)', content)
if git_source_match:
    print(f"{git_source_match.group(1)}/{git_source_match.group(2)}")
    sys.exit(0)

# Strategy 3: Look for url= variable
url_match = re.search(r'^[^\#]*\burl\s*=\s*["\']?(https?://github\.com/([^/\s"\']+)/([^/\s"\']+))', content, re.MULTILINE)
if url_match:
    print(f"{url_match.group(2)}/{url_match.group(3)}")
    sys.exit(0)

sys.exit(2)
PY
}

infer_feed_type_from_context() {
  pkg="$1"
  inferred_repo="$2"
  
  # VCS packages: -git, -hg, -svn, -bzr suffix
  case "$pkg" in
    *-git|*-hg|*-svn|*-bzr)
      echo "vcs"
      return 0
      ;;
  esac
  
  # If we found a GitHub repo, default to github-release
  if [ -n "$inferred_repo" ]; then
    echo "github-release"
    return 0
  fi
  
  echo "manual"
}

ensure_feeds_json_exists() {
  feeds_json="$1"
  
  if [ -f "$feeds_json" ]; then
    return 0
  fi
  
  err "feeds.json not found, creating: $feeds_json"
  
  cat >"$feeds_json" <<'JSON'
{
  "schemaVersion": 2,
  "packages": []
}
JSON
}

feeds_upsert_pkg() {
  feeds_json="$1"
  name="$2"
  type="$3"
  repo="$4"
  channel="$5"
  url="$6"
  
  obj=$(jq -n \
    --arg name "$name" \
    --arg type "$type" \
    --arg repo "$repo" \
    --arg channel "$channel" \
    --arg url "$url" \
    '
    { name: $name, sourceType: $type }
    + (if (($repo|length) > 0) then { repo: $repo } else {} end)
    + (if (($channel|length) > 0) then { channel: $channel } else {} end)
    + (if (($url|length) > 0) then { url: $url } else {} end)
    ') || {
    err "Failed to construct feed JSON for '$name'"
    return 1
  }
  
  tmp=$(mktemp)
  
  jq --arg name "$name" --argjson obj "$obj" '
    .schemaVersion = (.schemaVersion // 2)
    | .packages = (.packages // [])
    | if (.packages | map(.name) | index($name)) == null
      then .packages += [$obj]
      else .packages = (.packages | map(if .name == $name then $obj else . end))
      end
  ' "$feeds_json" >"$tmp" || {
    rm -f "$tmp" >/dev/null 2>&1 || true
    err "Failed to update feeds.json for '$name'"
    return 1
  }
  
  mv "$tmp" "$feeds_json"
  return 0
}

clone_aur_pkg() {
  input="$1"
  pkg="$2"
  force="$3"
  
  # Determine URL
  case "$input" in
    http*://*)
      url="$input"
      ;;
    *)
      url=$(aur_url_from_name "$input")
      ;;
  esac
  
  dest="${PACKAGES_DIR}/${pkg}"
  
  if [ -d "$dest" ]; then
    if [ "$force" = "true" ]; then
      err "Removing existing: $dest"
      rm -rf "$dest"
    else
      die "Directory exists: $dest (use --force to overwrite)"
    fi
  fi
  
  printf "Cloning: %s -> %s\n" "$url" "$dest" >&2
  
  git clone --depth 1 "$url" "$dest" >/dev/null 2>&1 || {
    die "Clone failed: $url"
  }
  
  # Strip git metadata
  rm -rf "$dest/.git" >/dev/null 2>&1 || true
  
  if [ ! -f "$dest/PKGBUILD" ]; then
    die "No PKGBUILD found in $dest"
  fi
  
  printf "Imported: %s\n" "$dest" >&2
}

# Parse arguments
FEEDS_JSON="$FEEDS_JSON_DEFAULT"
TYPE=""
REPO=""
CHANNEL="stable"
URL=""
INFER="false"
FORCE="false"
INPUTS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --feeds)
      FEEDS_JSON="$2"
      shift 2
      ;;
    --type)
      TYPE="$2"
      shift 2
      ;;
    --repo)
      REPO="$2"
      shift 2
      ;;
    --channel)
      CHANNEL="$2"
      shift 2
      ;;
    --url)
      URL="$2"
      shift 2
      ;;
    --infer)
      INFER="true"
      shift
      ;;
    --force)
      FORCE="true"
      shift
      ;;
    -h|--help)
      show_usage
      exit 0
      ;;
    -*)
      err "Unknown option: $1"
      show_usage
      exit 1
      ;;
    *)
      INPUTS="${INPUTS}${INPUTS:+ }$1"
      shift
      ;;
  esac
done

main() {
  check_deps
  ensure_feeds_json_exists "$FEEDS_JSON"
  
  if [ -z "$INPUTS" ]; then
    show_usage
    exit 1
  fi
  
  # Process each package (POSIX: no arrays, use word splitting)
  for input in $INPUTS; do
    pkg=$(aur_name_from_url_or_name "$input")
    pkgdir="${PACKAGES_DIR}/${pkg}"
    pkgb="${pkgdir}/PKGBUILD"
    
    clone_aur_pkg "$input" "$pkg" "$FORCE" || exit 1
    
    inferred_repo=""
    inferred_type="$TYPE"
    
    if [ "$INFER" = "true" ]; then
      inferred_repo=$(infer_github_repo_from_pkgbuild "$pkgb" 2>/dev/null || true)
      
      if [ -n "$inferred_repo" ]; then
        printf "Inferred GitHub repo: %s\n" "$inferred_repo" >&2
      else
        err "Could not infer GitHub repo from PKGBUILD"
      fi
      
      if [ -z "$inferred_type" ]; then
        inferred_type=$(infer_feed_type_from_context "$pkg" "$inferred_repo")
        printf "Inferred feed type: %s\n" "$inferred_type" >&2
      fi
    fi
    
    # Use explicit values if set, otherwise use inferred
    final_type="${TYPE:-$inferred_type}"
    final_repo="${REPO:-$inferred_repo}"
    final_channel="$CHANNEL"
    final_url="$URL"
    
    [ -z "$final_type" ] && final_type="manual"
    
    if feeds_upsert_pkg "$FEEDS_JSON" "$pkg" "$final_type" "$final_repo" "$final_channel" "$final_url"; then
      printf "Updated feeds.json: %s (type=%s" "$pkg" "$final_type" >&2
      [ -n "$final_repo" ] && printf ", repo=%s" "$final_repo" >&2
      printf ")\n" >&2
    else
      die "Failed to update feeds.json for $pkg"
    fi
  done
  
  printf "\nDone.\n" >&2
}

main "$@"