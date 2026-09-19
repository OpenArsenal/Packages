# shellcheck shell=bash

repo::pacman_stanza() {
  local repo_name="$1"
  local repo_dir="$2"
  local sig_level="$3"

  cat <<EOF
[$repo_name]
SigLevel = $sig_level
Server = file://$repo_dir
EOF
}
