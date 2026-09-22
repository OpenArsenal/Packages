# shellcheck shell=bash

repo::pacman_stanza() {
  local repo_name="$1"
  local repo_dir="$2"

  cat <<EOF
[$repo_name]
SigLevel = Optional TrustAll
Server = file://$repo_dir
EOF
}
