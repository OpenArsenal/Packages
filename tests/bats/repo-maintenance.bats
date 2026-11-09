#!/usr/bin/env bats
# repo maintenance integration tests — existing behavior retained.
# Each test is independently isolated by bats-core; fixture subshells preserve
# the original EXIT-trap cleanup semantics.

setup() {
  load 'test_helper/common'
  bats_repo_setup
}

@test "Pruning preserves indexed archives and refuses unreadable databases" {
  (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/repo"
  export TEST_TMP="$tmp" PKGBUILDS_ROOT="$root" REPO_DIR="$tmp/repo" REPO_DB="$tmp/repo/test.db"
  export PATH="$tmp/bin:$PATH"

  cat > "$tmp/bin/bsdtar" <<'MOCK'
#!/usr/bin/env bash
case "$BSDTAR_MODE:$1" in
  list-fail:-tf) exit 41 ;;
  list-partial-fail:-tf) echo 'kept/desc'; exit 41 ;;
  extract-fail:-xOf) exit 42 ;;
  extract-partial-fail:-xOf) printf '%%NAME%%\nkept\n\n%%VERSION%%\n1-1\n'; exit 42 ;;
  *:-tf) echo 'kept/desc' ;;
  missing-filename:-xOf) printf '%%NAME%%\nkept\n\n%%VERSION%%\n1-1\n' ;;
  *:-xOf) printf '%%FILENAME%%\nkept-1-1-x86_64.pkg.tar.zst\n\n%%NAME%%\nkept\n\n%%VERSION%%\n1-1\n' ;;
  *) exit 2 ;;
esac
MOCK
  cat > "$tmp/bin/pacman" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == -Qp && "$2" == -- ]] || exit 2
case "${3##*/}" in
  kept-*) echo 'kept 1-1' ;;
  orphan-*) echo 'orphan 1-1' ;;
  *) exit 2 ;;
esac
MOCK
  cat > "$tmp/bin/paccache" <<'MOCK'
#!/usr/bin/env bash
touch "$TEST_TMP/paccache-called"
[[ " $* " == *' -d '* && " $* " == *' -v '* ]] || exit 88
if [[ "${PACCACHE_MODE:-ok}" == fail ]]; then
  echo 'kept-1-1-x86_64.pkg.tar.zst'
  exit 43
fi
printf '==> Candidate packages:\nkept-0-1-x86_64.pkg.tar.zst\nkept-1-1-x86_64.pkg.tar.zst\n'
MOCK
  chmod +x "$tmp/bin/"*
  touch "$REPO_DB" "$REPO_DIR/kept-1-1-x86_64.pkg.tar.zst" "$REPO_DIR/kept-1-1-x86_64.pkg.tar.zst.sig" \
    "$REPO_DIR/orphan-1-1-x86_64.pkg.tar.zst" "$REPO_DIR/orphan-1-1-x86_64.pkg.tar.zst.sig"

  for mode in list-fail list-partial-fail extract-fail extract-partial-fail missing-filename; do
    if BSDTAR_MODE="$mode" bash "$root/.mise/tasks/repo/prune" >"$tmp/log" 2>&1; then
      fail "prune succeeded after $mode"
    fi
    [[ -f "$REPO_DIR/kept-1-1-x86_64.pkg.tar.zst" && -f "$REPO_DIR/orphan-1-1-x86_64.pkg.tar.zst" ]] || fail "prune deleted archives after $mode"
    [[ -f "$REPO_DIR/kept-1-1-x86_64.pkg.tar.zst.sig" && -f "$REPO_DIR/orphan-1-1-x86_64.pkg.tar.zst.sig" ]] || fail "prune deleted signatures after $mode"
    [[ ! -e "$tmp/paccache-called" ]] || fail "paccache ran after $mode"
  done

  if BSDTAR_MODE=ok PACCACHE_MODE=fail bash "$root/.mise/tasks/repo/prune" >"$tmp/log" 2>&1; then
    fail 'prune succeeded after paccache failed'
  fi
  [[ -f "$REPO_DIR/orphan-1-1-x86_64.pkg.tar.zst" ]] || fail 'paccache failure removed orphan'

  BSDTAR_MODE=ok bash "$root/.mise/tasks/repo/prune" >"$tmp/log" 2>&1 || fail "successful prune failed: $(cat "$tmp/log")"
  [[ -f "$REPO_DIR/kept-1-1-x86_64.pkg.tar.zst" && -f "$REPO_DIR/kept-1-1-x86_64.pkg.tar.zst.sig" ]] || fail 'prune removed indexed package'
  [[ ! -e "$REPO_DIR/orphan-1-1-x86_64.pkg.tar.zst" && ! -e "$REPO_DIR/orphan-1-1-x86_64.pkg.tar.zst.sig" ]] || fail 'prune did not remove orphan'
  [[ -f "$tmp/paccache-called" ]] || fail 'paccache not called on success'
  for ver in 0 2 3; do
    touch "$REPO_DIR/kept-${ver}-1-x86_64.pkg.tar.zst" "$REPO_DIR/kept-${ver}-1-x86_64.pkg.tar.zst.sig"
  done

  BSDTAR_MODE=ok usage_dry_run=true bash "$root/.mise/tasks/repo/prune" >"$tmp/log" 2>&1 || fail 'prune dry-run failed'
  grep -q 'kept-0-1-x86_64.pkg.tar.zst' "$tmp/log" || fail 'old archive missing from dry-run'
  ! grep -q 'kept-1-1-x86_64.pkg.tar.zst' "$tmp/log" || fail 'published archive listed for deletion'
  [[ -f "$REPO_DIR/kept-0-1-x86_64.pkg.tar.zst" ]] || fail 'dry-run deleted archive'

  BSDTAR_MODE=ok bash "$root/.mise/tasks/repo/prune" >"$tmp/log" 2>&1 || fail 'version retention prune failed'
  [[ ! -e "$REPO_DIR/kept-0-1-x86_64.pkg.tar.zst" && ! -e "$REPO_DIR/kept-0-1-x86_64.pkg.tar.zst.sig" ]] || fail 'old unindexed version not removed'
  for ver in 1 2 3; do
    [[ -f "$REPO_DIR/kept-${ver}-1-x86_64.pkg.tar.zst" && -f "$REPO_DIR/kept-${ver}-1-x86_64.pkg.tar.zst.sig" ]] || fail "published or newer archive deleted: $ver"
  done
  echo 'PASS prune (reader failures, published version retained, old archive deleted, dry-run)'
  )
}

@test "Publication propagates repo-add failures and resets indexes" {
  (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  source "$root/.mise/lib/repo/update.sh"
  repo-add() {
    if [[ "$1" == --help ]]; then echo '--wait-for-lock'; return 0; fi
    printf '%s\n' "$*" >"$tmp/repo-add-args"
    [[ "${REPO_ADD_MODE:-ok}" == ok ]] || return 42
  }
  repo::index_reset() { touch "$tmp/index-reset"; }

  if REPO_ADD_MODE=fail repo::add_archives "$tmp/db" false false false "$tmp/demo.pkg.tar.zst"; then
    fail 'repo-add failure was reported as success'
  else
    [[ "$?" -eq 42 ]] || fail 'repo-add failure status was lost'
  fi
  [[ ! -e "$tmp/index-reset" ]] || fail 'index reset after failed repo-add'

  repo::add_archives "$tmp/db" false false false "$tmp/demo.pkg.tar.zst" || fail 'repo-add success failed'
  [[ -f "$tmp/index-reset" ]] || fail 'index was not reset after successful repo-add'
  grep -q -- '--wait-for-lock' "$tmp/repo-add-args" || fail 'repo-add wait-for-lock behavior changed'
  echo 'PASS publish (repo-add failure propagates; successful add resets cache)'
  )
}

@test "Repository cleanup validates source recipes before changes" {
  (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/empty" "$tmp/empty/not-a-recipe"
  export PKGBUILDS_ROOT="$root" REPO_DB="$tmp/repo.db" REPO_NAME=test PATH="$tmp/bin:$PATH" TEST_TMP="$tmp"
  touch "$REPO_DB"

  cat >"$tmp/bin/bsdtar" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  -tf) echo 'kept/desc' ;;
  -xOf) printf '%%NAME%%\nkept\n\n%%VERSION%%\n1-1\n' ;;
  *) exit 2 ;;
esac
MOCK
  cat >"$tmp/bin/repo-remove" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$TEST_TMP/removed"
MOCK
  chmod +x "$tmp/bin/"*

  for sources in "$tmp/missing" "$tmp/empty"; do
    if PACKAGES_DIR="$sources" bash "$root/.mise/tasks/repo/clean" >"$tmp/log" 2>&1; then
      fail "cleanup accepted a missing or empty source directory: $sources"
    fi
    [[ ! -e "$tmp/removed" ]] || fail 'cleanup modified repository with no recipes'
  done

  mkdir -p "$tmp/empty/kept"
  touch "$tmp/empty/kept/PKGBUILD"
  printf 'pkgbase = kept\n\tpkgname = kept\n' >"$tmp/empty/kept/.SRCINFO"
  PACKAGES_DIR="$tmp/empty" bash "$root/.mise/tasks/repo/clean" >"$tmp/log" 2>&1 || fail "valid cleanup failed: $(cat "$tmp/log")"
  [[ ! -e "$tmp/removed" ]] || fail 'cleanup removed a referenced package'
  grep -q 'already matches' "$tmp/log" || fail 'cleanup did not recognize a matching repository'

  for mode in empty missing-pkgname; do
    if [[ "$mode" == empty ]]; then
      : >"$tmp/empty/kept/.SRCINFO"
    else
      printf 'pkgbase = kept\n\tpkgver = 1\n' >"$tmp/empty/kept/.SRCINFO"
    fi
    if PACKAGES_DIR="$tmp/empty" usage_dry_run=true bash "$root/.mise/tasks/repo/clean" >"$tmp/log" 2>&1; then
      fail "cleanup accepted $mode .SRCINFO"
    fi
    grep -Fq "$tmp/empty/kept" "$tmp/log" || fail "missing offending path for $mode"
    [[ ! -e "$tmp/removed" ]] || fail "cleanup modified repository with $mode metadata"
  done
  echo 'PASS clean_sources (missing source, empty metadata, valid source)'
  )
}

@test "Repository cleanup preserves indexed packages on database errors" {
  (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/packages/kept"
  export PKGBUILDS_ROOT="$root" REPO_DB="$tmp/repo.db" REPO_NAME=test
  export PACKAGES_DIR="$tmp/packages" PATH="$tmp/bin:$PATH" TEST_TMP="$tmp"
  touch "$REPO_DB" "$PACKAGES_DIR/kept/PKGBUILD"
  printf 'pkgbase = kept\n\tpkgname = kept\n' >"$PACKAGES_DIR/kept/.SRCINFO"

  cat >"$tmp/bin/bsdtar" <<'MOCK'
#!/usr/bin/env bash
case "${BSDTAR_MODE:-ok}:$1" in
  list-fail:-tf) exit 41 ;;
  list-partial-fail:-tf) echo 'kept/desc'; exit 41 ;;
  extract-fail:-xOf) exit 42 ;;
  extract-partial-fail:-xOf) printf '%%NAME%%\nkept\n\n%%VERSION%%\n1-1\n'; exit 42 ;;
  *:-tf) printf 'kept/desc\nstale/desc\n' ;;
  *:-xOf) printf '%%NAME%%\nkept\n\n%%VERSION%%\n1-1\n%%NAME%%\nstale\n\n%%VERSION%%\n1-1\n' ;;
  *) exit 2 ;;
esac
MOCK
  cat >"$tmp/bin/repo-remove" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$TEST_TMP/removed"
MOCK
  chmod +x "$tmp/bin/"*

  for mode in list-fail list-partial-fail extract-fail extract-partial-fail; do
    if BSDTAR_MODE="$mode" bash "$root/.mise/tasks/repo/clean" >"$tmp/log" 2>&1; then
      fail "cleanup accepted failed database reader: $mode"
    fi
    [[ ! -e "$tmp/removed" ]] || fail "cleanup modified DB after $mode"
    ! grep -q 'already matches' "$tmp/log" || fail "cleanup reported success after $mode"
  done

  usage_dry_run=true bash "$root/.mise/tasks/repo/clean" >"$tmp/log" 2>&1 || fail 'cleanup dry-run failed'
  [[ "$(cat "$tmp/log")" == stale ]] || fail 'cleanup dry-run listed unexpected entries'
  [[ ! -e "$tmp/removed" ]] || fail 'cleanup dry-run modified database'
  bash "$root/.mise/tasks/repo/clean" >"$tmp/log" 2>&1 || fail 'cleanup failed with readable database'
  [[ "$(tail -n1 "$tmp/removed")" == stale ]] || fail 'cleanup did not remove only stale entry'
  ! grep -q '^kept$' "$tmp/removed" || fail 'cleanup removed an indexed package'
  echo 'PASS clean_db (failed reads abort; dry-run and valid stale removal preserved)'
  )
}

@test "Archive selection chooses the newest version or fails closed" {
  (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  source "$root/.mise/lib/spec.sh"
  source "$root/.mise/lib/repo/inspect.sh"
  source "$root/.mise/lib/repo/update.sh"

  pacman() {
    [[ "$1" == -Qp && "$2" == -- ]] || return 2
    case "$3" in
      "$tmp/demo-1.pkg") printf 'demo 1-1\n' ;;
      "$tmp/demo-2.pkg") printf 'demo 2-1\n' ;;
      *) return 3 ;;
    esac
  }
  vercmp() {
    case "${VERCMP_MODE:-ok}" in
      fail) return 47 ;;
      malformed) printf 'invalid\n'; return 0 ;;
    esac
    [[ "$1:$2" == '2-1:1-1' || "$1:$2" == '2:1' ]] || return 48
    printf '1\n'
  }

  local -a selected=()
  repo::select_newest_archives selected "$tmp/demo-1.pkg" "$tmp/demo-2.pkg" ||
    fail 'valid version selection failed'
  [[ "${selected[*]}" == "$tmp/demo-2.pkg" ]] || fail 'newest archive not selected'

  local mode
  for mode in fail malformed; do
    if VERCMP_MODE="$mode" repo::select_newest_archives selected \
      "$tmp/demo-1.pkg" "$tmp/demo-2.pkg" >"$tmp/log" 2>&1; then
      fail "archive selection accepted $mode comparison"
    fi
  done

  REPO_DB="$tmp/db"
  touch "$REPO_DB"
  repo::db_records() { printf 'P\tdemo\t1\nP\tdemo\t2\n'; }
  if VERCMP_MODE=fail repo::index_build "$tmp/repo" >"$tmp/log" 2>&1; then
    fail 'repository index accepted a failed version comparison'
  fi
  [[ -z "$REPO_INDEX_DIR" && -z "${REPO_PACKAGE_VERSION[demo]+x}" ]] ||
    fail 'failed index retained partially parsed versions'
  if VERCMP_MODE=fail repo::is_dep_satisfied "$tmp/repo" demo '=' 1 >"$tmp/log" 2>&1; then
    fail 'partially built index satisfied a dependency'
  fi
  echo 'PASS archive_selection_errors (newest archive and failed comparisons)'
  )
}

@test "Archive enumeration refuses partial scans before publication" {
  (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  source "$root/.mise/lib/repo/update.sh"

  repo::match_package_archives() {
    printf '%s\n' "$tmp/demo-1.pkg.tar.zst"
    [[ "${ENUM_MODE:-ok}" == ok ]] || return 47
  }
  repo::select_newest_archives() {
    local outvar_name="$1"
    shift
    local -n outvar="$outvar_name"
    outvar=("$@")
  }
  repo::add_archives() {
    printf '%s\n' "${@:5}" >"$tmp/published"
  }

  if ENUM_MODE=partial repo::update_db "$tmp" "$tmp/db" "" false false false false >"$tmp/log" 2>&1; then
    fail 'repository update accepted partially failed archive enumeration'
  fi
  [[ ! -e "$tmp/published" ]] || fail 'repository update published partial archive set'
  grep -q 'unable to enumerate package archives' "$tmp/log" ||
    fail 'archive enumeration failure diagnostic disappeared'

  ENUM_MODE=ok repo::update_db "$tmp" "$tmp/db" "" false false false false >"$tmp/log" 2>&1 ||
    fail "successful archive enumeration was rejected: $(cat "$tmp/log")"
  [[ "$(cat "$tmp/published")" == "$tmp/demo-1.pkg.tar.zst" ]] ||
    fail 'successful archive enumeration was not published'
  echo 'PASS archive_enumeration_failure (partial scan aborts; successful scan publishes)'
  )
}

@test "Archive publication rejects unreadable or malformed metadata" {
  (
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  source "$root/.mise/lib/repo/update.sh"

  repo::match_package_archives() {
    printf '%s\n' "$tmp/demo-1.pkg.tar.zst" "$tmp/demo-2.pkg.tar.zst"
  }
  pacman() {
    [[ "$1" == -Qp && "$2" == -- ]] || return 2
    case "${3##*/}" in
      demo-1.pkg.tar.zst) printf 'demo 1-1\n' ;;
      demo-2.pkg.tar.zst)
        case "${META_MODE:-ok}" in
          unreadable) return 45 ;;
          malformed) printf 'demo\n' ;;
          ok) printf 'demo 2-1\n' ;;
        esac
        ;;
      *) return 3 ;;
    esac
  }
  vercmp() {
    [[ "$1:$2" == '2-1:1-1' ]] || return 47
    printf '1\n'
  }
  repo::add_archives() {
    printf '%s\n' "${@:5}" >"$tmp/published"
  }

  local mode
  for mode in unreadable malformed; do
    rm -f -- "$tmp/published"
    if META_MODE="$mode" repo::update_db "$tmp" "$tmp/db" "" false false false false >"$tmp/log" 2>&1; then
      fail "repository update accepted $mode package metadata"
    fi
    [[ ! -e "$tmp/published" ]] || fail "repository published a partial set after $mode metadata"
  done

  META_MODE=ok repo::update_db "$tmp" "$tmp/db" "" false false false false >"$tmp/log" 2>&1 ||
    fail "valid package metadata rejected: $(cat "$tmp/log")"
  [[ "$(cat "$tmp/published")" == "$tmp/demo-2.pkg.tar.zst" ]] ||
    fail 'valid newest package was not selected'
  echo 'PASS archive_metadata_failures (unreadable metadata blocks publication)'
  )
}

@test "Named archive scans fail if a candidate cannot be inspected" {
  (
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/repo"
  touch "$tmp/repo/demo-1-1-x86_64.pkg.tar.zst" "$tmp/repo/demo-2-1-x86_64.pkg.tar.zst"
  source "$root/.mise/lib/repo/update.sh"

  pacman() {
    [[ "$1" == -Qp && "$2" == -- ]] || return 2
    case "${3##*/}" in
      demo-1-1-*) printf 'demo 1-1\n' ;;
      demo-2-1-*)
        [[ "${ARCHIVE_META_MODE:-ok}" != fail ]] || return 47
        printf 'demo 2-1\n'
        ;;
      *) return 2 ;;
    esac
  }
  vercmp() {
    [[ "$1:$2" == '2-1:1-1' ]] || return 48
    printf '1\n'
  }
  repo::add_archives() { printf '%s\n' "${@:5}" >"$tmp/published"; }

  if ARCHIVE_META_MODE=fail repo::update_db "$tmp/repo" "$tmp/db" demo false false false false >"$tmp/log" 2>&1; then
    fail 'exact-name update published despite unreadable candidate archive'
  fi
  [[ ! -e "$tmp/published" ]] || fail 'partial exact-name archive set was published'
  grep -q 'unable to enumerate package archives' "$tmp/log" ||
    fail 'failed exact-name scan omitted its diagnostic'

  ARCHIVE_META_MODE=ok repo::update_db "$tmp/repo" "$tmp/db" demo false false false false >"$tmp/log" 2>&1 ||
    fail "valid exact-name scan rejected: $(cat "$tmp/log")"
  [[ "$(cat "$tmp/published")" == "$tmp/repo/demo-2-1-x86_64.pkg.tar.zst" ]] ||
    fail 'valid exact-name scan did not select the newest archive'
  echo 'PASS exact_archive_scan_failures (unreadable candidates block updates)'
  )
}

@test "Sync refresh validates DBPath and propagates failures" {
  (
  local tmp mode calls
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  source "$root/.mise/lib/repo/update.sh"

  pacman-conf() {
    [[ "$1" == DBPath ]] || return 2
    case "${DBPATH_MODE:-ok}" in
      fail) printf '%s\n' "$tmp/db"; return 47 ;;
      empty) printf '\n' ;;
      relative) printf 'var/lib/pacman/\n' ;;
      root) printf '/\n' ;;
      slashes) printf '////\n' ;;
      ok) printf '%s/db/../db///\n' "$tmp" ;;
      *) return 2 ;;
    esac
  }
  task::run_root() {
    printf '%s\n' "$*" >>"$tmp/calls"
    case "$1" in
      rm) [[ "${RUN_ROOT_MODE:-ok}" != rm-fail ]] ;;
      pacman) [[ "${RUN_ROOT_MODE:-ok}" != sync-fail ]] ;;
      *) return 2 ;;
    esac
  }

  for mode in fail empty relative root slashes; do
    rm -f -- "$tmp/calls"
    if DBPATH_MODE="$mode" repo::refresh_sync_db demo >"$tmp/log" 2>&1; then
      fail "sync refresh accepted unsafe or failed DBPath: $mode"
    fi
    [[ ! -e "$tmp/calls" ]] || fail "sync cleanup ran after $mode DBPath"
  done

  rm -f -- "$tmp/calls"
  if RUN_ROOT_MODE=rm-fail repo::refresh_sync_db demo >"$tmp/log" 2>&1; then
    fail 'sync refresh reported success after failed cleanup'
  fi
  [[ "$(wc -l <"$tmp/calls")" -eq 1 ]] ||
    fail 'pacman sync started after cleanup failure'
  ! grep -q '^pacman ' "$tmp/calls" ||
    fail 'pacman sync ran after cleanup failure'

  rm -f -- "$tmp/calls"
  if RUN_ROOT_MODE=sync-fail repo::refresh_sync_db demo >"$tmp/log" 2>&1; then
    fail 'sync refresh reported success after pacman -Sy failed'
  fi
  [[ "$(wc -l <"$tmp/calls")" -eq 2 ]] ||
    fail 'sync failure did not run expected cleanup and sync steps'

  rm -f -- "$tmp/calls"
  repo::refresh_sync_db demo >"$tmp/log" 2>&1 ||
    fail "valid sync refresh failed: $(cat "$tmp/log")"
  [[ "$(wc -l <"$tmp/calls")" -eq 2 ]] || fail 'valid sync refresh missed a step'
  grep -Fq "rm -f $tmp/db/sync/demo.db" "$tmp/calls" ||
    fail 'sync cleanup used the wrong pacman DBPath'
  grep -Fq "$tmp/db/sync/demo.files" "$tmp/calls" ||
    fail 'sync cleanup missed repository file index'
  grep -qx 'pacman -Sy --noconfirm' "$tmp/calls" ||
    fail 'valid sync refresh did not invoke pacman -Sy'

  echo 'PASS sync_dbpath_failures (failed and unsafe DBPath, cleanup failures, sync failures)'
  )
}

@test "Pruning rejects repository databases with missing package records" {
  (
  local tmp kept damaged
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/repo"
  export PKGBUILDS_ROOT="$root" REPO_DIR="$tmp/repo" REPO_DB="$tmp/repo/openarsenal.db"
  export TEST_TMP="$tmp" PATH="$tmp/bin:$PATH"
  kept="$REPO_DIR/kept-1-1-x86_64.pkg.tar.zst"
  damaged="$REPO_DIR/damaged-1-1-x86_64.pkg.tar.zst"
  touch "$REPO_DB" "$kept" "$damaged" "$damaged.sig"

  cat >"$tmp/bin/bsdtar" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  -tf) printf 'kept/desc\ndamaged/desc\n' ;;
  -xOf)
    printf '%%NAME%%\nkept\n%%VERSION%%\n1-1\n%%FILENAME%%\nkept-1-1-x86_64.pkg.tar.zst\n'
    printf '%%NAME%%\ndamaged\n'
    if [[ "${DB_MODE:-ok}" == ok ]]; then
      printf '%%VERSION%%\n1-1\n%%FILENAME%%\ndamaged-1-1-x86_64.pkg.tar.zst\n'
    fi
    ;;
  *) exit 2 ;;
esac
MOCK
  cat >"$tmp/bin/paccache" <<'MOCK'
#!/usr/bin/env bash
touch "$TEST_TMP/paccache-called"
MOCK
  cat >"$tmp/bin/pacman" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == -Qp && "$2" == -- ]] || exit 2
printf 'damaged 1-1\n'
MOCK
  chmod +x "$tmp/bin/"*

  if DB_MODE=incomplete bash "$root/.mise/tasks/repo/prune" >"$tmp/log" 2>&1; then
    fail 'pruning accepted a repository database with a missing version record'
  fi
  grep -Fq 'incomplete repository package metadata' "$tmp/log" ||
    fail 'incomplete repository database had no useful diagnostic'
  [[ ! -e "$tmp/paccache-called" ]] ||
    fail 'pruning began before validating all database package records'
  [[ -f "$kept" && -f "$damaged" && -f "$damaged.sig" ]] ||
    fail 'pruning deleted an archive after seeing incomplete database metadata'

  DB_MODE=ok bash "$root/.mise/tasks/repo/prune" >"$tmp/log" 2>&1 ||
    fail "complete repository database was rejected: $(cat "$tmp/log")"
  [[ -f "$tmp/paccache-called" && -f "$kept" && -f "$damaged" && -f "$damaged.sig" ]] ||
    fail 'valid database did not preserve published archives'
  )
}

@test "Pruning refuses missing and empty published repository indexes" {
  (
  local tmp archive
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/repo"
  export PKGBUILDS_ROOT="$root" REPO_DIR="$tmp/repo" REPO_DB="$tmp/repo/test.db"
  export TEST_TMP="$tmp" PATH="$tmp/bin:$PATH"
  archive="$REPO_DIR/orphan-1-1-x86_64.pkg.tar.zst"
  touch "$archive" "$archive.sig"

  cat >"$tmp/bin/bsdtar" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  -tf)
    [[ "${DB_MODE:-empty}" == valid ]] && printf 'kept/desc\n'
    ;;
  -xOf)
    [[ "${DB_MODE:-empty}" == valid ]] || exit 2
    printf '%%FILENAME%%\nkept-1-1-x86_64.pkg.tar.zst\n%%NAME%%\nkept\n%%VERSION%%\n1-1\n'
    ;;
  *) exit 2 ;;
esac
MOCK
  cat >"$tmp/bin/paccache" <<'MOCK'
#!/usr/bin/env bash
touch "$TEST_TMP/paccache-called"
printf 'orphan-1-1-x86_64.pkg.tar.zst\n'
MOCK
  cat >"$tmp/bin/pacman" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == -Qp && "$2" == -- ]] || exit 2
printf 'orphan 1-1\n'
MOCK
  chmod +x "$tmp/bin/"*

  # A missing DB must not turn every candidate into an unindexed archive.
  if bash "$root/.mise/tasks/repo/prune" >"$tmp/log" 2>&1; then
    fail 'pruning accepted a missing repository database'
  fi
  grep -Fq 'refusing to prune without a readable repository database' "$tmp/log" ||
    fail 'missing repository database had no useful diagnostic'
  [[ -f "$archive" && -f "$archive.sig" && ! -e "$tmp/paccache-called" ]] ||
    fail 'pruning touched archives or invoked paccache without a database'

  # An existing but empty index provides no authority to delete archives.
  touch "$REPO_DB"
  if DB_MODE=empty bash "$root/.mise/tasks/repo/prune" >"$tmp/log" 2>&1; then
    fail 'pruning accepted a database with no indexed packages'
  fi
  grep -Fq 'refusing to prune without indexed packages' "$tmp/log" ||
    fail 'empty repository index had no useful diagnostic'
  [[ -f "$archive" && -f "$archive.sig" && ! -e "$tmp/paccache-called" ]] ||
    fail 'pruning touched archives or invoked paccache with an empty index'

  # With usable metadata, pruning should still clean genuinely unindexed archives.
  DB_MODE=valid bash "$root/.mise/tasks/repo/prune" >"$tmp/log" 2>&1 ||
    fail "valid repository pruning failed: $(cat "$tmp/log")"
  [[ -e "$tmp/paccache-called" && ! -e "$archive" && ! -e "$archive.sig" ]] ||
    fail 'valid pruning did not remove the unindexed archive and signature'
  )
}
