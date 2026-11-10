#!/usr/bin/env bats
# build planning integration tests — existing behavior retained.
# Each test is independently isolated by bats-core; fixture subshells preserve
# the original EXIT-trap cleanup semantics.

setup() {
  load 'test_helper/common'
  bats_repo_setup
}

@test "Builds publish new outputs but reject stale and failed builds" {
  (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  export TMPDIR="$tmp" REPO_DIR="$tmp/repo" REPO_DB="$tmp/repo/db" CHROOT_DIR="$tmp/chroot" REPO_NAME=test
  mkdir -p "$REPO_DIR" "$CHROOT_DIR" "$tmp/demo"
  touch "$tmp/demo/PKGBUILD"
  printf 'pkgbase = demo\n\tpkgver = 1\n\tpkgrel = 1\n\n pkgname = demo\n' >"$tmp/demo/.SRCINFO"
  touch "$REPO_DIR/demo-1-1-x86_64.pkg.tar.zst"

  source "$root/.mise/lib/pkg/metadata.sh"
  source "$root/.mise/lib/pkg/build.sh"
  source "$root/.mise/lib/pkg/resolver.sh"
  source "$root/.mise/lib/repo/update.sh"

  PKG_PLAN=("$tmp/demo")
  makechrootpkg() {
    case "${BUILD_MODE:-new}" in
      new) touch "$REPO_DIR/demo-2-1-x86_64.pkg.tar.zst" ;;
      same) touch "$REPO_DIR/demo-1-1-x86_64.pkg.tar.zst" ;;
      none) : ;;
      fail) return 7 ;;
    esac
  }
  pacman() {
    [[ "$1" == -Qp && "$2" == -- ]] || return 2
    case "${3##*/}" in
      demo-1-1-*) echo 'demo 1-1' ;;
      demo-2-1-*) echo 'demo 2-1' ;;
      *) return 2 ;;
    esac
  }
  repo-add() {
    if [[ "$1" == --help ]]; then echo '--wait-for-lock'; return 0; fi
    printf '%s\n' "$@" >"$tmp/published"
  }
  repo::refresh_sync_db() { touch "$tmp/sync-refreshed"; }

  BUILD_MODE=new pkg::build_plan >"$tmp/log" 2>&1 || fail "new version build failed: $(cat "$tmp/log")"
  grep -qF "$REPO_DIR/demo-2-1-x86_64.pkg.tar.zst" "$tmp/published" || fail 'new build version not published'
  ! grep -qF "$REPO_DIR/demo-1-1-x86_64.pkg.tar.zst" "$tmp/published" || fail 'stale version published'
  [[ -f "$tmp/sync-refreshed" ]] || fail 'sync refresh was skipped'
  [[ -z "$(find "$tmp" -mindepth 1 -maxdepth 1 -name 'tmp.*' -print)" ]] || fail 'build marker leaked on success'

  rm -f -- "$tmp/published" "$REPO_DIR/demo-2-1-x86_64.pkg.tar.zst"
  if BUILD_MODE=none pkg::build_plan >"$tmp/log" 2>&1; then
    fail 'build without a new archive published a stale one'
  fi
  [[ ! -e "$tmp/published" ]] || fail 'stale archive sent to repo-add'
  [[ -z "$(find "$tmp" -mindepth 1 -maxdepth 1 -name 'tmp.*' -print)" ]] || fail 'build marker leaked on failed publish'

  BUILD_MODE=same pkg::build_plan >"$tmp/log" 2>&1 || fail "same-version rebuild failed: $(cat "$tmp/log")"
  grep -qF "$REPO_DIR/demo-1-1-x86_64.pkg.tar.zst" "$tmp/published" || fail 'same-version rebuild not published'

  rm -f -- "$tmp/published"
  if BUILD_MODE=fail pkg::build_plan >"$tmp/log" 2>&1; then
    fail 'failed build reported as success'
  fi
  [[ ! -e "$tmp/published" ]] || fail 'failed build still published'
  [[ -z "$(find "$tmp" -mindepth 1 -maxdepth 1 -name 'tmp.*' -print)" ]] || fail 'build marker leaked on failed build'
  echo 'PASS build (new Git version, stale archive, same-version rebuild, failed build)'
  )
}

@test "Dependency planner preserves version constraints" {
  (
  source "$root/.mise/lib/spec.sh"
  source "$root/.mise/lib/pkg/resolver.sh"
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  REPO_DIR="$tmp/repo"
  pkg::metadata_deps() { echo 'nodejs>=22.12.0'; }
  pkg::dir_outputs_name() { return 1; }
  repo::is_dep_satisfied() { printf '%s|%s|%s\n' "$2" "$3" "$4" >"$tmp/check"; }
  pkg::plan_deps "$tmp/demo" demo || fail 'dependency planning failed'
  [[ "$(cat "$tmp/check")" == 'nodejs|>=|22.12.0' ]] || fail 'planner omitted dependency constraint'
  echo 'PASS deps (planner preserves dependency constraints)'
  )
}

@test "Repository index handles versioned virtual providers" {
  (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/repo"
  export REPO_DB="$tmp/repo/test.db"
  touch "$REPO_DB"
  source "$root/.mise/lib/spec.sh"
  source "$root/.mise/lib/repo/inspect.sh"

  bsdtar() {
    case "$1" in
      -tf) printf 'electron40/desc\nelectron41/desc\n' ;;
      -xOf) cat <<'MOCK'
%NAME%
electron40-castlab
%VERSION%
40.10.6+wvcus
%PROVIDES%
electron-castlab=40.10.6+wvcus
plain-capability

%NAME%
electron41-castlab
%VERSION%
41.10.7+wvcus
%PROVIDES%
electron-castlab=41.10.7+wvcus
MOCK
      ;;
      *) return 2 ;;
    esac
  }
  vercmp() {
    [[ "$1" == "$2" ]] && { echo 0; return 0; }
    case "$1:$2" in
      40.*:41.*|40.*:42.*) echo -1 ;;
      41.*:40.*|41.*:39.*|40.*:39.*) echo 1 ;;
      *) echo "unexpected vercmp: $1 vs $2" >&2; return 3 ;;
    esac
  }

  repo::index_build "$tmp/repo" || fail 'provider index failed'
  repo::is_dep_satisfied "$tmp/repo" electron-castlab '=' '40.10.6+wvcus' || fail 'older exact provider rejected'
  repo::is_dep_satisfied "$tmp/repo" electron-castlab '<' '41.10.7+wvcus' || fail 'older provider failed upper bound'
  repo::is_dep_satisfied "$tmp/repo" electron-castlab '<=' '40.10.6+wvcus' || fail 'older provider failed inclusive upper bound'
  repo::is_dep_satisfied "$tmp/repo" electron-castlab '=' '41.10.7+wvcus' || fail 'newer exact provider rejected'
  repo::is_dep_satisfied "$tmp/repo" electron-castlab '>=' '41.10.7+wvcus' || fail 'newer provider failed lower bound'
  if repo::is_dep_satisfied "$tmp/repo" electron-castlab '<' '40.10.6+wvcus'; then
    fail 'accepted unsatisfied upper bound'
  fi
  if repo::is_dep_satisfied "$tmp/repo" electron-castlab '=' '39.0.0'; then
    fail 'accepted nonexistent provider version'
  fi
  repo::is_dep_satisfied "$tmp/repo" plain-capability '' '' || fail 'unversioned provider disappeared'
  if repo::is_dep_satisfied "$tmp/repo" plain-capability '>=' '40.10.6+wvcus'; then
    fail 'unversioned provider satisfied versioned requirement'
  fi
  repo::is_dep_satisfied "$tmp/repo" electron40-castlab '=' '40.10.6+wvcus' || fail 'package identity lookup changed'
  echo 'PASS provider_versions (multiple providers, exact and upper bounds)'
  )
}

@test "Planning errors and dependency cycles prevent builds" {
  (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  export PKGBUILDS_ROOT="$root" REPO_DIR="$tmp/repo" REPO_DB="$tmp/missing.db"
  mkdir -p "$REPO_DIR" "$tmp/packages"
  source "$root/.mise/lib/repo.sh"
  source "$root/.mise/lib/pkg.sh"

  recipe() {
    local name="$1" dependency="${2:-}"
    local dir="$tmp/packages/$name"
    mkdir -p "$dir"
    printf 'pkgname=%s\npkgver=1\npkgrel=1\n' "$name" >"$dir/PKGBUILD"
    printf 'pkgbase = %s\n\tpkgver = 1\n\tpkgrel = 1\n\npkgname = %s\n' \
      "$name" "$name" >"$dir/.SRCINFO"
    [[ -z "$dependency" ]] || printf '\tdepends = %s\n' "$dependency" >>"$dir/.SRCINFO"
  }

  recipe missing missing-dep
  recipe good
  recipe cycle-a cycle-b
  recipe cycle-b cycle-a

  # Exercise the entire plan/build boundary without Arch or a real chroot.
  repo::is_dep_satisfied() { return 1; }
  pkg::pacman_can_resolve() { return 1; }
  pkg::build_plan() { touch "$tmp/build-ran"; }

  if pkg::build_selected "$tmp/packages" false missing good >"$tmp/log" 2>&1; then
    fail 'build proceeded after unresolved dependency'
  fi
  grep -q 'unresolved dependency' "$tmp/log" || fail 'missing dependency diagnostic disappeared'
  [[ ! -e "$tmp/build-ran" ]] || fail 'build started after an unresolved dependency'

  if pkg::build_selected "$tmp/packages" false cycle-a >"$tmp/log" 2>&1; then
    fail 'build proceeded after dependency cycle'
  fi
  grep -q 'dependency cycle detected' "$tmp/log" || fail 'cycle diagnostic disappeared'
  [[ ! -e "$tmp/build-ran" ]] || fail 'build started after a cycle'

  # A broken database must stop the build before metadata/dependency fallback.
  REPO_DB="$tmp/broken.db"
  touch "$REPO_DB"
  repo::index_reset
  bsdtar() { return 47; }
  if pkg::build_selected "$tmp/packages" false good >"$tmp/log" 2>&1; then
    fail 'build proceeded after repository index read failed'
  fi
  grep -q 'unable to inspect repository database' "$tmp/log" ||
    fail 'repository index failure diagnostic disappeared'
  [[ ! -e "$tmp/build-ran" ]] || fail 'build started with unreadable repository index'

  REPO_DB="$tmp/missing.db"
  repo::index_reset
  pkg::cache_srcinfo() { return 47; }
  if pkg::build_selected "$tmp/packages" false good >"$tmp/log" 2>&1; then
    fail 'build proceeded after metadata indexing failed'
  fi
  [[ ! -e "$tmp/build-ran" ]] || fail 'build started after metadata indexing failed'
  echo 'PASS planner_failures (unresolved deps, cycles, and unreadable metadata or index stop builds)'
  )
}

@test "Versioned dependencies choose compatible local providers" {
  (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  export PKGBUILDS_ROOT="$root" REPO_DIR="$tmp/repo" REPO_DB="$tmp/missing.db"
  mkdir -p "$REPO_DIR" "$tmp/packages"
  source "$root/.mise/lib/repo.sh"
  source "$root/.mise/lib/pkg.sh"

  recipe() {
    local name="$1" dependency="${2:-}" provided="${3:-}"
    local dir="$tmp/packages/$name"
    mkdir -p "$dir"
    touch "$dir/PKGBUILD"
    printf 'pkgbase = %s\n\tpkgver = 1\n\tpkgrel = 1\n\npkgname = %s\n' \
      "$name" "$name" >"$dir/.SRCINFO"
    [[ -z "$dependency" ]] || printf '\tdepends = %s\n' "$dependency" >>"$dir/.SRCINFO"
    [[ -z "$provided" ]] || printf '\tprovides = %s\n' "$provided" >>"$dir/.SRCINFO"
  }

  recipe consumer 'shared>=2'
  recipe impossible 'shared>=3'
  recipe provider-one '' 'shared=1'
  recipe provider-two '' 'shared=2'
  recipe provider-unversioned '' shared

  vercmp() {
    local a="$1" b="$2"
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || return 48
    if (( a < b )); then printf '%s\n' -1
    elif (( a > b )); then printf '%s\n' 1
    else printf '%s\n' 0; fi
  }
  repo::is_dep_satisfied() { return 1; }
  pkg::pacman_can_resolve() { return 1; }

  pkg::plan_selected "$tmp/packages" false consumer >"$tmp/log" 2>&1 ||
    fail "compatible local provider was rejected: $(cat "$tmp/log")"
  [[ "${PKG_PLAN[*]}" == "$tmp/packages/provider-two $tmp/packages/consumer" ]] ||
    fail "versioned dependency selected wrong provider: ${PKG_PLAN[*]}"

  if pkg::plan_selected "$tmp/packages" false impossible >"$tmp/log" 2>&1; then
    fail 'incompatible local provider satisfied a versioned dependency'
  fi
  grep -q 'unresolved dependency' "$tmp/log" ||
    fail 'missing diagnostic for incompatible local provider'
  echo 'PASS versioned_local_providers (compatible alias selected, incompatible rejected)'
  )
}

@test "Split-package publication requires complete output metadata" {
  (
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  export REPO_DIR="$tmp/repo" REPO_DB="$tmp/repo/db"
  mkdir -p "$REPO_DIR"
  source "$root/.mise/lib/pkg/build.sh"
  source "$root/.mise/lib/repo/update.sh"
  touch "$tmp/marker"
  touch -t 200001010000.00 "$tmp/marker"
  touch "$REPO_DIR/alpha-1-1-x86_64.pkg.tar.zst" "$REPO_DIR/beta-1-1-x86_64.pkg.tar.zst"

  pkg::metadata_outputs() {
    printf 'alpha\n'
    if [[ "${OUTPUT_MODE:-complete}" == partial ]]; then return 47; fi
    printf 'beta\n'
  }
  repo::match_package_archives() {
    printf '%s/%s-1-1-x86_64.pkg.tar.zst\n' "$REPO_DIR" "$2"
  }
  repo::add_archives() { printf '%s\n' "${@:5}" >"$tmp/published"; }

  if OUTPUT_MODE=partial pkg::publish_outputs "$tmp/demo" "$tmp/marker" >"$tmp/log" 2>&1; then
    fail 'partial package output metadata was accepted'
  fi
  [[ ! -e "$tmp/published" ]] || fail 'partial package output metadata reached publication'

  OUTPUT_MODE=complete pkg::publish_outputs "$tmp/demo" "$tmp/marker" >"$tmp/log" 2>&1 ||
    fail "complete package output metadata rejected: $(cat "$tmp/log")"
  [[ "$(wc -l <"$tmp/published")" -eq 2 ]] || fail 'complete package output list was not published'
  grep -q '/alpha-1-1-x86_64.pkg.tar.zst' "$tmp/published" || fail 'missing alpha output'
  grep -q '/beta-1-1-x86_64.pkg.tar.zst' "$tmp/published" || fail 'missing beta output'
  echo 'PASS partial_package_outputs (partial output list blocks publication)'
  )
}

@test "Chroot repository setup errors stop subsequent builds" {
  (
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  export TMPDIR="$tmp" REPO_NAME=test
  source "$root/.mise/lib/pkg/resolver.sh"
  PKG_PLAN=("$tmp/first" "$tmp/second")
  chroot_calls=0

  chroot::enable_repo() {
    chroot_calls=$((chroot_calls + 1))
    case "${CHROOT_MODE:-ok}" in
      initial) return 47 ;;
      refresh) (( chroot_calls < 2 )) || return 48 ;;
    esac
    return 0
  }
  pkg::build_dir() { printf '%s\n' "$1" >>"$tmp/built"; }
  pkg::publish_outputs() { printf '%s\n' "$1" >>"$tmp/published"; }

  if CHROOT_MODE=initial pkg::build_plan >"$tmp/log" 2>&1; then
    fail 'build continued after initial chroot repository configuration failed'
  fi
  [[ ! -e "$tmp/built" && ! -e "$tmp/published" ]] ||
    fail 'build or publication began after initial chroot setup failure'

  chroot_calls=0
  if CHROOT_MODE=refresh pkg::build_plan >"$tmp/log" 2>&1; then
    fail 'build continued after chroot repository refresh failed'
  fi
  [[ "$(cat "$tmp/built")" == "$tmp/first" ]] || fail 'build continued past failing chroot refresh'
  [[ "$(cat "$tmp/published")" == "$tmp/first" ]] || fail 'unexpected publication after failing chroot refresh'
  echo 'PASS chroot_setup_failures (configuration errors stop later builds)'
  )
}

@test "Upper-bound dependencies rebuild compatible local providers" {
  (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  export PKGBUILDS_ROOT="$root" REPO_DIR="$tmp/repo" REPO_DB="$tmp/missing.db"
  mkdir -p "$REPO_DIR" "$tmp/packages"
  source "$root/.mise/lib/repo.sh"
  source "$root/.mise/lib/pkg.sh"

  mkdir -p "$tmp/packages/foo" "$tmp/packages/app"
  touch "$tmp/packages/foo/PKGBUILD" "$tmp/packages/app/PKGBUILD"
  printf 'pkgbase = foo\n\tpkgver = 1\n\tpkgrel = 1\n\npkgname = foo\n' >"$tmp/packages/foo/.SRCINFO"
  printf 'pkgbase = app\n\tpkgver = 1\n\tpkgrel = 1\n\tdepends = foo<2\n\npkgname = app\n' >"$tmp/packages/app/.SRCINFO"

  # Model the real repository index with a newer but incompatible foo 3-1.
  # Compare numeric fixture versions, not Arch's implementation of vercmp.
  vercmp() {
    local a="${1%%-*}" b="${2%%-*}"
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || return 47
    if (( a < b )); then printf '%s\n' -1
    elif (( a > b )); then printf '%s\n' 1
    else printf '%s\n' 0; fi
  }
  pkg::pacman_can_resolve() { return 1; }
  repo::index_reset
  REPO_INDEX_DIR="$REPO_DIR"
  REPO_PACKAGE_VERSION[foo]='3-1'

  pkg::plan_selected "$tmp/packages" false app >"$tmp/log" 2>&1 ||
    fail "compatible foo 1 recipe rejected: $(cat "$tmp/log")"
  [[ "${PKG_PLAN[*]}" == "$tmp/packages/foo $tmp/packages/app" ]] ||
    fail "foo 1 must be built before app requiring foo<2: ${PKG_PLAN[*]}"

  # If foo was selected and skipped first, the later constraint must promote
  # that already-visited recipe into the build plan before the application.
  pkg::plan_selected "$tmp/packages" false foo app >"$tmp/log" 2>&1 ||
    fail "compatible foo 1 recipe rejected after earlier selection: $(cat "$tmp/log")"
  [[ "${PKG_PLAN[*]}" == "$tmp/packages/foo $tmp/packages/app" ]] ||
    fail "skipped foo was not restored to the plan: ${PKG_PLAN[*]}"

  # Do not rebuild foo when the repository already satisfies the constraint.
  REPO_PACKAGE_VERSION[foo]='1-1'
  pkg::plan_selected "$tmp/packages" false app >"$tmp/log" 2>&1 ||
    fail "compatible published foo 1 was not accepted: $(cat "$tmp/log")"
  [[ "${PKG_PLAN[*]}" == "$tmp/packages/app" ]] ||
    fail "published compatible foo 1 was unnecessarily rebuilt: ${PKG_PLAN[*]}"

  echo 'PASS published_incompatible_provider (upper bound forces local build, including earlier skipped selection)'
  )
}

@test "Incomplete recipe and dependency metadata abort planning" {
  (
  local tmp stage
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  export PKGBUILDS_ROOT="$root" REPO_DIR="$tmp/repo" REPO_DB="$tmp/missing.db"
  mkdir -p "$REPO_DIR" "$tmp/packages/app"
  touch "$tmp/packages/app/PKGBUILD"
  printf 'pkgbase = app\n\tpkgver = 1\n\tpkgrel = 1\n\npkgname = app\n' \
    >"$tmp/packages/app/.SRCINFO"
  source "$root/.mise/lib/repo.sh"
  source "$root/.mise/lib/pkg.sh"

  pkg::metadata_outputs() {
    printf 'app\n'
    [[ "${METADATA_STAGE:-ok}" != outputs ]] || return 47
  }
  pkg::metadata_provides() {
    if [[ "${METADATA_STAGE:-ok}" == provides ]]; then
      printf 'partial-alias=1\n'
      return 48
    fi
  }
  pkg::metadata_deps() {
    printf 'external>=1\n'
    [[ "${METADATA_STAGE:-ok}" != deps ]] || return 49
  }
  repo::is_dep_satisfied() { return 1; }
  pkg::pacman_can_resolve() { return 0; }
  pkg::build_plan() { touch "$tmp/build-ran"; }

  # Partially successful metadata producers must stop planning rather than
  # letting a truncated list silently reach a package build.
  for stage in outputs provides deps; do
    rm -f -- "$tmp/build-ran"
    if METADATA_STAGE="$stage" pkg::build_selected "$tmp/packages" false app >"$tmp/log" 2>&1; then
      fail "build proceeded after partially failed $stage metadata scan"
    fi
    [[ ! -e "$tmp/build-ran" ]] || fail "build started after failed $stage metadata scan"
    grep -q 'error: unable to' "$tmp/log" ||
      fail "missing error diagnostic for partially failed $stage metadata scan"
  done

  # Check the helper boundaries too: a partial result must never count as
  # a matching output or as a usable versioned virtual provider.
  if METADATA_STAGE=outputs pkg::dir_outputs_name "$tmp/packages/app" app; then
    fail 'partial output metadata was accepted as a matching output'
  else
    [[ "$?" -eq 2 ]] || fail 'output metadata failure status was lost'
  fi
  pkg::resolver_reset
  PKG_PROVIDER_CANDIDATES[partial-alias]="$tmp/packages/app"$'\n'
  repo::version_satisfies() { return 0; }
  if METADATA_STAGE=provides pkg::find_local_provider partial-alias '>=' 1 >"$tmp/log"; then
    fail 'partial provides metadata was accepted as a compatible provider'
  else
    [[ "$?" -eq 2 ]] || fail 'provider metadata failure status was lost'
  fi

  # Valid metadata should still allow the normal build plan to run.
  rm -f -- "$tmp/build-ran"
  METADATA_STAGE=ok pkg::build_selected "$tmp/packages" false app >"$tmp/log" 2>&1 ||
    fail "valid metadata was rejected: $(cat "$tmp/log")"
  [[ -f "$tmp/build-ran" ]] || fail 'valid metadata did not reach the build step'

  # If an incomplete output list starts with an already published package,
  # even a direct skip check must reject it, not mark the recipe satisfied.
  repo::is_dep_satisfied() { return 0; }
  if METADATA_STAGE=outputs pkg::all_outputs_in_repo "$tmp/packages/app" >"$tmp/log" 2>&1; then
    fail 'partial output list incorrectly marked the recipe as published'
  fi
  pkg::resolver_reset
  if METADATA_STAGE=outputs pkg::plan_dir "$tmp/packages/app" >"$tmp/log" 2>&1; then
    fail 'planning continued after incomplete published-output metadata'
  fi
  [[ "${#PKG_PLAN[@]}" -eq 0 ]] || fail 'incomplete output metadata added a recipe to the build plan'

  echo 'PASS planning_metadata_failures (incomplete output, provider and dependency metadata abort planning)'
  )
}

@test "Build publication refuses archives whose symlink targets are outside the served repo" {
  (
  local tmp package archive target
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  export REPO_DIR="$tmp/served repo" REPO_DB="$tmp/served repo/test.db"
  mkdir -p "$REPO_DIR" "$tmp/recipe" "$tmp/outside"
  package="$tmp/recipe"
  archive="$REPO_DIR/demo-1-1-any.pkg.tar.zst"
  target="$tmp/outside/demo-1-1-any.pkg.tar.zst"

  touch "$package/PKGBUILD"
  printf 'pkgbase = demo\n\tpkgver = 1\n\tpkgrel = 1\npkgname = demo\n' >"$package/.SRCINFO"
  printf 'original database\n' >"$REPO_DB"
  cp "$REPO_DB" "$tmp/original.db"
  touch -t 202001010000.00 "$tmp/marker"
  printf 'outside package bytes\n' >"$target"
  ln -s "$target" "$archive"

  source "$root/.mise/lib/pkg/metadata.sh"
  source "$root/.mise/lib/pkg/build.sh"
  source "$root/.mise/lib/repo/update.sh"

  pacman() {
    [[ "$1" == -Qp && "$2" == -- ]] || return 2
    printf 'demo 1-1\n'
  }
  repo-add() {
    if [[ "$1" == --help ]]; then
      printf 'Usage: repo-add --wait-for-lock\n'
      return 0
    fi
    printf '%s\n' "$@" >"$tmp/repo-add-called"
    printf 'published\n' >>"$REPO_DB"
  }

  if pkg::publish_outputs "$package" "$tmp/marker" >"$tmp/log" 2>&1; then
    fail 'build publisher accepted a symlink pointing outside REPO_DIR'
  fi
  grep -Fq 'copy the archive into' "$tmp/log" ||
    fail 'build publisher omitted the archive-location diagnostic'
  [[ ! -e "$tmp/repo-add-called" ]] ||
    fail 'repo-add ran for a build output outside the served repository'
  cmp -s "$REPO_DB" "$tmp/original.db" ||
    fail 'build publisher changed the repository database despite rejection'

  # A real, freshly built archive directly in the repo is still publishable.
  rm "$archive"
  printf 'in-repository package bytes\n' >"$archive"
  pkg::publish_outputs "$package" "$tmp/marker" >"$tmp/log" 2>&1 ||
    fail "build publisher rejected an in-repository archive: $(cat "$tmp/log")"
  [[ -e "$tmp/repo-add-called" ]] ||
    fail 'build publisher did not invoke repo-add for a valid output'
  grep -Fxq "$archive" "$tmp/repo-add-called" ||
    fail 'build publisher selected the wrong archive'
  )
}

@test "Forced selected dependency builds precede consumers even when older version is published" {
  (
  local tmp packages requirement selection
  local -a requested=()

  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  packages="$tmp/packages"
  export REPO_DIR="$tmp/repo" REPO_DB="$tmp/nonexistent.db"
  mkdir -p "$REPO_DIR" "$packages/libdemo" "$packages/app"
  touch "$packages/libdemo/PKGBUILD" "$packages/app/PKGBUILD"

  # A newer libdemo=2-1 is selected locally, while the repository still
  # satisfies libdemo via the published version 1-1.
  printf 'pkgbase = libdemo\n\tpkgver = 2\n\tpkgrel = 1\npkgname = libdemo\n' \
    >"$packages/libdemo/.SRCINFO"

  source "$root/.mise/lib/repo.sh"
  source "$root/.mise/lib/pkg.sh"
  repo::index_reset
  REPO_INDEX_DIR="$REPO_DIR"
  REPO_PACKAGE_VERSION[libdemo]='1-1'

  # In Ubuntu CI, model just the Arch version comparison used in the
  # versioned case. The planner itself and metadata readers remain real.
  vercmp() {
    local a="${1%%-*}" b="${2%%-*}"
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || return 47
    if (( a < b )); then printf '%s\n' -1
    elif (( a > b )); then printf '%s\n' 1
    else printf '%s\n' 0
    fi
  }

  # Cover both an unversioned dependency and a lower-bound constraint
  # already satisfied by the *older* published library.
  for requirement in libdemo 'libdemo>=1'; do
    printf 'pkgbase = app\n\tpkgver = 1\n\tpkgrel = 1\n\tdepends = %s\npkgname = app\n' \
      "$requirement" >"$packages/app/.SRCINFO"
    pkg::metadata_cache_reset

    # Force applies only to explicitly requested recipes, not every package
    # whose outputs are available locally.
    pkg::plan_selected "$packages" true app >"$tmp/log" 2>&1 ||
      fail "forcing only app failed ($requirement): $(cat "$tmp/log")"
    [[ "${#PKG_PLAN[@]}" -eq 1 && "${PKG_PLAN[0]}" == "$packages/app" ]] ||
      fail "forcing app alone unexpectedly rebuilt libdemo ($requirement): ${PKG_PLAN[*]}"

    for selection in 'app libdemo' 'libdemo app'; do
      read -r -a requested <<<"$selection"
      pkg::plan_selected "$packages" true "${requested[@]}" >"$tmp/log" 2>&1 ||
        fail "forced planning failed for $selection ($requirement): $(cat "$tmp/log")"
      [[ "${#PKG_PLAN[@]}" -eq 2 &&
         "${PKG_PLAN[0]}" == "$packages/libdemo" &&
         "${PKG_PLAN[1]}" == "$packages/app" ]] ||
        fail "forced dependency built after its consumer for $selection ($requirement): ${PKG_PLAN[*]}"
    done

    pkg::plan_selected "$packages" false app >"$tmp/log" 2>&1 ||
      fail "normal planning failed ($requirement): $(cat "$tmp/log")"
    [[ "${#PKG_PLAN[@]}" -eq 1 && "${PKG_PLAN[0]}" == "$packages/app" ]] ||
      fail "normal planning rebuilt an already-satisfied published dependency: ${PKG_PLAN[*]}"
  done

  # The currently published libdemo=1 satisfies the upper bound, but the
  # explicitly forced libdemo=2 would replace it before the app is built.
  # Reject this selection during planning, regardless of argument order.
  printf 'pkgbase = app\n\tpkgver = 1\n\tpkgrel = 1\n\tdepends = libdemo<2\npkgname = app\n' \
    >"$packages/app/.SRCINFO"
  pkg::metadata_cache_reset

  # Only a forced consumer can still use the compatible published library
  # when no replacement was explicitly selected.
  pkg::plan_selected "$packages" true app >"$tmp/log" 2>&1 ||
    fail "forcing app alone with a published compatible library failed: $(cat "$tmp/log")"
  [[ "${#PKG_PLAN[@]}" -eq 1 && "${PKG_PLAN[0]}" == "$packages/app" ]] ||
    fail "force app alone incorrectly rebuilt libdemo: ${PKG_PLAN[*]}"

  # The public build entrypoint must never reach build_plan on an
  # incompatible selection, even if a dependency was planned first.
  pkg::build_plan() { touch "$tmp/build-started"; }
  for selection in 'app libdemo' 'libdemo app'; do
    read -r -a requested <<<"$selection"
    rm -f "$tmp/build-started"

    if pkg::plan_selected "$packages" true "${requested[@]}" >"$tmp/log" 2>&1; then
      fail "planner accepted incompatible forced replacement for $selection"
    fi
    grep -Fq "forced replacement of 'libdemo'" "$tmp/log" ||
      fail "missing incompatible forced replacement diagnostic for $selection: $(cat "$tmp/log")"

    if pkg::build_selected "$packages" true "${requested[@]}" >"$tmp/log" 2>&1; then
      fail "build entrypoint accepted incompatible forced replacement for $selection"
    fi
    [[ ! -e "$tmp/build-started" ]] ||
      fail "build started before rejecting incompatible replacement for $selection"
  done
  )
}
