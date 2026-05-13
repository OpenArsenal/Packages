#!/usr/bin/env bash
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
appname='cherry-studio'
declare -a user_flags=()

# Allow users to override command-line options
if [[ -f "${XDG_CONFIG_HOME}/${appname}-flags.conf" ]]; then
    while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        user_flags+=("${line}")
    done < "${XDG_CONFIG_HOME}/${appname}-flags.conf"
fi

# DO NOT change __ELECTRON__, it's updated by PKGBUILD
exec __ELECTRON__ /usr/lib/${appname}/app.asar "${user_flags[@]}" "$@"