#!/bin/bash
# One argument per line in ~/.config/gitbutler-flags.conf; blank lines and
# lines beginning with # are ignored. Arguments are not evaluated as shell code.
flags_file="${XDG_CONFIG_HOME:-${HOME}/.config}/gitbutler-flags.conf"
flags=()
if [[ -f "$flags_file" ]]; then
  while IFS= read -r flag || [[ -n "$flag" ]]; do
    [[ -z "$flag" || "$flag" == \#* ]] && continue
    flags+=("$flag")
  done < "$flags_file"
fi
exec '@GITBUTLER_EXEC@' "${flags[@]}" "$@"
