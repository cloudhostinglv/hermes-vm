#!/usr/bin/env bash
# apply.sh — host-side applier for the Hermes per-client VM (CloudHosting AI Panel).
#
# The web panel container is UNPRIVILEGED: it can only WRITE to the shared data
# volume and then `touch <data>/.apply-request`. It cannot reach docker. This script
# runs ON THE HOST (via a systemd path unit watching .apply-request) and is the only
# thing allowed to drive docker compose. Keeping docker control on the host — not in
# the web surface — is the whole point.
#
# For Hermes this maps to:
#   docker compose -f /opt/hermes-vm/docker-compose.yml restart gateway
# so the agent re-reads the config.yaml + .env the panel just wrote.
#
# RESTART vs UP -d (decision):
#   The gateway service has NO `env_file:` and carries NO provider/Telegram
#   secrets in its compose `environment:` block. All agent secrets live in the
#   DATA DIR (/opt/data/config.yaml + /opt/data/.env, a bind mount), and Hermes
#   loads them itself at PROCESS START. `docker compose restart` restarts the
#   process in the existing container, so on the next start the agent re-reads
#   the freshly-written data-dir files. There is no compose-level env to
#   re-evaluate, so `up -d` (which would recreate the container) is unnecessary.
#   => `restart` is the correct, lighter operation here.
#   If you ever move a secret back into the compose `environment:`/`env_file:`
#   (don't — the panel is the source of truth), switch this to `up -d gateway`
#   so compose re-evaluates it. See README "Reload behaviour".
#
# Paths default to the Hermes layout but can be overridden via env or
# /etc/cloudhosting-panel.env:
#   PRODUCT             hermes (fixed for this VM)
#   COMPOSE_FILE        absolute path to docker-compose.yml (default /opt/hermes-vm/docker-compose.yml)
#   COMPOSE_PROJECT_DIR dir to run compose from (default dirname COMPOSE_FILE)
#   DATA_DIR            the shared data dir (default /opt/hermes-vm/data)
#
# Idempotent and safe to re-run.

set -euo pipefail

ENV_FILE="${PANEL_APPLIER_ENV:-/etc/cloudhosting-panel.env}"
# shellcheck disable=SC1090
[ -f "${ENV_FILE}" ] && . "${ENV_FILE}"

PRODUCT="${PRODUCT:-${1:-hermes}}"
COMPOSE_FILE="${COMPOSE_FILE:-/opt/hermes-vm/docker-compose.yml}"
DATA_DIR="${DATA_DIR:-/opt/hermes-vm/data}"

log() { printf '[applier %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { printf '[applier ERROR] %s\n' "$*" >&2; exit 1; }

# This applier ships in the hermes-vm repo: the only product it serves is Hermes.
case "${PRODUCT}" in
  hermes) SERVICE="gateway" ;;
  *)      die "This applier is for PRODUCT=hermes only (got '${PRODUCT}')." ;;
esac

command -v docker >/dev/null 2>&1 || die "docker not found on host."
docker compose version >/dev/null 2>&1 || die "docker compose v2 required."

[ -f "${COMPOSE_FILE}" ] || die "COMPOSE_FILE not found: ${COMPOSE_FILE}. Set it in ${ENV_FILE}."

PROJECT_DIR="${COMPOSE_PROJECT_DIR:-$(dirname "${COMPOSE_FILE}")}"

# --- pairing approve/revoke (if the panel queued one) ----------------------
# The panel (unprivileged) can't exec the gateway CLI, so to approve a user who
# messaged the bot it drops a tiny KEY=VALUE request file and touches
# .apply-request (which fired this run). If that file is present, run the
# gateway's native pairing CLI instead of a plain restart. Inputs are validated
# here (defense in depth) before being passed to the CLI.
PAIRING_REQ="${DATA_DIR}/.pairing-request"
if [ -f "${PAIRING_REQ}" ]; then
  P_ACTION="$(sed -n 's/^action=\(.*\)$/\1/p'   "${PAIRING_REQ}" | head -n1)"
  P_PLATFORM="$(sed -n 's/^platform=\(.*\)$/\1/p' "${PAIRING_REQ}" | head -n1)"
  P_CODE="$(sed -n 's/^code=\(.*\)$/\1/p'        "${PAIRING_REQ}" | head -n1)"
  rm -f "${PAIRING_REQ}"
  case "${P_ACTION}" in
    approve|revoke) : ;;
    *) die "invalid pairing action: '${P_ACTION}'" ;;
  esac
  printf '%s' "${P_PLATFORM}" | grep -Eq '^[a-z_]{2,20}$'   || die "invalid pairing platform: '${P_PLATFORM}'"
  printf '%s' "${P_CODE}"     | grep -Eq '^[a-f0-9]{6,64}$' || die "invalid pairing code"
  log "Pairing: hermes pairing ${P_ACTION} ${P_PLATFORM} <code>"
  docker compose --project-directory "${PROJECT_DIR}" -f "${COMPOSE_FILE}" \
    exec -T "${SERVICE}" hermes pairing "${P_ACTION}" "${P_PLATFORM}" "${P_CODE}" 2>&1 \
    | sed 's/^/[pairing] /' || log "WARN: pairing CLI exited non-zero"
  # Restart so the running agent re-reads the approval store on next start.
  log "Pairing processed; restarting '${SERVICE}'."
  docker compose --project-directory "${PROJECT_DIR}" -f "${COMPOSE_FILE}" restart "${SERVICE}"
  log "Done (pairing)."
  exit 0
fi

# Sanity: confirm the config artifact the panel writes is present before bouncing.
CFG="${DATA_DIR}/config.yaml"
if [ ! -f "${CFG}" ]; then
  log "WARN: expected config ${CFG} not found yet; restarting anyway so the agent re-reads .env."
fi

log "PRODUCT=${PRODUCT} SERVICE=${SERVICE} COMPOSE_FILE=${COMPOSE_FILE}"
log "Restarting service '${SERVICE}' so it picks up the new config..."

# --project-directory keeps relative volume paths (./data) resolving correctly.
docker compose --project-directory "${PROJECT_DIR}" -f "${COMPOSE_FILE}" restart "${SERVICE}"

log "Restart issued for '${SERVICE}'. Done."
