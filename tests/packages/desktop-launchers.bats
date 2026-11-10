#!/usr/bin/env bats
# Launch actual package wrappers with temporary flags files and a fake executable.

setup() {
  load '../bats/test_helper/common'
  bats_repo_setup
}

@test "VS Code and Chrome launchers load flags from XDG paths containing spaces" {
  (
  local tmp config variant script executable config_name wrapper
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  config="$tmp/config directory with spaces"
  mkdir -p "$config"

  cat >"$tmp/fake-app" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FLAG_LOG"
MOCK
  chmod +x "$tmp/fake-app"

  for variant in code stable canary; do
    case "$variant" in
      code)
        script="$root/packages/visual-studio-code/visual-studio-code.sh"
        executable="/opt/visual-studio-code/bin/code"
        config_name=code-flags.conf
        ;;
      stable)
        script="$root/packages/google-chrome-ffmpeg/google-chrome-stable.sh"
        executable="/opt/google/chrome/google-chrome"
        config_name=chrome-flags.conf
        ;;
      canary)
        script="$root/packages/google-chrome-canary-ffmpeg/google-chrome-canary.sh"
        executable="/opt/google/chrome-canary/google-chrome-canary"
        config_name=chrome-canary-flags.conf
        ;;
    esac

    printf '# ignored comment\n--configured=value\n' >"$config/$config_name"
    wrapper="$tmp/wrapper-$variant"
    sed "s#$executable#$tmp/fake-app#g" "$script" >"$wrapper"
    chmod +x "$wrapper"

    rm -f -- "$tmp/args"
    XDG_CONFIG_HOME="$config" FLAG_LOG="$tmp/args" \
      bash "$wrapper" --from-command-line=ok >"$tmp/log" 2>&1 ||
      fail "$variant wrapper failed with an XDG config path containing spaces: $(cat "$tmp/log")"

    [[ -f "$tmp/args" ]] || fail "$variant did not execute the application"
    grep -Fxq -- '--configured=value' "$tmp/args" ||
      fail "$variant lost configured flags when XDG_CONFIG_HOME has spaces"
    grep -Fxq -- '--from-command-line=ok' "$tmp/args" ||
      fail "$variant lost command-line arguments"
    [[ "$(wc -l <"$tmp/args")" -eq 2 ]] ||
      fail "$variant forwarded unexpected extra arguments"
  done
  )
}
