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
