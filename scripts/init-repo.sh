#!/usr/bin/env bash
set -euo pipefail

PACMAN_CONF="/etc/pacman.conf"

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (use sudo)." >&2
    exit 1
  fi
}

backup_conf() {
  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  cp -a "${PACMAN_CONF}" "${PACMAN_CONF}.bak-${ts}"
  echo "Backed up ${PACMAN_CONF} -> ${PACMAN_CONF}.bak-${ts}"
}

section_exists() {
  local name="$1"
  grep -qE "^[[:space:]]*\[${name}\][[:space:]]*$" "${PACMAN_CONF}"
}

append_repo_block() {
  local name="$1"
  local dir="$2"
  cat <<EOF >> "${PACMAN_CONF}"

[${name}]
SigLevel = Optional TrustAll
Server = file://${dir}
EOF
}

init_repo_dir_and_db() {
  local name="$1"
  local dir="$2"
  local db="${dir}/${name}.db.tar"

  mkdir -p "${dir}"
  chmod 755 "${dir}"

  if ! command -v repo-add >/dev/null 2>&1; then
    echo "repo-add not found. Install 'pacman-contrib' first." >&2
    exit 1
  fi

  if [[ -f "${db}" ]]; then
    echo "Repo DB already exists: ${db}"
  else
    echo "Initializing repo DB: ${db}"
    repo-add "${db}" >/dev/null
  fi
}

main() {
  require_root

  # Ask for repo name
  read -rp "Enter the local repo name (e.g., local, myrepo): " REPO_NAME
  REPO_NAME="${REPO_NAME// /}"   # strip spaces just in case
  if [[ -z "${REPO_NAME}" ]]; then
    echo "Repo name cannot be empty." >&2
    exit 1
  fi

  REPO_DIR="/var/local/${REPO_NAME}"

  echo "Checking pacman.conf for [${REPO_NAME}]…"
  if section_exists "${REPO_NAME}"; then
    echo "Repo section [${REPO_NAME}] already present in ${PACMAN_CONF}."
  else
    echo "Repo section not found. Adding it and backing up pacman.conf first."
    backup_conf
    append_repo_block "${REPO_NAME}" "${REPO_DIR}"
    echo "Added [${REPO_NAME}] -> Server=file://${REPO_DIR}"
  fi

  echo "Setting up directory and database at ${REPO_DIR}…"
  init_repo_dir_and_db "${REPO_NAME}" "${REPO_DIR}"

  echo
  echo "Done."
  echo "You can now drop .pkg.tar.* files into ${REPO_DIR} and update the DB with:"
  echo "  repo-add ${REPO_DIR}/${REPO_NAME}.db.tar ${REPO_DIR}/*.pkg.tar.*"
  echo
  echo "Install packages via pacman/paru like any other repo, e.g.:"
  echo "  paru -S <pkgname>"
}

main "$@"
