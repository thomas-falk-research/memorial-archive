#!/usr/bin/env bash
#
# archive-paperless-setup.sh — document manager (Paperless-ngx) for the family.
#
# Deploys Paperless-ngx as a PINNED Docker Compose stack (Postgres + Redis + the app). It OCRs,
# tags, and full-text-indexes documents you place in its consume folder, with a friendly web UI.
# App data lives on the OS disk (Docker-managed volumes, off the 2 TB archive budget); the consume/
# export folders are under /srv/apps/paperless so you can drop files in. Reachable on the local
# network (and tailnet) at :8000.
#
# Run as a REGULAR user with sudo (NOT via `sudo ./...`). Requires Docker (provision.sh).
#
set -euo pipefail
umask 022
trap 'printf "\n\033[1;31mERROR\033[0m: command failed at line %s\n" "$LINENO" >&2' ERR

# ---- Configuration (override via environment) ------------------------------------------------
APP_DIR="${PAPERLESS_DIR:-/srv/apps/paperless}"
PAPERLESS_VERSION="${PAPERLESS_VERSION:-}"     # empty = auto-resolve the latest release
PAPERLESS_PORT=8000                            # fixed: Paperless's compose publishes 8000 (the proxy + .home names front it)
PAPERLESS_ADMIN_USER="${PAPERLESS_ADMIN_USER:-admin}"
OCR_LANGUAGE="${OCR_LANGUAGE:-eng}"
FALLBACK_VERSION="v2.20.15"                     # used only if the release lookup fails

ASSUME_YES=false
usage() {
  cat <<USAGE
Usage: ${0##*/} [--yes|-y] [--help|-h]
  --yes, -y   skip prompts; generate a random admin password and print it
  --help, -h  show this help and exit
Env overrides: PAPERLESS_VERSION, PAPERLESS_ADMIN_USER (default
'admin'), OCR_LANGUAGE (default 'eng'), PAPERLESS_DIR.
USAGE
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)  ASSUME_YES=true ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '    \033[0;36m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m: %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -ne 0 ]] || die "Run as a regular user (not root / not via sudo). The script sudo's when needed."
command -v sudo >/dev/null 2>&1 || die "sudo is required."
command -v curl >/dev/null 2>&1 || die "curl is required."

sudo -v
sudo docker info >/dev/null 2>&1 || die "Docker isn't available/running. Run provision.sh (and start Docker) first."

if [[ -z "$PAPERLESS_VERSION" ]]; then
  info "Resolving the latest Paperless-ngx release..."
  PAPERLESS_VERSION="$(git ls-remote --tags --refs https://github.com/paperless-ngx/paperless-ngx 'v*' 2>/dev/null \
    | awk -F/ '{print $NF}' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
  [[ -n "$PAPERLESS_VERSION" ]] || { PAPERLESS_VERSION="$FALLBACK_VERSION"; warn "Release lookup failed; using ${PAPERLESS_VERSION}."; }
fi
# Git release tags are vX.Y.Z, but the container image tag drops the leading 'v' (e.g. 2.20.15).
# Keep the git ref (with 'v') for the compose/env downloads; use the image tag (no 'v') for the pin.
PAPERLESS_VERSION="v${PAPERLESS_VERSION#v}"
IMAGE_TAG="${PAPERLESS_VERSION#v}"

host_short="$(hostname -s 2>/dev/null || hostname)"
lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
tz="$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo 'Etc/UTC')"
uid="$(id -u)"; gid="$(id -g)"

# Detect a prior install: a re-run must NOT rotate the admin password, regenerate the secret, or
# wipe your docker-compose.env edits (e.g. PAPERLESS_URL). On re-run we refresh only the compose
# file and the version pin, and leave your env file untouched.
first_install=true
if sudo test -f "$APP_DIR/docker-compose.env" && sudo grep -q 'archive-paperless-setup.sh' "$APP_DIR/docker-compose.env" 2>/dev/null; then
  first_install=false
fi

log "This will deploy Paperless-ngx ${PAPERLESS_VERSION} with Docker, using sudo:"
printf '    - app + database + redis (Docker-managed volumes on the OS disk, off the archive budget)\n'
printf '    - drop documents to OCR/index into:  %s/consume\n' "$APP_DIR"
printf '    - reachable on the local network + tailnet at port %s\n' "$PAPERLESS_PORT"
if [[ "$first_install" == true ]]; then printf '    - admin login: %s  (you set its password below)\n' "$PAPERLESS_ADMIN_USER"
else printf '    - re-run: keeping your settings (admin password, PAPERLESS_URL); refreshing to %s\n' "$PAPERLESS_VERSION"; fi
if [[ "${ASSUME_YES}" != "true" ]]; then
  read -rp $'\nProceed? [y/N] ' _ans
  [[ "${_ans}" =~ ^[Yy] ]] || { echo "Aborted; nothing was changed."; exit 0; }
fi

# Admin password (terminal only — never echoed; never paste it in chat).
GEN_PW=""
if [[ "$first_install" == true ]]; then
  if [[ "${ASSUME_YES}" == "true" ]]; then
    GEN_PW="$(openssl rand -base64 12 2>/dev/null || head -c 9 /dev/urandom | base64)"; admin_pw="$GEN_PW"
  else
    read -rsp "Set a password for the Paperless '${PAPERLESS_ADMIN_USER}' login: " admin_pw; echo
    read -rsp "Confirm: " admin_pw2; echo
    [[ -n "$admin_pw" ]] || die "Password cannot be empty."
    [[ "$admin_pw" == "$admin_pw2" ]] || die "Passwords did not match."
  fi
fi

log "Creating ${APP_DIR} (with consume/ and export/)"
sudo mkdir -p "$APP_DIR/consume" "$APP_DIR/export"
sudo chown "$uid:$gid" "$APP_DIR/consume" "$APP_DIR/export"

log "Fetching Paperless-ngx official compose (pinned ${PAPERLESS_VERSION})"
sudo curl -fsSL "https://raw.githubusercontent.com/paperless-ngx/paperless-ngx/${PAPERLESS_VERSION}/docker/compose/docker-compose.postgres.yml" \
  -o "$APP_DIR/docker-compose.yml" || die "Could not download Paperless's compose for ${PAPERLESS_VERSION}."
if [[ "$first_install" == false ]]; then
  info "Existing install — keeping your docker-compose.env (admin password, PAPERLESS_URL, secret preserved)."
else
  sudo curl -fsSL "https://raw.githubusercontent.com/paperless-ngx/paperless-ngx/${PAPERLESS_VERSION}/docker/compose/docker-compose.env" \
    -o "$APP_DIR/docker-compose.env" || die "Could not download Paperless's env template."
fi

if [[ "$first_install" == true ]]; then
log "Writing settings (.env additions, pinned image, generated secret)"
if [[ -f "$APP_DIR/.paperless-secret" ]] && sudo test -s "$APP_DIR/.paperless-secret"; then
  secret="$(sudo cat "$APP_DIR/.paperless-secret")"
else
  secret="$(openssl rand -hex 32 2>/dev/null || head -c 48 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 50)"
  printf '%s' "$secret" | sudo tee "$APP_DIR/.paperless-secret" >/dev/null && sudo chmod 600 "$APP_DIR/.paperless-secret"
fi
# Append our settings to the env file (later values win over the commented defaults above).
sudo tee -a "$APP_DIR/docker-compose.env" >/dev/null <<EOF

# ---- Added by archive-paperless-setup.sh ----
USERMAP_UID=${uid}
USERMAP_GID=${gid}
PAPERLESS_TIME_ZONE=${tz}
PAPERLESS_OCR_LANGUAGE=${OCR_LANGUAGE}
PAPERLESS_URL=http://${host_short}.local:${PAPERLESS_PORT}
PAPERLESS_SECRET_KEY=${secret}
PAPERLESS_ADMIN_USER=${PAPERLESS_ADMIN_USER}
PAPERLESS_ADMIN_PASSWORD=${admin_pw}
EOF
sudo chmod 600 "$APP_DIR/docker-compose.env"
unset admin_pw admin_pw2 2>/dev/null || true
fi
# Pin the app image (upstream ships :latest) and map the chosen port.
sudo tee "$APP_DIR/docker-compose.override.yml" >/dev/null <<EOF
# Managed by archive-paperless-setup.sh — pin the image and the published port.
services:
  webserver:
    image: ghcr.io/paperless-ngx/paperless-ngx:${IMAGE_TAG}
    ports:
      - "${PAPERLESS_PORT}:8000"
EOF

log "Validating the merged compose configuration"
( cd "$APP_DIR" && sudo docker compose config >/dev/null ) || die "docker compose config rejected the setup — not starting. Check ${APP_DIR}."
info "Configuration valid."

if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  sudo ufw allow "${PAPERLESS_PORT}/tcp" >/dev/null 2>&1 || true
  info "opened port ${PAPERLESS_PORT} in ufw for the local network."
fi

log "Starting Paperless-ngx (first run pulls images + initialises the database — a few minutes)"
( cd "$APP_DIR" && sudo docker compose up -d )

log "Done — Paperless-ngx is starting."
if [[ -n "$GEN_PW" ]]; then signin="${GEN_PW}   (save this now)"
elif [[ "$first_install" == true ]]; then signin="the password you just set"
else signin="your existing admin password (unchanged)"; fi
cat <<EOF
    Open it (give it a couple of minutes on first start while it migrates the DB):
        http://${host_short}.local:${PAPERLESS_PORT}/     (or  http://${lan_ip:-<LAN-IP>}:${PAPERLESS_PORT}/ )
      Sign in:  ${PAPERLESS_ADMIN_USER} / ${signin}

    To file documents: copy PDFs/scans/images into
        ${APP_DIR}/consume
      Paperless watches that folder, OCRs + tags each file, and adds it to the searchable library.
      (recoll still searches the whole archive as-is; Paperless is the curated, OCR'd documents view.)

    Notes:
      - App data + the database are Docker-managed volumes on the OS disk (off the archive budget).
        'archive-backup' backs them up automatically — Paperless's own exporter (documents + tags)
        into /srv/backup/apps/paperless, with a RESTORE.txt alongside.
      - If you reach it by IP/Tailscale and hit a login/CSRF error, set PAPERLESS_URL in
        ${APP_DIR}/docker-compose.env to that address and 'sudo docker compose up -d'.
      - Manage:  cd ${APP_DIR} && sudo docker compose [ps|logs -f|restart|down]
      - Add more family logins in the web UI under the admin (gear) -> Users & Groups.
EOF
[[ -n "$GEN_PW" ]] && warn "The generated password above is shown only once. Save it now."
