#!/usr/bin/env bash
set -euo pipefail

_APPDIR="/usr/lib/figma-linux"
_RUN_ASAR="${_APPDIR}/app.asar"

_XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-"${HOME}/.config"}"
_FLAGS_FILE="${_XDG_CONFIG_HOME}/figma-linux/figma-linux-flags.conf"

# Default env that helps most people.
: "${ELECTRON_OZONE_PLATFORM_HINT:=auto}"
export ELECTRON_OZONE_PLATFORM_HINT

# Default flags: keep these conservative.
declare -a DEFAULT_FLAGS=(
	"--ozone-platform-hint=auto"
)

declare -a USER_FLAGS=()
declare -a REMOVE_FLAGS=()

trim_line() {
	local s="$1"
	s="${s#"${s%%[![:space:]]*}"}"
	s="${s%"${s##*[![:space:]]}"}"
	printf '%s' "${s}"
}

# Read flags file:
# - normal lines: add to USER_FLAGS
# - lines starting with ! : remove from DEFAULT_FLAGS by exact match
if [[ -f "${_FLAGS_FILE}" ]]; then
	while IFS= read -r line || [[ -n "${line}" ]]; do
		line="$(trim_line "${line}")"
		[[ -z "${line}" ]] && continue
		[[ "${line}" == \#* ]] && continue

		if [[ "${line}" == \!* ]]; then
			REMOVE_FLAGS+=("${line:1}")
		else
			USER_FLAGS+=("${line}")
		fi
	done < "${_FLAGS_FILE}"
fi

# Remove defaults requested by user.
if [[ "${#REMOVE_FLAGS[@]}" -gt 0 ]]; then
	declare -a FILTERED_DEFAULTS=()

	for d in "${DEFAULT_FLAGS[@]}"; do
		local keep="1"
		for r in "${REMOVE_FLAGS[@]}"; do
			if [[ "${d}" == "${r}" ]]; then
				keep="0"
				break
			fi
		done

		if [[ "${keep}" == "1" ]]; then
			FILTERED_DEFAULTS+=("${d}")
		fi
	done

	DEFAULT_FLAGS=("${FILTERED_DEFAULTS[@]}")
fi

if [[ ! -r "${_RUN_ASAR}" ]]; then
	echo "figma-linux: missing ${_RUN_ASAR}" >&2
	exit 1
fi

cd "${_APPDIR}"

# Root fallback only (don’t pre-enable for everyone).
if [[ "${EUID}" -eq 0 ]]; then
	exec electron "${_RUN_ASAR}" --no-sandbox "${DEFAULT_FLAGS[@]}" "${USER_FLAGS[@]}" "$@"
fi

# Order matters: defaults first, then user, then CLI args
# (later flags tend to win when duplicates exist).
exec electron "${_RUN_ASAR}" "${DEFAULT_FLAGS[@]}" "${USER_FLAGS[@]}" "$@"
