#!/usr/bin/env bash
# firstboot.sh — one-shot first-real-boot provisioning for the Hermes per-client VM.
#
# Runs ONCE via the hermes-firstboot.service systemd oneshot (installed by the
# autoinstall snippet). Idempotent: safe to re-run; it disables itself at the end so
# it never runs again. Brings up the full stack:
#   gateway (Hermes agent) + panel (CloudHosting setup UI) + caddy (TLS for the panel).
#
# Steps:
#   1. Ensure ./data exists, owned by the agent's uid:gid, with correct perms.
#   2. Seed config.yaml into ./data if not already present (agent reads ./data/config.yaml).
#   3. If PANEL_DOMAIN is blank, derive vps-<o3>-<o4>.cloudhosting.lv from the primary IPv4.
#   4. docker compose pull && up -d.
#   5. Install + enable the host-side applier (systemd path+service) for this product.
#   6. Disable this oneshot so it doesn't run again.
#
# All product paths are absolute (/opt/hermes-vm) so this works regardless of cwd.

set -euo pipefail

APP_DIR="/opt/hermes-vm"
DATA_DIR="${APP_DIR}/data"
ENV_FILE="${APP_DIR}/.env"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
APPLIER_SRC="${APP_DIR}/applier"
APPLIER_LIB="/usr/local/lib/cloudhosting"
PANEL_ENV="/etc/cloudhosting-panel.env"

log() { printf '[firstboot %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { printf '[firstboot ERROR] %s\n' "$*" >&2; exit 1; }

cd "${APP_DIR}" || die "missing ${APP_DIR}"

# --- Load .env so we can read HERMES_UID/GID + PANEL_DOMAIN (best-effort) ----------
# shellcheck disable=SC1090
[ -f "${ENV_FILE}" ] && set -a && . "${ENV_FILE}" && set +a || true

HERMES_UID="${HERMES_UID:-10000}"
HERMES_GID="${HERMES_GID:-10000}"

# --- 1. Shared data dir: owner = agent uid:gid (the panel runs as this uid too) ----
# Both the Hermes agent and the panel run as HERMES_UID:HERMES_GID, so a single owner
# is enough and the panel's 0600 .env stays readable by the agent.
log "Ensuring ${DATA_DIR} (owner ${HERMES_UID}:${HERMES_GID})"
mkdir -p "${DATA_DIR}"
chown -R "${HERMES_UID}:${HERMES_GID}" "${DATA_DIR}"
chmod 0750 "${DATA_DIR}"

# --- 2. Seed config.yaml the agent reads (don't clobber an existing one) ------------
if [ -f "${APP_DIR}/config.yaml" ] && [ ! -f "${DATA_DIR}/config.yaml" ]; then
  log "Seeding config.yaml into data dir"
  cp "${APP_DIR}/config.yaml" "${DATA_DIR}/config.yaml"
  chown "${HERMES_UID}:${HERMES_GID}" "${DATA_DIR}/config.yaml"
fi
# If .env exists (autoinstall wrote it), make sure it's a private, agent-owned secret.
if [ -f "${DATA_DIR}/.env" ]; then
  chown "${HERMES_UID}:${HERMES_GID}" "${DATA_DIR}/.env"
  chmod 0600 "${DATA_DIR}/.env"
fi

# --- 3. Derive PANEL_DOMAIN from the primary IPv4 if it was left blank --------------
if [ -z "${PANEL_DOMAIN:-}" ]; then
  # Primary IPv4 = the source address used to reach the default route. No DNS needed.
  IP="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -n1)"
  [ -n "${IP}" ] || IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -n "${IP}" ] || die "could not determine primary IPv4 to derive PANEL_DOMAIN"
  O3="$(printf '%s' "${IP}" | cut -d. -f3)"
  O4="$(printf '%s' "${IP}" | cut -d. -f4)"
  PANEL_DOMAIN="vps-${O3}-${O4}.cloudhosting.lv"
  log "Derived PANEL_DOMAIN=${PANEL_DOMAIN} from IP ${IP}"
  # Persist it into .env so compose + Caddy + the panel all see the same value.
  if grep -q '^PANEL_DOMAIN=' "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^PANEL_DOMAIN=.*|PANEL_DOMAIN=${PANEL_DOMAIN}|" "${ENV_FILE}"
  else
    printf 'PANEL_DOMAIN=%s\n' "${PANEL_DOMAIN}" >> "${ENV_FILE}"
  fi
  export PANEL_DOMAIN
else
  log "PANEL_DOMAIN already set: ${PANEL_DOMAIN}"
fi

# --- 4. Pull + start the stack ------------------------------------------------------
log "docker compose pull"
docker compose -f "${COMPOSE_FILE}" pull
log "docker compose up -d"
docker compose -f "${COMPOSE_FILE}" up -d

# --- 5. Install the host-side applier (docker control stays off the web surface) ----
log "Installing applier units"
install -d -m 0755 "${APPLIER_LIB}"
install -m 0755 "${APPLIER_SRC}/apply.sh" "${APPLIER_LIB}/apply.sh"
cp "${APPLIER_SRC}/cloudhosting-applier.path"    /etc/systemd/system/
cp "${APPLIER_SRC}/cloudhosting-applier.service" /etc/systemd/system/

# Per-VM applier config: which product + compose file + data dir to act on. apply.sh
# maps hermes -> restart the `gateway` service. The .path unit watches .apply-request.
cat > "${PANEL_ENV}" <<EOF
PRODUCT=hermes
COMPOSE_FILE=${COMPOSE_FILE}
COMPOSE_PROJECT_DIR=${APP_DIR}
DATA_DIR=${DATA_DIR}
EOF
chmod 0644 "${PANEL_ENV}"

systemctl daemon-reload
systemctl enable --now cloudhosting-applier.path
log "Applier enabled (watching ${DATA_DIR}/.apply-request)"

# --- 6. Disable this oneshot so it never runs again ---------------------------------
log "Disabling hermes-firstboot.service (provisioning complete)"
systemctl disable hermes-firstboot.service 2>/dev/null || true

log "First boot complete. Panel: https://${PANEL_DOMAIN}"
