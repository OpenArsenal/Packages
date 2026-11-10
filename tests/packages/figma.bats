#!/usr/bin/env bats
# File-backed launcher integration test, with a fake Figma executable.

setup() {
  load '../bats/test_helper/common'
  bats_repo_setup
}

@test "Figma launchers honor removal of default flags without preventing startup" {
  (
  local tmp variant launcher args
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/app" "$tmp/config/figma-linux"

  # Replace only the fixed installation directory in the fixture copy.
  cat >"$tmp/app/figma-linux" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$LAUNCH_ARGS"
MOCK
  chmod +x "$tmp/app/figma-linux"

  for variant in figma-linux figma-linux-git; do
    launcher="$tmp/$variant-wrapper"
    args="$tmp/$variant-args"

    sed "s|^_APPDIR=.*|_APPDIR=\"$tmp/app\"|" \
      "$root/packages/$variant/figma-linux.sh" >"$launcher"
    chmod +x "$launcher"

    printf '!--ozone-platform-hint=auto\n--user-flag=value\n' \
      >"$tmp/config/figma-linux/figma-linux-flags.conf"

    LAUNCH_ARGS="$args" XDG_CONFIG_HOME="$tmp/config" bash "$launcher" --from-cli \
      >"$tmp/output" 2>&1 ||
      fail "$variant did not launch after removing a default flag: $(cat "$tmp/output")"

    [[ -f "$args" ]] || fail "$variant did not execute the application"
    if grep -Fxq -- '--ozone-platform-hint=auto' "$args"; then
      fail "$variant did not remove the requested default flag"
    fi
    grep -Fxq -- '--user-flag=value' "$args" ||
      fail "$variant lost the user-configured flag"
    grep -Fxq -- '--from-cli' "$args" ||
      fail "$variant lost the command-line argument"

    rm -f "$tmp/config/figma-linux/figma-linux-flags.conf"
    LAUNCH_ARGS="$args" XDG_CONFIG_HOME="$tmp/config" bash "$launcher" --from-cli \
      >"$tmp/output" 2>&1 ||
      fail "$variant did not launch with its normal defaults"
    grep -Fxq -- '--ozone-platform-hint=auto' "$args" ||
      fail "$variant lost its default flag when no override was configured"
  done
  )
}
