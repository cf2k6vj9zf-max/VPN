#!/usr/bin/env bash
set -euo pipefail

REMOTE_HOST="${1:-root@77.246.105.100}"
REMOTE_ENV_FILE="${2:-/root/vpn-stack.env}"
LOCAL_ENV_FILE="${3:-./config/vpn-stack.env}"
REMOTE_WORKDIR="/root/vpn-stack-bootstrap"

log() {
  printf '[deploy-vpn] %s\n' "$*"
}

require_file() {
  local path="$1"
  [[ -f "${path}" ]] || {
    printf '[deploy-vpn] ERROR: missing file %s\n' "${path}" >&2
    exit 1
  }
}

main() {
  require_file "${LOCAL_ENV_FILE}"
  require_file "./scripts/install_vpn_stack.sh"

  log "creating remote working directory on ${REMOTE_HOST}"
  ssh "${REMOTE_HOST}" "install -d -m 0700 '${REMOTE_WORKDIR}'"

  log "uploading installer and env file"
  scp "./scripts/install_vpn_stack.sh" "${REMOTE_HOST}:${REMOTE_WORKDIR}/install_vpn_stack.sh"
  scp "${LOCAL_ENV_FILE}" "${REMOTE_HOST}:${REMOTE_ENV_FILE}"

  log "running installer remotely"
  ssh "${REMOTE_HOST}" "chmod +x '${REMOTE_WORKDIR}/install_vpn_stack.sh' && bash '${REMOTE_WORKDIR}/install_vpn_stack.sh' '${REMOTE_ENV_FILE}'"

  log "downloading client bundle to ./artifacts/${REMOTE_HOST##*@}"
  mkdir -p "./artifacts/${REMOTE_HOST##*@}"
  scp -r "${REMOTE_HOST}:/root/vpn-clients/." "./artifacts/${REMOTE_HOST##*@}/"
}

main "$@"
