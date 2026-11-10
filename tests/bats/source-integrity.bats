#!/usr/bin/env bats
# Shared local-source checksum verifier integration tests.

setup() {
  load 'test_helper/common'
  bats_repo_setup
}

@test "Local source verifier rejects mismatched checksums" {
  (
  local tmp checksum
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/demo"
  printf 'original file\n' >"$tmp/demo/script.sh"
  printf 'post_install() { :; }\n' >"$tmp/demo/demo.install"
  checksum="$(sha512sum "$tmp/demo/script.sh")" || fail 'could not hash fixture'
  checksum="${checksum%% *}"
  printf 'pkgbase = demo\n\tinstall = demo.install\n\tsource = script.sh\n\tsha512sums = %s\n' "$checksum" >"$tmp/demo/.SRCINFO"

  python3 "$root/tests/check-local-source-checksums.py" "$tmp/demo" >"$tmp/log" 2>&1 ||
    fail "valid local checksum was rejected: $(cat "$tmp/log")"

  printf 'changed file\n' >"$tmp/demo/script.sh"
  if python3 "$root/tests/check-local-source-checksums.py" "$tmp/demo" >"$tmp/log" 2>&1; then
    fail 'stale local checksum was accepted'
  fi
  grep -Fq 'sha512sums mismatch for script.sh' "$tmp/log" ||
    fail 'stale local checksum did not identify its source file'

  printf 'original file\n' >"$tmp/demo/script.sh"
  rm -f "$tmp/demo/demo.install"
  if python3 "$root/tests/check-local-source-checksums.py" "$tmp/demo" >"$tmp/log" 2>&1; then
    fail 'missing package installation hook was accepted'
  fi
  grep -Fq 'missing install script: demo.install' "$tmp/log" ||
    fail 'missing installation hook did not identify the expected file'
  )
}

@test "Local source verifier handles architecture-specific sources, SKIP and count mismatches" {
  (
  local tmp checksum arch_checksum
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/demo"
  printf 'main source\n' >"$tmp/demo/main.sh"
  printf 'ARM source\n' >"$tmp/demo/arm.sh"
  checksum="$(sha256sum "$tmp/demo/main.sh")"
  checksum="${checksum%% *}"
  arch_checksum="$(sha256sum "$tmp/demo/arm.sh")"
  arch_checksum="${arch_checksum%% *}"

  # Remote archives are not fetched; local and per-architecture checksums
  # must still be validated independently.
  printf 'pkgbase = demo\n\tsource = main.sh\n\tsource = https://example.invalid/remote.tar.gz\n\tsha256sums = %s\n\tsha256sums = SKIP\n\tsource_aarch64 = arm.sh\n\tsha256sums_aarch64 = %s\n' \
    "$checksum" "$arch_checksum" >"$tmp/demo/.SRCINFO"
  cp "$tmp/demo/.SRCINFO" "$tmp/original-srcinfo"

  python3 "$root/tests/check-local-source-checksums.py" "$tmp/demo" >"$tmp/log" 2>&1 ||
    fail "valid architecture-specific and remote sources were rejected: $(cat "$tmp/log")"

  printf 'changed ARM source\n' >"$tmp/demo/arm.sh"
  if python3 "$root/tests/check-local-source-checksums.py" "$tmp/demo" >"$tmp/log" 2>&1; then
    fail 'stale aarch64 checksum was accepted'
  fi
  grep -Fq 'sha256sums_aarch64 mismatch for arm.sh' "$tmp/log" ||
    fail 'architecture-specific mismatch was not diagnosed'

  rm -f -- "$tmp/demo/arm.sh"
  if python3 "$root/tests/check-local-source-checksums.py" "$tmp/demo" >"$tmp/log" 2>&1; then
    fail 'missing architecture-specific source was accepted'
  fi
  grep -Fq 'missing local source: arm.sh' "$tmp/log" ||
    fail 'missing architecture-specific source was not diagnosed'

  printf 'ARM source\n' >"$tmp/demo/arm.sh"
  sed '/sha256sums = SKIP/d' "$tmp/original-srcinfo" >"$tmp/demo/.SRCINFO"
  if python3 "$root/tests/check-local-source-checksums.py" "$tmp/demo" >"$tmp/log" 2>&1; then
    fail 'checksum/source count mismatch was accepted'
  fi
  grep -Fq 'sha256sums has 1 entries but source has 2' "$tmp/log" ||
    fail 'checksum/source count mismatch was not diagnosed'
  )
}
