#!/usr/bin/env bash
# Strict mode:
#   -u  treat unset variables as errors (prevents silent bugs from typos in var names)
#   -o pipefail  a pipeline fails if ANY command in it fails, not just the last one
#   (intentionally omitting -e / errexit because we handle errors explicitly with ||)
set -uo pipefail

# update-pkg.sh - Version detection and PKGBUILD update tool.
#
# Default behavior (no --apply): reads feeds.json to discover what each
# package's upstream version is, compares it to the pkgver= in each local
# PKGBUILD, and reports which packages are out of date. No files are modified.
#
# With --apply: also rewrites pkgver=/pkgrel= in the PKGBUILD and runs
# updpkgsums to regenerate source checksums.
#
# Architecture overview:
#   feeds.json       →  describes HOW to find each package's upstream version
#                       (which API, which repo, which regex, etc.)
#   PKGBUILD files   →  contain the CURRENT version (pkgver=)
#   fetcher functions →  translate feed config into a single version string
#   dispatcher       →  routes each feed "type" to the right fetcher
#   check_single_package → ties it all together: fetch, compare, report/apply

# ============================================================================
# Logging (all to stderr so stdout stays clean for --json / --list-outdated)
# ============================================================================

declare -r RED='\033[0;31m'
declare -r GREEN='\033[0;32m'
declare -r YELLOW='\033[1;33m'
declare -r BLUE='\033[0;34m'
declare -r NC='\033[0m'   # No Color — resets terminal color after each message

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"    >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*" >&2; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"    >&2; }
# log_debug only emits output when DEBUG=true, so it's safe to leave calls in
# production code — they're completely silent unless explicitly enabled.
log_debug()   { [[ "${DEBUG:-false}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} $*" >&2; }

declare -r PACKAGE_UPDATE_BOT_USER_AGENT="Package-Update-Bot/1.0"
declare -r FETCH_TIMEOUT=30  # seconds; prevents hung connections from blocking the whole run

# ============================================================================
# Network Helpers
# ============================================================================

# General-purpose HTTP fetch. Transparently injects GitHub auth headers when
# a token is available and the URL targets api.github.com.
#
# curl flags used throughout this script:
#   -s   silent: suppresses progress meter
#   -S   show-error: still shows error messages even in silent mode
#   -L   follow HTTP redirects (needed for many download URLs)
#   -A   set User-Agent header (some APIs require a non-empty UA)
#   --max-time  hard timeout for the entire operation (not just connection)
fetch() {
  local url="${1:-}"
  [[ -z "$url" ]] && return 1

  # GitHub's unauthenticated API limit is 60 requests/hour per IP — very easy
  # to exhaust when checking dozens of packages. With a token it's 5000/hour.
  # The X-GitHub-Api-Version header pins us to a specific API version so
  # GitHub's API changes don't silently break the response shape.
  if [[ -n "${GITHUB_TOKEN:-}" && "$url" == https://api.github.com/* ]]; then
    curl -sSL --max-time "$FETCH_TIMEOUT" \
      -A "$PACKAGE_UPDATE_BOT_USER_AGENT" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url" 2>/dev/null
    return $?
  fi

  curl -sSL --max-time "$FETCH_TIMEOUT" -A "$PACKAGE_UPDATE_BOT_USER_AGENT" "$url" 2>/dev/null
}

# Resolves a URL through all HTTP redirects and returns the final destination URL.
# Used by get_lmstudio_version: LM Studio encodes the version number in the
# path of their "latest" redirect target, so we need the final URL, not the body.
#
# Strategy: try HEAD first (avoids downloading the body), fall back to a
# ranged GET (bytes 0-0) if the server doesn't support HEAD.
#
# curl flags specific to this function:
#   -I       HEAD request only (no body download)
#   -r 0-0   request only the first byte (Range: bytes=0-0)
#   -o /dev/null  discard the body entirely
#   -w '%{url_effective}'  write-out directive: prints the final URL after
#                          all redirects have been followed; this is the
#                          only output we actually want from this call
fetch_effective_url() {
  local url="${1:-}"
  [[ -z "$url" ]] && return 1
  local effective=""

  # Primary: HEAD request, follow redirects (-L), discard body (-o /dev/null),
  # print only the final URL (-w '%{url_effective}')
  effective="$(
    curl -sSIL --max-time "$FETCH_TIMEOUT" \
      -A "$PACKAGE_UPDATE_BOT_USER_AGENT" \
      -o /dev/null \
      -w '%{url_effective}' \
      "$url" 2>/dev/null
  )" || true

  if [[ -z "$effective" ]]; then
    # Fallback: some servers return 405 Method Not Allowed for HEAD.
    # A ranged GET fetching only 1 byte still follows redirects and gives
    # us the final URL without downloading the full (potentially large) file.
    effective="$(
      curl -sSL --max-time "$FETCH_TIMEOUT" \
        -A "$PACKAGE_UPDATE_BOT_USER_AGENT" \
        -r 0-0 \
        -o /dev/null \
        -w '%{url_effective}' \
        "$url" 2>/dev/null
    )" || true
  fi

  [[ -z "$effective" ]] && return 1
  printf '%s\n' "$effective"
}

# ============================================================================
# JSON Response Validation Helpers
# ============================================================================

# Guards against GitHub API error responses being passed to jq array operations.
#
# When the API returns an error (rate limit exceeded, repo not found, etc.) it
# sends a JSON object like {"message": "API rate limit exceeded...", ...} rather
# than the expected array. If we then run `jq '.[].name'` on that object, jq
# iterates the object's values (which are strings) and then tries to access
# `.name` on each string — producing the cryptic error:
#   "Cannot index string with string 'name'"
#
# jq -e exits with status 1 if the expression produces false or null, and 0
# otherwise. So `jq -e 'type == "array"'` exits 0 only when the input IS an
# array — letting us guard before any .[].field access.
json_is_array() {
  echo "${1:-}" | jq -e 'type == "array"' >/dev/null 2>&1
}

# Extracts the human-readable error message from a GitHub API error object.
# GitHub error objects always have a "message" field; this returns empty string
# for non-error responses (the // empty fallback handles missing keys cleanly).
json_api_error_message() {
  echo "${1:-}" | jq -r '.message // empty' 2>/dev/null
}

# ============================================================================
# feeds.json Helpers (Schema-Aware)
# ============================================================================
#
# feeds.json has two schema versions that store feed config in different shapes:
#
#   Schema v1 (legacy):
#     {"packages": [{"name": "foo", "feed": {"type": "github-release", "repo": "..."}}]}
#     Fields are nested under a "feed" sub-object.
#
#   Schema v2 (current):
#     {"schemaVersion": 2, "packages": [{"name": "foo", "type": "github-release", "repo": "..."}]}
#     Fields are flat on the package object itself.
#
# All helpers below handle both versions transparently.

feeds_json_get_schema_version() {
  local feeds_json="${1:-}"
  [[ -z "$feeds_json" ]] && echo "1" && return 0
  # .schemaVersion // 1 — the // operator is jq's "alternative": if the left
  # side is null or missing, use the right side (1) as the default.
  jq -r '.schemaVersion // 1' "$feeds_json"
}

feeds_json_list_packages() {
  local feeds_json="${1:-}"
  [[ -z "$feeds_json" ]] && return 0
  # .packages[]? — the ? makes the array iterator optional: if .packages is
  # null or missing, produce nothing instead of an error. Without ? it would
  # throw "null is not iterable".
  # // empty — if a package object has no .name field, skip it (output nothing)
  # rather than outputting the string "null".
  # sed '/^$/d' — removes any blank lines that slip through.
  jq -r '.packages[]?.name // empty' "$feeds_json" | sed '/^$/d'
}

# Reads a single field from a package's feed config, handling both schema versions.
# Returns empty string (not an error) if the field is absent — callers check
# for empty and apply their own defaults.
feeds_json_get_field() {
  local feeds_json="${1:-}"
  local pkg="${2:-}"
  local field="${3:-}"
  [[ -z "$feeds_json" || -z "$pkg" || -z "$field" ]] && return 0

  local schema_version
  schema_version="$(feeds_json_get_schema_version "$feeds_json")"

  if [[ "$schema_version" == "1" ]]; then
    # v1: find the matching package by name, then look inside its .feed object.
    # --arg name "$pkg"  — passes the shell variable safely into jq as a string
    #                      (avoids injection if the name contains special chars).
    # select(.name==$name) — filters the array to just the element with matching name.
    # .feed[$field]     — dynamic field lookup using the jq variable $field.
    # // empty          — produce no output (not "null") when the field is absent.
    jq -r --arg name "$pkg" --arg field "$field" '
      (.packages[] | select(.name==$name) | .feed[$field]) // empty
    ' "$feeds_json"
  else
    # v2: same lookup but fields are directly on the package object, not under .feed.
    jq -r --arg name "$pkg" --arg field "$field" '
      (.packages[] | select(.name==$name) | .[$field]) // empty
    ' "$feeds_json"
  fi
}

# Returns exit code 0 (true) if the package exists in feeds.json, 1 otherwise.
# jq -e exits 1 if the expression produces false or null — we exploit this to
# turn the presence/absence of a matching element into a bash boolean.
feeds_json_has_pkg() {
  local feeds_json="${1:-}"
  local pkg="${2:-}"
  [[ -z "$feeds_json" || -z "$pkg" ]] && return 1
  jq -e --arg name "$pkg" '.packages[] | select(.name==$name) | .name' "$feeds_json" >/dev/null 2>&1
}

# ============================================================================
# Version Normalization / Extraction
# ============================================================================

trim() {
  local s="${1:-}"
  # Two-pass sed: strip leading whitespace, then trailing whitespace.
  # Handles newlines, spaces, tabs that may come in from curl/jq output.
  echo "$s" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

# Strips common tag prefixes to produce a bare version number.
# Accepts input either as a positional argument OR from stdin (for use in pipes).
#
# What gets stripped:
#   "refs/tags/v1.2.3"  → "1.2.3"   (full git ref format)
#   "v1.2.3"            → "1.2.3"   (lowercase v prefix, the common convention)
#   "V1.2.3"            → "1.2.3"   (uppercase V prefix, used by some repos)
#   "\r\n" line endings → stripped   (GitHub API can return Windows line endings
#                                     in some tag name fields)
#
# ${var#prefix} is bash parameter expansion for "strip shortest prefix match".
# It's faster than sed for simple literal prefix removal.
normalize_basic_tag_to_version() {
  local raw=""

  if [[ $# -gt 0 ]]; then
    raw="${1:-}"
  else
    # Stdin mode: read entire input into one string. The `|| true` prevents
    # pipefail from triggering if the upstream command in the pipe already failed.
    raw="$(cat || true)"
  fi

  raw="${raw//$'\r'/}"   # strip carriage returns (Windows line endings)
  raw="${raw//$'\n'/}"   # strip newlines (defensive; shouldn't be in a tag name)
  raw="${raw#refs/tags/}" # strip git ref prefix if present
  raw="${raw#v}"          # strip lowercase v prefix
  raw="${raw#V}"          # strip uppercase V prefix

  printf '%s\n' "$raw"
}

# Extracts a version string from a tag by applying a regex with capture groups,
# then substituting the captures into a format string.
#
# Example from feeds.json for icu69:
#   tag:            "release-69-1"
#   versionRegex:   "^release-([0-9]+)-([0-9]+)$"
#   versionFormat:  "$1.$2"
#   result:         "69.1"
#
# Why Python instead of bash:
#   Bash's =~ operator supports capture groups via BASH_REMATCH, but
#   substituting them into a format string requires clunky array indexing,
#   can't handle more than ~3 groups cleanly, and has subtle quoting issues
#   with special characters in the version string. Python's re module handles
#   all of this cleanly and is universally available.
#
# The heredoc uses <<'PY' (single-quoted delimiter) to prevent the shell from
# expanding $1, $2, etc. inside the Python script — those are Python variables,
# not shell positional parameters.
#
# Exit codes:
#   0   success — version string printed to stdout
#   2   regex didn't match (caller can fall back to the raw tag)
apply_version_regex() {
  local raw="${1:-}"
  local version_regex="${2:-}"
  local version_format="${3:-}"
  [[ -z "$raw" || -z "$version_regex" || -z "$version_format" ]] && return 2

  python3 - "$raw" "$version_regex" "$version_format" <<'PY'
import re
import sys

raw = sys.argv[1]
rx  = sys.argv[2]
fmt = sys.argv[3]

# re.match anchors at the start of the string (like ^); for full-string
# matching the versionRegex should include $ at the end.
m = re.match(rx, raw)
if not m:
  sys.exit(2)   # Signal "no match" to the caller with a distinct exit code

out = fmt
# Substitute $1, $2, ... $9 in the format string with their capture group values.
# m.lastindex is the index of the last matched group (None if no groups).
# We check i <= m.lastindex to avoid IndexError on unmatched optional groups.
for i in range(1, 10):
  token = f"${i}"
  if token in out:
    val = m.group(i) if i <= m.lastindex else ""
    out = out.replace(token, val or "")
print(out)
PY
}

# Reads version strings from stdin (one per line) and prints the highest one.
# Used after github_tags_filtered_versions collects ALL matching tags across
# all pages — we want the newest, not just the last one on the last page.
#
# Why not just take the last line from the API (which returns newest-first)?
#   Because we filter tags by regex across multiple pages, and the regex match
#   could produce versions in a non-monotonic order (e.g., "release-69-2" and
#   "release-69-10" would sort incorrectly as strings: "10" < "2" alphabetically).
#
# vercmp (from pacman-contrib) understands Arch Linux version ordering, including:
#   - Epoch (e.g., "2:1.0" > "1.99")
#   - Alphanumeric segments ("1.10a" > "1.9z")
#   - Tilde for pre-releases ("1.0~rc1" < "1.0")
# This is more correct than sort -V for version strings found in the wild.
pick_max_version_list() {
  local -a versions=()
  local line
  # IFS=  prevents splitting on whitespace within a line (defensive)
  # -r    prevents backslash interpretation
  while IFS= read -r line; do
    [[ -n "$line" ]] && versions+=("$line")
  done

  if [[ ${#versions[@]} -eq 0 ]]; then
    echo ""
    return 0
  fi

  if command -v vercmp >/dev/null 2>&1; then
    # Linear scan: start with the first version as the current max, then
    # challenge it with each subsequent version. vercmp returns:
    #   1   if first arg is greater
    #   0   if equal
    #   -1  if first arg is lesser
    # We replace max whenever the challenger (v) beats it.
    local max="${versions[0]}"
    local v
    # ${versions[@]:1} — array slice starting at index 1 (skips the first element
    # which is already in max, avoiding an unnecessary self-comparison)
    for v in "${versions[@]:1}"; do
      if [[ "$(vercmp "$v" "$max")" -gt 0 ]]; then
        max="$v"
      fi
    done
    echo "$max"
    return 0
  fi

  # Fallback when vercmp is unavailable: sort -V understands version numbers
  # (e.g., 1.9 < 1.10) unlike plain sort, then take the last line (highest).
  # Less accurate than vercmp for Arch-specific version syntax, but acceptable.
  printf "%s\n" "${versions[@]}" | sort -V | tail -n 1
}

# ============================================================================
# Upstream Version Fetchers
# ============================================================================

# Fetches the latest release tag from the GitHub Releases API.
#
# Two different API endpoints are used depending on the channel:
#
#   stable → /releases/latest
#     Returns a SINGLE release object (not an array): {"tag_name": "v1.2.3", ...}
#     GitHub defines "latest" as the newest non-prerelease, non-draft release.
#     This is the fast path — one request, no pagination needed.
#
#   prerelease/any → /releases?per_page=30
#     Returns an ARRAY of releases, sorted newest-first. We then filter
#     by the prerelease flag. We can't use /releases/latest because that
#     endpoint deliberately excludes pre-releases.
#
# Why this function exists separately from github_latest_release_tag_filtered:
#   This handles the common case (no tag regex needed) with minimal API calls.
#   The filtered variant is for repos whose tags don't follow the convention
#   where the "latest" release is actually the one we want (e.g., repos that
#   mix release types in a single release stream).
github_latest_release_tag() {
  local repo="${1:-}"
  local channel="${2:-stable}"
  [[ -z "$repo" ]] && return 0

  log_debug "github_latest_release_tag: repo=$repo, channel=$channel"

  local url=""
  case "$channel" in
    stable)  url="https://api.github.com/repos/${repo}/releases/latest" ;;
    # prerelease and any both need the array endpoint for filter access
    *)       url="https://api.github.com/repos/${repo}/releases?per_page=30" ;;
  esac

  local response
  response="$(fetch "$url")" || {
    log_debug "Failed to fetch from GitHub API: $url"
    return 1
  }

  # Early exit on API errors before attempting any .tag_name access.
  # A rate-limit response looks like {"message": "API rate limit exceeded..."}
  # and does not have a .tag_name field — jq would return empty, silently
  # hiding the real cause.
  local api_err
  api_err="$(json_api_error_message "$response")"
  if [[ -n "$api_err" ]]; then
    log_debug "GitHub API error for $repo: $api_err"
    return 1
  fi

  local result
  case "$channel" in
    stable)
      # /releases/latest returns a single object; .tag_name is directly accessible.
      # // empty — produce no output rather than the string "null" if absent.
      result=$(echo "$response" | jq -r '.tag_name // empty')
      ;;
    prerelease)
      # The response is an array. Pipeline:
      #   .[]          — iterate over all release objects
      #   select(...)  — keep only ones where .prerelease is true
      #   [...]        — collect matches back into an array (so [0] works safely
      #                  on an empty set without error; returns null instead)
      #   [0]          — take the first (newest, since array is sorted newest-first)
      #   .tag_name    — extract the tag name field
      result=$(echo "$response" | jq -r '[.[] | select(.prerelease==true)][0].tag_name // empty')
      ;;
    any|*)
      # Any channel: just take the newest release regardless of prerelease status.
      result=$(echo "$response" | jq -r '.[0].tag_name // empty')
      ;;
  esac

  echo "$result"
}

# Fetches the latest release tag that matches a regex, paginating through results.
#
# Why this is more complex than github_latest_release_tag:
#   Some repos tag releases inconsistently — e.g., they might publish auxiliary
#   releases (CLI tools, plugins, docs) alongside the main package, or use
#   multiple release series in the same repo. The /releases/latest endpoint
#   returns whatever GitHub considers "latest", which might not be the series
#   we care about. By filtering with a regex we can target a specific release
#   series even if it's not the absolute newest.
#
# Algorithm:
#   1. Fetch pages of up to 100 releases each (GitHub's maximum per_page)
#   2. On each page, filter for the target channel (stable/prerelease/any)
#      AND the tag_regex match
#   3. Take the first match on the first page where a match exists
#   4. Stop when: a match is found, OR a page comes back empty, OR
#      a page has <100 releases (meaning it was the last page), OR
#      we've exceeded max_pages (safety limit)
#
# Note: releases are returned newest-first, so the first match found across
# pages is the newest matching release.
github_latest_release_tag_filtered() {
  local repo="${1:-}"
  local channel="${2:-stable}"
  local tag_regex="${3:-}"
  local max_pages="${4:-10}"
  [[ -z "$repo" || -z "$tag_regex" ]] && return 1

  log_debug "github_latest_release_tag_filtered: repo=$repo, channel=$channel, tag_regex=$tag_regex"

  local page=1
  local result=""

  # Loop exits when result is found OR when pagination exhausted
  while [[ "$page" -le "$max_pages" && -z "$result" ]]; do
    local releases
    releases="$(fetch "https://api.github.com/repos/${repo}/releases?per_page=100&page=${page}")" || {
      log_debug "Failed to fetch releases from GitHub API (page $page)"
      break
    }

    # Validate the response is an array before doing any array operations on it.
    # Rate-limit errors return an object, not an array — without this guard,
    # jq would try to iterate the object's values and .tag_name on strings.
    if ! json_is_array "$releases"; then
      local api_err
      api_err="$(json_api_error_message "$releases")"
      [[ -n "$api_err" ]] && log_debug "GitHub API error for $repo: $api_err"
      break
    fi

    local count
    count=$(echo "$releases" | jq -r 'length' 2>/dev/null || echo 0)
    log_debug "Page $page: $count releases"
    [[ "$count" -eq 0 ]] && break

    case "$channel" in
      stable)
        # jq pipeline:
        #   .[]                            — iterate all releases on this page
        #   select(.prerelease==false)     — skip pre-releases
        #   select(.tag_name | test($re))  — skip tags not matching our regex
        #                                    test() applies the regex; $re is
        #                                    the jq variable bound by --arg
        #   [...]                          — collect remaining into array
        #   [0].tag_name // empty          — take first match's tag (or empty)
        result=$(echo "$releases" | jq -r --arg re "$tag_regex" '
          [.[] | select(.prerelease==false) | select(.tag_name | test($re))][0].tag_name // empty
        ')
        ;;
      prerelease)
        result=$(echo "$releases" | jq -r --arg re "$tag_regex" '
          [.[] | select(.prerelease==true) | select(.tag_name | test($re))][0].tag_name // empty
        ')
        ;;
      any|*)
        # No channel filter — match any release type
        result=$(echo "$releases" | jq -r --arg re "$tag_regex" '
          [.[] | select(.tag_name | test($re))][0].tag_name // empty
        ')
        ;;
    esac

    # If this page had fewer than 100 results, it's the last page — stop paging.
    # (If we got a match, the outer while condition handles the stop.)
    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
  done

  echo "$result"
}

# Fetches git refs matching a tag prefix using GitHub's matching-refs API.
# Returns raw JSON array of ref objects: [{"ref": "refs/tags/v1.2.3", ...}, ...]
#
# Why use matching-refs instead of the standard /tags endpoint?
#   The standard tags endpoint returns ALL tags (e.g., dart-lang/sdk has
#   thousands of tags for every version series). When we only want tags
#   matching "v3.12.*", we'd have to fetch and discard most of them.
#   The matching-refs endpoint does server-side prefix filtering, returning
#   only refs that START with the given prefix — far fewer network round trips
#   and pages to paginate through.
#
# API endpoint pattern:
#   GET /repos/{owner}/{repo}/git/matching-refs/tags/{prefix}
#   e.g., /git/matching-refs/tags/v3.12. → returns only v3.12.x tags
#
# The tradeoff: this API requires knowing the prefix in advance, which is why
# feeds.json has an optional "tagPrefix" field. When absent, we fall back to
# the standard tags endpoint.
github_matching_refs_tags() {
  local repo="${1:-}"
  local prefix="${2:-}"
  local page="${3:-1}"
  local per_page="${4:-100}"
  [[ -z "$repo" || -z "$prefix" ]] && return 1
  log_debug "github_matching_refs_tags: repo=$repo prefix=$prefix page=$page"
  fetch "https://api.github.com/repos/${repo}/git/matching-refs/tags/${prefix}?per_page=${per_page}&page=${page}"
}

# Fetches a single page of tags from the standard GitHub tags endpoint.
# Returns raw JSON array: [{"name": "v1.2.3", "commit": {...}}, ...]
# Note the different shape from matching-refs: "name" not "ref".
github_list_tags_page() {
  local repo="${1:-}"
  local page="${2:-1}"
  local per_page="${3:-100}"
  [[ -z "$repo" ]] && return 1
  log_debug "github_list_tags_page: repo=$repo page=$page"
  fetch "https://api.github.com/repos/${repo}/tags?per_page=${per_page}&page=${page}"
}

# Applies regex filtering and version extraction to a single tag string.
# Designed as a filter: outputs a version string if the tag passes, or
# outputs NOTHING (no lines) if the tag is filtered out. This makes it
# safe to call inside a pipeline — filtered tags simply disappear.
#
# Processing order:
#   1. If tagRegex is set, grep the tag against it. No match → silent return.
#   2. If versionRegex+versionFormat are set, extract version via capture groups.
#   3. Otherwise, normalize the tag (strip v prefix, etc.) and output it.
process_tag_to_version() {
  local tag="${1:-}"
  local tag_regex="${2:-}"
  local version_regex="${3:-}"
  local version_format="${4:-}"

  [[ -z "$tag" ]] && return 0

  if [[ -n "$tag_regex" ]]; then
    # grep -E  extended regex (same syntax as the tagRegex in feeds.json)
    # grep -q  quiet mode: no output, just exit code (0=match, 1=no match)
    # printf '%s\n' is safer than echo for arbitrary strings (won't interpret
    # flags like -e or -n if the tag starts with a dash)
    if ! printf '%s\n' "$tag" | grep -Eq "$tag_regex"; then
      return 0   # silently skip this tag; no output = filtered out
    fi
  fi

  if [[ -n "$version_regex" && -n "$version_format" ]]; then
    # 2>/dev/null suppresses Python's traceback if the regex has a syntax error.
    # || true prevents pipefail from propagating a non-match (exit 2) upward;
    # apply_version_regex exit 2 means no-match, which produces no output —
    # effectively filtering this tag out like a failed tagRegex.
    apply_version_regex "$tag" "$version_regex" "$version_format" 2>/dev/null || true
  else
    normalize_basic_tag_to_version "$tag"
  fi
}

# Paginates through ALL tags in a repo (or a prefix-filtered subset) and
# outputs every version string that matches the configured filters.
# The caller (pick_max_version_list) then selects the maximum from ALL of them.
#
# Why collect all matching versions instead of stopping at the first?
#   GitHub returns tags newest-first on the standard endpoint, but the
#   matching-refs endpoint may not be strictly ordered. Collecting all and
#   then picking the max via vercmp is more correct than assuming ordering.
#
# Two code paths based on whether tagPrefix is configured:
#
#   With tagPrefix (e.g., "v3.12."):
#     Uses the matching-refs API — server-side filtering before pagination.
#     Ideal for repos with many unrelated tag series (python/cpython has
#     thousands of tags; we only want the 3.12.x series).
#     Response shape: [{"ref": "refs/tags/v3.12.0", ...}]
#     Tag name is in .ref, needs "refs/tags/" stripped.
#
#   Without tagPrefix:
#     Uses the standard /tags endpoint — fetches all tags, applies regex locally.
#     Works for repos with fewer tags or where the series can't be prefix-filtered.
#     Response shape: [{"name": "v1.2.3", ...}]
#     Tag name is in .name directly.
#
# Pagination stops when:
#   - A page comes back empty (count == 0): no more tags exist
#   - A page has fewer than 100 tags (count < 100): it's the last page
#   - We hit max_pages: safety limit to prevent infinite loops on huge repos
github_tags_filtered_versions() {
  local repo="${1:-}"
  local tag_regex="${2:-}"
  local version_regex="${3:-}"
  local version_format="${4:-}"
  local tag_prefix="${5:-}"
  local max_pages="${6:-20}"
  [[ -z "$repo" ]] && return 0

  log_debug "github_tags_filtered_versions: repo=$repo tag_regex=$tag_regex tag_prefix=$tag_prefix"

  local page=1
  local total_found=0

  while [[ "$page" -le "$max_pages" ]]; do
    local json=""
    local count=0

    if [[ -n "$tag_prefix" ]]; then
      json="$(github_matching_refs_tags "$repo" "$tag_prefix" "$page" 100 2>/dev/null)" || break

      # Guard: matching-refs returns an array on success, but an error object
      # on rate-limit or 404. Without this check, jq's .[].ref would iterate
      # the object's string values and fail with "Cannot index string with string 'ref'".
      if ! json_is_array "$json"; then
        local api_err
        api_err="$(json_api_error_message "$json")"
        [[ -n "$api_err" ]] && log_debug "GitHub API error for $repo (matching-refs): $api_err"
        break
      fi

      count="$(echo "$json" | jq -r 'length' 2>/dev/null || echo 0)"
      log_debug "Page $page: $count refs from matching-refs"

      if [[ "$count" -gt 0 ]]; then
        # Extract .ref from each element, strip "refs/tags/" prefix to get
        # the bare tag name, then pass each through process_tag_to_version.
        #
        # The `while IFS= read -r tag; do ... done` loop runs in a subshell
        # because it's on the right side of a pipe. This is intentional —
        # we're printing to stdout for the caller to collect, not building
        # a variable. IFS= prevents word splitting on spaces in tag names.
        echo "$json" | jq -r '.[].ref // empty' | sed 's|^refs/tags/||' | while IFS= read -r tag; do
          process_tag_to_version "$tag" "$tag_regex" "$version_regex" "$version_format"
        done
      fi
    else
      json="$(github_list_tags_page "$repo" "$page" 100 2>/dev/null)" || break

      # Same guard as above, but for the standard tags endpoint.
      # The error here would be "Cannot index string with string 'name'"
      # because tags objects have .name (not .ref like matching-refs).
      if ! json_is_array "$json"; then
        local api_err
        api_err="$(json_api_error_message "$json")"
        [[ -n "$api_err" ]] && log_debug "GitHub API error for $repo (tags): $api_err"
        break
      fi

      count="$(echo "$json" | jq -r 'length' 2>/dev/null || echo 0)"
      log_debug "Page $page: $count tags"

      if [[ "$count" -gt 0 ]]; then
        echo "$json" | jq -r '.[].name // empty' | while IFS= read -r tag; do
          process_tag_to_version "$tag" "$tag_regex" "$version_regex" "$version_format"
        done
      fi
    fi

    total_found=$((total_found + count))
    [[ "$count" -eq 0 ]] && break       # empty page = no more data
    [[ "$count" -lt 100 ]] && break     # partial page = last page
    page=$((page + 1))
  done

  log_debug "Total tags processed across $page page(s): $total_found"
}

# ============================================================================
# Source-Specific Version Fetchers
# ============================================================================

# Fetches the Chrome version from Google's Version History API.
#
# The URL-encoded filter string decodes to:
#   endtime=none        — only include currently-active rollouts (not old ones)
#   fraction>=0.5       — only include releases that are at least 50% rolled out
#                         to users. This filters out partial canary rollouts
#                         and ensures we get a version that's genuinely stable.
# order_by=version desc — newest version first, so .releases[0] is the latest.
#
# The channel param maps directly to Chrome's release channels: stable, beta,
# dev, canary. Canary is handled separately via google-chrome-canary-bin.
get_chrome_version_json() {
  local channel="${1:-stable}"
  # Pre-encoded: endtime%3Dnone%2Cfraction%3E%3D0.5 = endtime=none,fraction>=0.5
  local encoded_filter="endtime%3Dnone%2Cfraction%3E%3D0.5"
  local encoded_order="version%20desc"
  local url="https://versionhistory.googleapis.com/v1/chrome/platforms/linux/channels/${channel}/versions/all/releases?filter=${encoded_filter}&order_by=${encoded_order}"
  local response
  response="$(fetch "$url")" || return 1
  # .releases[0].version — first result after order_by=version desc is the newest
  echo "$response" | jq -r '.releases[0].version // empty'
}

# Fetches the Microsoft Edge version from their Linux RPM repository metadata.
#
# Why this is more complex than a simple API call:
#   Microsoft doesn't publish a version API for Edge on Linux — they only
#   maintain an RPM/DEB repository. The version lives inside the repository's
#   package metadata XML, which is gzip-compressed and referenced indirectly
#   via an index file.
#
# Two-step XML parsing chain:
#
#   Step 1: Fetch repomd.xml (the repository index). This contains a <data
#   type="primary"> element whose <location href="..."> attribute points to
#   the gzip-compressed primary package metadata file.
#   XPath used:
#     //*[local-name()="data" and @type="primary"]  — find <data type="primary">
#       using local-name() because the XML may use a default namespace that
#       would otherwise require namespace-aware XPath (messy with xmllint)
#     /*[local-name()="location"]/@href  — get the href attribute of <location>
#     string(...)  — return as a plain string, not an XML node
#
#   Step 2: Fetch the primary.xml.gz, decompress it, and parse for the Edge
#   package entry. RPM metadata uses <entry name="..." ver="..." rel="...">
#   to describe package versions. We look for:
#     [@name='microsoft-edge-stable']  — filter to the Edge package
#     @ver  — the version attribute (RPM uses "ver" not "version")
#     [last()]  — take the last match in case multiple architectures appear
#     string(...)  — plain string output
get_edge_version() {
  local repomd_url="${1:-}"
  [[ -z "$repomd_url" ]] && return 1

  # ${url%/repodata/repomd.xml} strips the longest suffix matching that
  # pattern, giving us the repo base URL to prepend to relative hrefs.
  local base="${repomd_url%/repodata/repomd.xml}"

  local primary_href
  primary_href="$(fetch "$repomd_url" \
    | xmllint --xpath 'string(//*[local-name()="data" and @type="primary"]/*[local-name()="location"]/@href)' - 2>/dev/null)"
  [[ -z "$primary_href" ]] && return 1

  # Pipe chain: fetch gzipped primary.xml → decompress → extract version with XPath
  fetch "${base}/${primary_href}" \
    | gunzip 2>/dev/null \
    | xmllint --xpath "string((//*[local-name()='entry'][@name='microsoft-edge-stable']/@ver)[last()])" - 2>/dev/null
}

# VS Code uses GitHub releases conventionally, so this is just a thin wrapper.
get_vscode_version() {
  normalize_basic_tag_to_version "$(github_latest_release_tag "microsoft/vscode" "stable")"
}

# 1Password CLI v2 publishes version info via a dedicated JSON endpoint used by
# their own auto-updater. The response is a simple object: {"version": "2.x.y"}
get_1password_cli2_version_json() {
  local url="${1:-}"
  [[ -z "$url" ]] && return 1
  local response
  response="$(fetch "$url")" || return 1
  echo "$response" | jq -r '.version // empty'
}

# 1Password desktop app (Linux) publishes version info only via a changelog-style
# web page — there's no structured API. We scrape it with regex.
#
# Why `tr '\n' ' '` before sed:
#   The "Updated to X.Y.Z" text sometimes spans a line break in the HTML.
#   Collapsing the entire document to a single line lets the sed pattern
#   match the version even if it's split across newlines in the raw HTML.
#
# sed flags:
#   -n   suppress default output (only print on explicit p command)
#   -E   extended regex
#   's/.*Updated to (VERSION).*/\1/p'  — capture and print just the version
#
# The version regex captures:
#   [0-9]+(\.[0-9]+)+  — one or more numeric dot-separated segments
#   ([\-][0-9]+)?      — optional hyphen-separated build suffix (e.g., -1)
get_1password_linux_stable_version() {
  local url="${1:-}"
  [[ -z "$url" ]] && return 1
  local html
  html="$(fetch "$url")" || return 1
  echo "$html" \
    | tr '\n' ' ' \
    | sed -n -E 's/.*Updated to ([0-9]+(\.[0-9]+)+([\-][0-9]+)?).*/\1/p' \
    | head -1
}

# Fetches the LM Studio version by following their "latest download" redirect.
#
# Why redirect-following instead of an API:
#   LM Studio has no public version API and doesn't use GitHub releases. But
#   their download endpoint (https://lmstudio.ai/download/latest/linux/x64)
#   redirects to a versioned URL like:
#     https://installers.lmstudio.ai/linux/x64/0.4.1-1/LM-Studio-0.4.1-1-x64.AppImage
#   The version slug (0.4.1-1) is embedded in the path, so we resolve the
#   redirect and parse the slug from the final URL.
#
# Slug format normalization:
#   LM Studio uses "0.4.1-1" where the suffix after the hyphen is a build number.
#   Arch Linux pkgver cannot contain hyphens (makepkg uses hyphen to separate
#   pkgver from pkgrel), so we convert "0.4.1-1" → "0.4.1.1".
#
# BASH_REMATCH:
#   After [[ str =~ regex ]], bash stores capture groups in BASH_REMATCH[].
#   BASH_REMATCH[0] = full match, [1] = first group, [2] = second, etc.
#   For the pattern ^([0-9]+(\.[0-9]+){2,4})-([0-9]+)$:
#     [1] = base version (e.g., "0.4.1")
#     [2] = last segment from (\.[0-9]+) repetition (not useful)
#     [3] = build number (e.g., "1")
get_lmstudio_version() {
  local latest="https://lmstudio.ai/download/latest/linux/x64"
  log_debug "get_lmstudio_version: Resolving latest via redirect: $latest"

  local effective
  effective="$(fetch_effective_url "$latest")" || {
    log_debug "Failed to resolve effective URL for: $latest"
    return 1
  }
  log_debug "Effective URL: $effective"

  # Extract the version slug from the URL path segment after /linux/x64/
  # [^/]+ matches everything up to the next slash (the slug: "0.4.1-1")
  local slug=""
  if [[ "$effective" =~ /linux/x64/([^/]+)/ ]]; then
    slug="${BASH_REMATCH[1]}"
  fi

  if [[ -z "$slug" ]]; then
    log_debug "Could not extract version slug from effective URL"
    return 1
  fi

  # Format 1: "0.4.1-1" — base version + hyphen + build number
  # Convert to "0.4.1.1" for Arch pkgver compatibility
  if [[ "$slug" =~ ^([0-9]+(\.[0-9]+){2,4})-([0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}.${BASH_REMATCH[3]}"
    return 0
  fi

  # Format 2: "0.4.1.1" — already dot-separated (used by some release builds)
  if [[ "$slug" =~ ^[0-9]+(\.[0-9]+){2,5}$ ]]; then
    printf '%s\n' "$slug"
    return 0
  fi

  log_debug "Unrecognized LM Studio slug format: $slug"
  return 1
}

# Fetches the npm package version from the npm registry JSON API.
#
# Scoped packages (e.g., @tessl/cli) need URL encoding:
#   @tessl/cli → @tessl%2Fcli
#   The @ is fine unencoded in URL paths; only the / needs encoding.
#   The registry API treats "/@scope/pkg" and "/@scope%2Fpkg" differently —
#   the %2F form retrieves the full package document (which includes dist-tags),
#   while the un-encoded form might route to a sub-path.
#
# dist-tags: npm packages can have multiple named "channels" (dist-tags) like
#   "latest" (stable), "next" (pre-release), "beta", "canary".
#   .["dist-tags"][$tag] — dynamic field access using the dist_tag jq variable.
#   The bracket notation handles keys with hyphens or special chars.
get_npm_version() {
  local package="${1:-}"
  local dist_tag="${2:-latest}"
  [[ -z "$package" ]] && return 1
  log_debug "get_npm_version: package=$package, dist_tag=$dist_tag"

  # Encode only the slash; @ can remain literal in the URL path
  local encoded_package
  encoded_package="$(printf '%s' "$package" | sed 's|/|%2F|g')"

  local response
  response="$(fetch "https://registry.npmjs.org/${encoded_package}")" || {
    log_debug "Failed to fetch npm registry"
    return 1
  }
  # .["dist-tags"][$tag] — access .dist-tags object with the dynamic tag name.
  # We use ["dist-tags"] instead of .dist-tags because the hyphen would be
  # interpreted as subtraction in plain jq identifier syntax.
  echo "$response" | jq -r --arg tag "$dist_tag" '.["dist-tags"][$tag] // empty'
}

# Fetches the latest stable version of a Python package from PyPI's JSON API.
#
# PyPI's /pypi/{project}/json endpoint returns package metadata including
# .info.version which is the current stable version string. PyPI itself
# determines what's "stable" (excludes pre-releases unless they're the only
# version), so we don't need to filter further for the typical case.
#
# allowPrerelease is read from feeds.json but not yet acted on here — PyPI's
# .info.version already excludes pre-releases by default. Implementing
# pre-release support would require parsing .releases and filtering by
# version classifiers.
get_pypi_version() {
  local project="${1:-}"
  local allow_prerelease="${2:-false}"
  [[ -z "$project" ]] && return 1
  log_debug "get_pypi_version: project=$project"
  local response
  response="$(fetch "https://pypi.org/pypi/${project}/json")" || {
    log_debug "Failed to fetch PyPI API"
    return 1
  }
  echo "$response" | jq -r '.info.version // empty'
}

# Fetches the Snap package version from the Snapcraft Store API.
#
# Why Snap is more complicated than other sources:
#   1. The Snapcraft API v2 REQUIRES the "Snap-Device-Series: 16" header.
#      Without it, the API returns 400 Bad Request. Series 16 corresponds to
#      Ubuntu 16.04's snap base — it's the "universal" series that all modern
#      snaps are published under regardless of the user's actual OS.
#
#   2. Snap packages have a "channel map" — a separate release per channel
#      (stable, candidate, beta, edge). There's no single "latest" endpoint;
#      you must find your channel within the channel-map array.
#
# jq pipeline:
#   .["channel-map"][]         — iterate all channel entries
#   select(.channel.name == $ch) — filter to the target channel by name
#   .version // empty          — extract the version string
#   head -1                    — take first match (there should only be one
#                                per channel, but belt-and-suspenders)
#
# Note: We use a raw curl here instead of the fetch() helper because we need
# to inject the Snap-specific header that fetch() doesn't support.
get_snap_version() {
  local package="${1:-}"
  local channel="${2:-stable}"
  [[ -z "$package" ]] && return 1
  log_debug "get_snap_version: package=$package, channel=$channel"

  local response
  response="$(curl -sSL --max-time "$FETCH_TIMEOUT" \
    -A "$PACKAGE_UPDATE_BOT_USER_AGENT" \
    -H 'Snap-Device-Series: 16' \
    "https://api.snapcraft.io/v2/snaps/info/${package}" 2>/dev/null)" || {
    log_debug "Failed to fetch Snapcraft API"
    return 1
  }

  echo "$response" | jq -r --arg ch "$channel" '
    .["channel-map"][] | select(.channel.name == $ch) | .version // empty
  ' | head -1
}

# Fetches the Flutter SDK version by parsing Flutter's CHANGELOG.md.
#
# Why CHANGELOG.md instead of GitHub releases:
#   Flutter's GitHub releases and tags track the engine commit hashes, not the
#   SDK version numbers that end users care about. The CHANGELOG.md file is
#   maintained by the Flutter team and reflects the actual published SDK versions
#   in descending order.
#
# Parsing strategy:
#   Version section headers appear as:
#     ### [3.41.0](https://github.com/.../releases/tag/3.41.0)  (newer format)
#     ### 3.38.0 (May 10, 2023)                                  (older format)
#   grep -E '^### \[?[0-9]+\.[0-9]+\.[0-9]+'  — match lines starting with ###
#     followed by an optional [ (handles both link and plain formats)
#   head -1  — take the first match (newest, since changelog is newest-first)
#   sed -E 's/^### \[?([0-9]+\.[0-9]+\.[0-9]+).*/\1/'  — extract just the
#     version number, discarding the rest of the line
get_flutter_version() {
  local url="https://raw.githubusercontent.com/flutter/flutter/master/CHANGELOG.md"
  log_debug "get_flutter_version: Fetching changelog from $url"
  local changelog
  changelog="$(fetch "$url")" || { log_debug "Failed to fetch Flutter changelog"; return 1; }
  echo "$changelog" \
    | grep -E '^### \[?[0-9]+\.[0-9]+\.[0-9]+' \
    | head -1 \
    | sed -E 's/^### \[?([0-9]+\.[0-9]+\.[0-9]+).*/\1/'
}

# ============================================================================
# Main Version Detection Dispatcher
# ============================================================================

# Routes each package to its appropriate version fetcher based on the "type"
# field in feeds.json. This is the central switch that maps feed configuration
# to a concrete upstream version string.
#
# All paths produce either:
#   - A non-empty version string on stdout (success)
#   - Empty output (failure to detect — caller interprets as UNKNOWN)
#
# The github-release* and vcs types share an optional post-processing step:
# if versionRegex+versionFormat are configured, the raw tag is further
# transformed. The `|| echo "$tag"` fallback ensures that a failed regex
# (e.g., the tag format changed upstream) degrades gracefully by using the
# normalized tag as-is rather than silently returning empty.
#
# The vcs type shows the latest stable tag for informational display (so you
# can see "VCS package (stable: 1.2.3)"), but VCS packages are never flagged
# as needing an update — they always build from HEAD.
fetch_upstream_version_for_pkg() {
  local feeds_json="${1:-}"
  local pkg="${2:-}"
  [[ -z "$feeds_json" || -z "$pkg" ]] && return 0

  # Read all potentially-needed config fields upfront. Fields absent from
  # feeds.json produce empty strings (not errors) via feeds_json_get_field.
  local type repo channel url tag_regex version_regex version_format tag_prefix

  type="$(feeds_json_get_field "$feeds_json" "$pkg" "type")"
  repo="$(feeds_json_get_field "$feeds_json" "$pkg" "repo")"
  channel="$(feeds_json_get_field "$feeds_json" "$pkg" "channel")"
  url="$(feeds_json_get_field "$feeds_json" "$pkg" "url")"
  tag_regex="$(feeds_json_get_field "$feeds_json" "$pkg" "tagRegex")"
  version_regex="$(feeds_json_get_field "$feeds_json" "$pkg" "versionRegex")"
  version_format="$(feeds_json_get_field "$feeds_json" "$pkg" "versionFormat")"
  tag_prefix="$(feeds_json_get_field "$feeds_json" "$pkg" "tagPrefix")"

  [[ -z "$channel" ]] && channel="stable"  # default channel for all types

  log_debug "Package: $pkg | Type: $type | Repo: $repo | Channel: $channel | TagPrefix: $tag_prefix"

  case "$type" in
    github-release)
      local tag
      tag="$(normalize_basic_tag_to_version "$(github_latest_release_tag "$repo" "$channel")")"
      if [[ -n "$tag" && -n "$version_regex" && -n "$version_format" ]]; then
        apply_version_regex "$tag" "$version_regex" "$version_format" 2>/dev/null || echo "$tag"
      else
        echo "$tag"
      fi
      ;;
    github-release-filtered)
      local tag
      tag="$(normalize_basic_tag_to_version "$(github_latest_release_tag_filtered "$repo" "$channel" "$tag_regex")")"
      if [[ -n "$tag" && -n "$version_regex" && -n "$version_format" ]]; then
        apply_version_regex "$tag" "$version_regex" "$version_format" 2>/dev/null || echo "$tag"
      else
        echo "$tag"
      fi
      ;;
    github-tags-filtered)
      # Collect ALL matching versions across all pages, then pick the max.
      # Unlike github-release-filtered which stops at the first match,
      # this gathers everything and compares properly (needed when tags
      # across pages may not be strictly ordered by version).
      local versions
      versions="$(github_tags_filtered_versions "$repo" "$tag_regex" "$version_regex" "$version_format" "$tag_prefix")"
      pick_max_version_list <<<"$versions"
      ;;
    vcs)
      # VCS packages (-git, etc.) always build from HEAD, so we never flag them
      # as "needs update". But if a repo is configured, we fetch the latest stable
      # tag to display alongside the package (e.g., "VCS package (stable: 1.2.3)")
      # so maintainers can see how far behind HEAD-based builds might be.
      if [[ -n "$repo" ]]; then
        local tag
        tag="$(normalize_basic_tag_to_version "$(github_latest_release_tag "$repo" "stable")")"
        if [[ -n "$tag" && -n "$version_regex" && -n "$version_format" ]]; then
          apply_version_regex "$tag" "$version_regex" "$version_format" 2>/dev/null || echo "$tag"
        else
          echo "$tag"
        fi
      else
        echo ""
      fi
      ;;
    chrome)               get_chrome_version_json "$channel" ;;
    edge)                 get_edge_version "$url" ;;
    vscode)               get_vscode_version ;;
    1password-cli2)       get_1password_cli2_version_json "$url" ;;
    1password-linux-stable) get_1password_linux_stable_version "$url" ;;
    lmstudio)             get_lmstudio_version "${url:-}" ;;
    npm)
      local package dist_tag
      package="$(feeds_json_get_field "$feeds_json" "$pkg" "package")"
      dist_tag="$(feeds_json_get_field "$feeds_json" "$pkg" "distTag")"
      [[ -z "$dist_tag" ]] && dist_tag="latest"
      [[ -z "$package" ]] && { log_debug "npm: No 'package' field for $pkg"; echo ""; return 0; }
      get_npm_version "$package" "$dist_tag"
      ;;
    pypi)
      local project allow_prerelease
      project="$(feeds_json_get_field "$feeds_json" "$pkg" "project")"
      allow_prerelease="$(feeds_json_get_field "$feeds_json" "$pkg" "allowPrerelease")"
      [[ -z "$allow_prerelease" ]] && allow_prerelease="false"
      [[ -z "$project" ]] && { log_debug "pypi: No 'project' field for $pkg"; echo ""; return 0; }
      get_pypi_version "$project" "$allow_prerelease"
      ;;
    snap)
      local package snap_channel
      package="$(feeds_json_get_field "$feeds_json" "$pkg" "package")"
      snap_channel="$channel"
      [[ -z "$package" ]] && { log_debug "snap: No 'package' field for $pkg"; echo ""; return 0; }
      get_snap_version "$package" "$snap_channel"
      ;;
    flutter) get_flutter_version ;;
    manual)  echo "" ;;  # intentionally unversioned; maintained by hand
    "")      log_debug "Empty type for $pkg, treating as manual"; echo "" ;;
    *)       log_warning "Unknown feed type '$type' for $pkg (treating as manual)"; echo "" ;;
  esac
}

# ============================================================================
# PKGBUILD Helpers
# ============================================================================

# Reads the current pkgver from a PKGBUILD file.
#
# Parsing logic:
#   grep '^pkgver='  — anchored at start of line to avoid matching comments
#                      or variables named like mypkgver=
#   head -1          — take first match (defensive; valid PKGBUILDs have exactly one)
#   cut -d'=' -f2-   — split on '=' and take everything from field 2 onward.
#                      'f2-' (not just 'f2') handles versions containing '='
#                      (rare but theoretically possible with some custom pkgver schemes)
#   sed strip quotes — PKGBUILDs can write pkgver='1.2.3' or pkgver="1.2.3" or
#                      pkgver=1.2.3; we normalize all three to the bare version
get_current_pkgver() {
  local pkgbuild_path="${1:-}"
  [[ ! -f "$pkgbuild_path" ]] && echo "" && return 0
  grep -E '^pkgver=' "$pkgbuild_path" | head -1 | cut -d'=' -f2- \
    | sed "s/^[\"']*//; s/[\"']*$//"
}

# Determines whether a package is a VCS (Version Control System) package.
# VCS packages build from source control HEAD and are never flagged as outdated.
#
# Two detection methods (either is sufficient):
#   1. Explicit type: vcs in feeds.json — unambiguous, preferred.
#   2. Name suffix: -git, -hg, -svn, -bzr — the Arch Linux naming convention
#      for VCS packages, used as a fallback for packages in feeds.json that
#      may be listed with a different type or no type at all.
#      The regex -(git|hg|svn|bzr)$ matches at end-of-string ($).
is_vcs_pkg() {
  local feeds_json="${1:-}"
  local pkg="${2:-}"
  local type
  type="$(feeds_json_get_field "$feeds_json" "$pkg" "type")"
  [[ "$type" == "vcs" ]] && return 0
  [[ "$pkg" =~ -(git|hg|svn|bzr)$ ]] && return 0
  return 1
}

# Rewrites pkgver= and pkgrel= in a PKGBUILD to the new upstream version.
#
# Version sanitization:
#   Arch Linux's makepkg uses hyphen as the separator between pkgver and pkgrel
#   in the final package filename (e.g., foo-1.2.3-1-x86_64.pkg.tar.zst).
#   Therefore pkgver CANNOT contain hyphens — they would confuse makepkg's
#   version parsing. We convert all hyphens to underscores: "1.2.3-1" → "1.2.3_1".
#
# Ampersand escaping in sed replacement:
#   In sed's s/pattern/replacement/ syntax, & in the replacement means
#   "insert the entire matched string". If the version string itself contains
#   an & (e.g., a hypothetical "1.0&2"), the sed replacement would become
#   "pkgver=1.0pkgver=.*2" instead of "pkgver=1.0&2". We escape all & → \&.
#   The bash ${var//&/\\&} substitution: // replaces all occurrences, & is the
#   search string, \\& is the replacement (a literal backslash followed by &).
#
# pkgrel reset to 1:
#   pkgrel tracks how many times the package has been rebuilt for the SAME
#   upstream version (e.g., to fix a packaging bug). When upstream version
#   changes, the rebuild count resets to 1.
update_pkgbuild_version() {
  local pkgbuild_path="${1:-}"
  local new_version="${2:-}"

  local clean_version
  clean_version="$(trim "$new_version")"
  clean_version="${clean_version//-/_}"  # hyphens → underscores (Arch pkgver constraint)

  if [[ ! -w "$(dirname "$pkgbuild_path")" ]]; then
    log_warning "Not writable: $(dirname "$pkgbuild_path")"
    return 1
  fi

  # Backup before modifying — allows manual rollback if something goes wrong
  if ! cp "$pkgbuild_path" "${pkgbuild_path}.backup" 2>/dev/null; then
    log_warning "Failed to write backup: ${pkgbuild_path}.backup"
    return 1
  fi

  # -i  in-place edit
  # -E  extended regex (so .* works as expected)
  # ${clean_version//&/\\&}  escape & to prevent sed replacement interpretation
  if ! sed -i -E "s/^pkgver=.*/pkgver='${clean_version//&/\\&}'/" "$pkgbuild_path"; then
    log_warning "Failed to update pkgver in $pkgbuild_path"
    return 1
  fi

  if ! sed -i -E "s/^pkgrel=.*/pkgrel=1/" "$pkgbuild_path"; then
    log_warning "Failed to update pkgrel in $pkgbuild_path"
    return 1
  fi

  return 0
}

# Regenerates source checksums after a version bump.
# Runs in a subshell ( cd "$pkg_dir" && ... ) so the directory change is
# scoped to this operation and doesn't affect the caller's working directory.
update_checksums() {
  local pkg_dir="${1:-}"
  ( cd "$pkg_dir" && updpkgsums )
}

# ============================================================================
# Version Comparison & Status
# ============================================================================

# Compares two version strings and returns a status via exit code.
#
# Return codes (deliberately non-standard to encode three states):
#   0  upstream > current  → update available (the "actionable" case)
#   1  upstream < current  → local is newer than remote (NEWER status)
#   2  upstream == current → up to date (OK status)
#
# Why use exit codes instead of echo output:
#   This function is called inside $(...) capture by status_for, but we need
#   to communicate a three-way result. Exit codes let us do that cleanly
#   without mixing the comparison result with stdout output. The caller uses
#   `case $?` immediately after the call.
#
# vercmp (from pacman-contrib) is the authoritative version comparator for
# Arch Linux packages. It understands:
#   - Epoch prefixes: "1:1.0" > "9.99" (epoch always wins)
#   - Alphanumeric segments: "1.10a" > "1.9z"
#   - Tilde for pre-releases: "1.0~rc1" < "1.0"
# Output: prints "-1", "0", or "1" to stdout and exits 0 in all cases
# (it only exits non-zero on usage errors).
#
# The string comparison fallback uses bash's [[ > ]] which does lexicographic
# ASCII comparison — correct for simple semver but wrong for e.g. "9" vs "10".
compare_versions() {
  local current="${1:-}"
  local upstream="${2:-}"
  log_debug "compare_versions: current='$current' upstream='$upstream'"

  if command -v vercmp >/dev/null 2>&1; then
    local vercmp_result
    # Note argument order: vercmp <upstream> <current>.
    # Returns 1 when upstream > current (update available → our exit 0).
    vercmp_result="$(vercmp "$upstream" "$current")"
    case "$vercmp_result" in
      -1) return 1 ;;   # upstream < current  → local is newer
      0)  return 2 ;;   # upstream == current → up to date
      1)  return 0 ;;   # upstream > current  → update available
    esac
  else
    # Fallback: bash string comparison (ASCII lexicographic order)
    if [[ "$upstream" == "$current" ]]; then
      return 2
    elif [[ "$upstream" > "$current" ]]; then
      return 0
    else
      return 1
    fi
  fi
}

# Derives a human-readable status string for a package given its versions and
# flags. Acts as the single source of truth for what "state" a package is in.
#
# Short-circuit evaluation: each condition returns early so later conditions
# only run when earlier ones are false. The order matters:
#
#   1. NO_FEED   — no entry in feeds.json at all
#   2. MANUAL    — explicitly opted out of auto-detection
#   3. VCS       — never outdated by definition (builds from HEAD)
#   4. UNKNOWN   — couldn't detect upstream (API failure, rate limit, etc.)
#   5. UPDATE    — no current version recorded in PKGBUILD (unusual; treat as needing update)
#   6. compare   — normal comparison; produces UPDATE, OK, or NEWER
#
# UNKNOWN comes before the empty-current check because a failed upstream fetch
# should be reported as UNKNOWN rather than UPDATE (we don't want to blindly
# flag a package as needing an update just because we can't reach the API).
status_for() {
  local current="${1:-}"
  local upstream="${2:-}"
  local has_feed="${3:-}"
  local is_vcs="${4:-}"
  local is_manual="${5:-}"

  [[ "$has_feed" != "true" ]]   && echo "NO_FEED"  && return 0
  [[ "$is_manual" == "true" ]]  && echo "MANUAL"   && return 0
  [[ "$is_vcs" == "true" ]]     && echo "VCS"      && return 0
  [[ -z "$upstream" ]]          && echo "UNKNOWN"  && return 0
  [[ -z "$current" ]]           && echo "UPDATE"   && return 0

  # compare_versions communicates its result purely via exit code.
  # We must capture $? immediately — any subsequent command would overwrite it.
  compare_versions "$current" "$upstream"
  case $? in
    0)  echo "UPDATE"  ;;
    2)  echo "OK"      ;;
    1)  echo "NEWER"   ;;
    *)  echo "UNKNOWN" ;;
  esac
}

# ============================================================================
# Output Formatting
# ============================================================================

print_table_header() {
  # %-30s  left-align in a 30-character-wide field
  printf "\n%-30s %-18s %-18s %-10s\n" "PACKAGE" "CURRENT" "UPSTREAM" "STATUS"
  printf "%-30s %-18s %-18s %-10s\n" \
    "------------------------------" "------------------" "------------------" "----------"
}

# ============================================================================
# CLI Options
# ============================================================================

declare FEEDS_JSON="${FEEDS_JSON:-feeds.json}"  # overridable via environment or --feeds
declare LIST_OUTDATED="false"
declare OUTPUT_JSON="false"
declare APPLY_UPDATES="false"
declare DEBUG="false"
declare -a SPECIFIC_PACKAGES=()

show_usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [packages...]

OPTIONS:
  --feeds <path>        Path to feeds.json (default: feeds.json)
  --apply               Actually update PKGBUILDs (pkgver + checksums)
  --list-outdated       Only output package names needing updates
  --json                Output JSON for scripting
  --debug               Extra diagnostics (shows API errors, rate limits)
  -h, --help            Show this help

Set GITHUB_TOKEN to avoid GitHub API rate limits.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --feeds)         FEEDS_JSON="$2"; shift 2 ;;
      --apply)         APPLY_UPDATES="true"; shift ;;
      --list-outdated) LIST_OUTDATED="true"; shift ;;
      --json)          OUTPUT_JSON="true"; shift ;;
      --debug)         DEBUG="true"; shift ;;
      --dry-run)       shift ;;   # accepted but ignored; default behavior is already dry-run
      -h|--help)       show_usage; exit 0 ;;
      -*)              log_error "Unknown option: $1"; show_usage; exit 1 ;;
      *)               SPECIFIC_PACKAGES+=("$1"); shift ;;  # positional = package name filter
    esac
  done
}

# ============================================================================
# Package Checking
# ============================================================================

# Checks a single package and either reports its status or applies an update.
#
# Return value convention (inverse of what you might expect):
#   0  the package HAD something to do (update available or update applied)
#   1  nothing to do (up to date, manual, VCS, error, etc.)
#
# This is intentional: check_all_packages uses `if check_single_package; then
# ((count++))` to count actionable packages. Returning 0 for "action taken"
# matches bash's success=0 convention while also being the natural counting signal.
check_single_package() {
  local pkg="$1"
  local pkg_dir="${PKG_DIR:-packages}/$pkg"
  local pkgbuild="$pkg_dir/PKGBUILD"

  if [[ ! -d "$pkg_dir" || ! -f "$pkgbuild" ]]; then
    [[ "$LIST_OUTDATED" != "true" && "$OUTPUT_JSON" != "true" ]] && \
      log_error "$pkg: Directory or PKGBUILD not found"
    return 1
  fi

  local has_feed="false"
  feeds_json_has_pkg "$FEEDS_JSON" "$pkg" && has_feed="true"

  if [[ "$has_feed" != "true" ]]; then
    [[ "$LIST_OUTDATED" != "true" && "$OUTPUT_JSON" != "true" ]] && \
      log_warning "$pkg: Not found in feeds.json"
    return 1
  fi

  local type is_manual="false" is_vcs="false"
  type="$(feeds_json_get_field "$FEEDS_JSON" "$pkg" "type")"
  [[ "$type" == "manual" ]] && is_manual="true"
  is_vcs_pkg "$FEEDS_JSON" "$pkg" && is_vcs="true"

  local current upstream
  current="$(get_current_pkgver "$pkgbuild")"
  upstream="$(trim "$(fetch_upstream_version_for_pkg "$FEEDS_JSON" "$pkg")")"

  local status
  status="$(status_for "$current" "$upstream" "$has_feed" "$is_vcs" "$is_manual")"

  # --list-outdated mode: emit only package names, one per line, for scripting
  if [[ "$LIST_OUTDATED" == "true" ]]; then
    [[ "$status" == "UPDATE" ]] && echo "$pkg"
    return 0
  fi

  # --json mode: emit one JSON object per package (caller may jq-filter the stream)
  if [[ "$OUTPUT_JSON" == "true" ]]; then
    # jq -n builds JSON from scratch using --arg bindings (no input needed).
    # This is safer than printf/echo for JSON because jq handles escaping.
    jq -n \
      --arg pkg "$pkg" --arg current "${current:-}" \
      --arg upstream "${upstream:-}" --arg status "$status" \
      '{package: $pkg, current_version: $current, upstream_version: $upstream, status: $status}'
    return 0
  fi

  # Human-readable display: construct a user-friendly upstream version label.
  # For VCS packages: show "1.2.3 (stable)" if we have a stable tag, else "VCS".
  # ${upstream:+${upstream} (stable)} — the :+ expansion: if $upstream is non-empty,
  # expand to "$upstream (stable)"; if empty, expand to nothing (so the next
  # assignment catches it with the :- fallback).
  local upstream_display="$upstream"
  if [[ "$is_manual" == "true" ]]; then
    upstream_display="n/a"
  elif [[ "$is_vcs" == "true" ]]; then
    upstream_display="${upstream:+${upstream} (stable)}"
    upstream_display="${upstream_display:-VCS}"
  elif [[ -z "$upstream_display" ]]; then
    upstream_display="n/a"
  fi

  case "$status" in
    UPDATE)
      if [[ "$APPLY_UPDATES" == "true" ]]; then
        log_info "$pkg: Updating ${current:-n/a} → $upstream_display"
        if update_pkgbuild_version "$pkgbuild" "$upstream"; then
          log_info "$pkg: Updated PKGBUILD"
          if update_checksums "$pkg_dir"; then
            log_success "$pkg: Updated checksums"
          else
            log_warning "$pkg: Failed to update checksums (run updpkgsums manually)"
          fi
          return 0  # action taken
        else
          log_error "$pkg: Failed to update PKGBUILD"
          return 1
        fi
      else
        log_info "$pkg: ${current:-n/a} → $upstream_display (update available)"
        return 0  # update available = actionable
      fi
      ;;
    OK)      log_success "$pkg: up-to-date ($current)";                               return 1 ;;
    NEWER)   log_warning "$pkg: local version ($current) is newer than remote ($upstream)"; return 1 ;;
    MANUAL)  log_info "$pkg: Manual package, skipping version check";                  return 1 ;;
    VCS)     [[ -n "$upstream" ]] && log_info "$pkg: VCS package (stable: $upstream)"; return 1 ;;
    UNKNOWN) log_warning "$pkg: Could not detect remote version";                      return 1 ;;
    *)       return 1 ;;
  esac
}

# Iterates all packages in feeds.json and checks (or updates) each one.
check_all_packages() {
  if [[ ! -f "$FEEDS_JSON" ]]; then
    log_error "feeds.json not found: $FEEDS_JSON"
    return 1
  fi

  local -a all_packages=()

  # Process substitution < <(...) instead of a pipe: if we wrote
  #   feeds_json_list_packages | while IFS= read -r pkg; do all_packages+=...
  # the while loop would run in a subshell (right side of a pipe), and the
  # array assignment would be invisible to the outer shell after the pipe ends.
  # Process substitution keeps the while loop in the current shell context,
  # so the array is populated in the scope we actually use it.
  # sort -u deduplicates in case the same package appears twice in feeds.json.
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && all_packages+=("$pkg")
  done < <(feeds_json_list_packages "$FEEDS_JSON" 2>/dev/null | sort -u)

  if [[ ${#all_packages[@]} -eq 0 ]]; then
    log_error "No packages found in feeds.json"
    return 1
  fi

  [[ "$LIST_OUTDATED" != "true" && "$OUTPUT_JSON" != "true" ]] && print_table_header

  local outdated_count=0 updated_count=0
  for pkg in "${all_packages[@]}"; do
    # check_single_package returns 0 when the package is actionable (has update
    # or was updated), 1 when nothing to do. The if captures that distinction.
    if check_single_package "$pkg"; then
      ((outdated_count++))
      [[ "$APPLY_UPDATES" == "true" ]] && ((updated_count++))
    fi
  done

  if [[ "$LIST_OUTDATED" != "true" && "$OUTPUT_JSON" != "true" ]]; then
    echo ""
    if [[ "$APPLY_UPDATES" == "true" ]]; then
      if [[ $updated_count -eq 0 ]]; then log_success "No packages needed updating"
      else log_success "Updated $updated_count package(s)"; fi
    else
      if [[ $outdated_count -eq 0 ]]; then log_success "All packages are up-to-date"
      else log_info "$outdated_count package(s) need updates"; log_info "Apply: $0 --apply"; fi
    fi
  fi
}

# ============================================================================
# Main
# ============================================================================

main() {
  parse_args "$@"

  # Dependency check: fail fast with a clear message rather than cryptic errors
  # mid-run. updpkgsums (from pacman-contrib) is only needed when --apply is set.
  local -a missing=()
  command -v jq      >/dev/null 2>&1 || missing+=("jq")
  command -v curl    >/dev/null 2>&1 || missing+=("curl")
  command -v python3 >/dev/null 2>&1 || missing+=("python")
  command -v xmllint >/dev/null 2>&1 || missing+=("libxml2")
  [[ "$APPLY_UPDATES" == "true" ]] && ! command -v updpkgsums >/dev/null 2>&1 && missing+=("pacman-contrib")

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing dependencies: ${missing[*]}"
    log_info "Install with: sudo pacman -S ${missing[*]}"
    exit 1
  fi

  if [[ ! -f "$FEEDS_JSON" ]]; then
    log_error "feeds.json not found: $FEEDS_JSON"
    exit 1
  fi

  if [[ ${#SPECIFIC_PACKAGES[@]} -gt 0 ]]; then
    # Named packages on the command line: check only those, in the order given.
    for pkg in "${SPECIFIC_PACKAGES[@]}"; do
      check_single_package "$pkg"
    done
  else
    # No filter: check everything in feeds.json.
    check_all_packages
  fi
}

main "$@"