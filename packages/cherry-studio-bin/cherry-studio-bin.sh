#!/bin/bash
set -e

appdir="/opt/cherry-studio"
runname="${appdir}/CherryStudio"

export PATH="${appdir}:${appdir}/usr/sbin:${PATH}"
export LD_LIBRARY_PATH="${appdir}:${appdir}/usr/lib:${appdir}/swiftshader:${LD_LIBRARY_PATH}"
export XDG_DATA_DIRS="${appdir}/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export GSETTINGS_SCHEMA_DIR="${appdir}/usr/share/glib-2.0/schemas:${GSETTINGS_SCHEMA_DIR}"
export ELECTRON_OZONE_PLATFORM_HINT="${ELECTRON_OZONE_PLATFORM_HINT:-auto}"
export ELECTRON_IS_DEV=0
export ELECTRON_FORCE_IS_PACKAGED=true
export ELECTRON_DISABLE_SECURITY_WARNINGS=true
export NODE_ENV=production

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
flags_file="${XDG_CONFIG_HOME}/cherry-studio-flags.conf"
declare -a flags

if [[ -f "${flags_file}" ]]; then
   mapfile -t lines < "${flags_file}"
   for line in "${lines[@]}"; do
      if [[ ! "${line}" =~ ^[[:space:]]*#.* ]] && [[ -n "${line}" ]]; then
         flags+=("${line}")
      fi
   done
fi

cd "${appdir}"
if [[ "${EUID}" -ne 0 ]] || [[ "${ELECTRON_RUN_AS_NODE}" ]]; then
   exec "${runname}" "${flags[@]}" "$@"
else
   exec "${runname}" --no-sandbox "${flags[@]}" "$@"
fi