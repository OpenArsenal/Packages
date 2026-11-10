#!/usr/bin/env bash
# Fetch pinned Bash-only Bats helper libraries for local and CI tests.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
library_root="$repo_root/.mise/vendor/bats"
mkdir -p -- "$library_root"

install_bats_library() {
  local name="$1" version="$2"
  local target="$library_root/$name"
  local temp

  if [[ -f "$target/.installed-version" && -f "$target/load.bash" ]] &&
     [[ "$(<"$target/.installed-version")" == "$version" ]]; then
    return 0
  fi

  temp="$(mktemp -d "$library_root/.$name.XXXXXXXX")"
  if ! git clone --quiet --depth 1 --branch "v$version" --single-branch \
      "https://github.com/bats-core/$name.git" "$temp"; then
    rm -rf -- "$temp"
    printf 'error: could not install %s v%s\n' "$name" "$version" >&2
    return 1
  fi
  if [[ ! -f "$temp/load.bash" ]]; then
    rm -rf -- "$temp"
    printf 'error: missing load.bash in %s v%s\n' "$name" "$version" >&2
    return 1
  fi

  printf '%s\n' "$version" >"$temp/.installed-version"
  rm -rf -- "$target"
  mv -- "$temp" "$target"
}

install_bats_library bats-support 0.3.0
install_bats_library bats-assert 2.2.4
install_bats_library bats-file 0.4.0

printf 'Bats helper libraries ready at %s\n' "$library_root"
