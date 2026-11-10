#!/usr/bin/env bats
# Verify that the pinned helper libraries are installed and discoverable via mise.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  bats_load_library bats-file
}

@test "mise makes Bats assertions and filesystem helpers available" {
  run bash -c 'printf "ready\\n"'
  assert_success
  assert_output "ready"

  local fixture="$BATS_TEST_TMPDIR/fixture"
  printf 'fixture\\n' >"$fixture"
  assert_file_exists "$fixture"
}
