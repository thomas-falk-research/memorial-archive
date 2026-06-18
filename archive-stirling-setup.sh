#!/usr/bin/env bash
#
# archive-stirling-setup.sh — a self-hosted PDF toolbox (Stirling-PDF) for the family.
#
# Deploys Stirling-PDF as a PINNED Docker Compose stack: a web app to merge, split, OCR, convert,
# compress, rotate, sign and otherwise work with PDFs — entirely on the box, nothing uploaded to the
# internet. You upload a file in the browser, do the operation, download the result.
#
# It does NOT touch the archive: it has no access to /srv/archive at all (it only sees files you
# upload through its web page), so it can never change a master. It listens on LOOPBACK only; publish
# it (behind the same family password as search) with archive-proxy-setup.sh. Config lives on the OS
# disk, off the archive budget, and it joins the shared 'memorial' network.
#
# Run as a REGULAR user with sudo (NOT via `sudo ./...`). Requires Docker (provision.sh).
#
set -euo pipefail
umask 022
trap 'printf "\n\033[1;31mERROR\033[0m: command failed at line %s\n" "$LINENO" >&2' ERR

# ---- Configuration (override via environment) ------------------------------------------------
APP_DIR="${STIRLING_DIR:-/srv/apps/stirling}"
STIRLING_VERSION="${STIRLING_VERSION:-}"        # empty = auto-resolve the latest release
STIRLING_VARIANT="${STIRLING_VARIANT:-}"        # "", "fat" (adds LibreOffice/extra OCR), or "ultra-lite"
STIRLING_PORT="${STIRLING_PORT:-8082}"          # published on 127.0.0.1 only; Caddy fronts it (8080 inside)
STIRLING_IMAGE="${STIRLING_IMAGE:-stirlingtools/stirling-pdf}"
FALLBACK_VERSION="v2.12.0"                       # used only if the release lookup fails
DOCKER_NET="${ARCHIVE_DOCKER_NET:-memorial}"

ASSUME_YES=false
usage() {
  cat <<USAGE
Usage: ${0##*/} [--yes|-y] [--help|-h]
  --yes, -y   skip the confirmation prompt
  --help, -h  show this help and exit
Env overrides: STIRLING_VERSION (pin a tag), STIRLING_VARIANT (fat|ultra-lite), STIRLING_DIR,
STIRLING_IMAGE, STIRLING_PORT.
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

if [[ -r /etc/archive-ingest.conf ]]; then
  # shellcheck source=/dev/null
  . /etc/archive-ingest.conf || true
fi

sudo -v
sudo docker info >/dev/null 2>&1 || die "Docker isn't available/running. Run provision.sh (and start Docker) first."

# Resolve the version to pin. Git tags are vX.Y.Z; the image tag drops the leading 'v'.
if [[ -z "$STIRLING_VERSION" ]]; then
  info "Resolving the latest Stirling-PDF release..."
  STIRLING_VERSION="$(git ls-remote --tags --refs https://github.com/Stirling-Tools/Stirling-PDF 'v*' 2>/dev/null \
    | awk -F/ '{print $NF}' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
  [[ -n "$STIRLING_VERSION" ]] || { STIRLING_VERSION="$FALLBACK_VERSION"; warn "Release lookup failed; using ${STIRLING_VERSION}."; }
fi
STIRLING_VERSION="v${STIRLING_VERSION#v}"
IMAGE_TAG="${STIRLING_VERSION#v}${STIRLING_VARIANT:+-$STIRLING_VARIANT}"
host_short="$(hostname -s 2>/dev/null || hostname)"
lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

log "This will deploy Stirling-PDF ${STIRLING_VERSION} (${IMAGE_TAG}) with Docker, using sudo:"
printf '    - a self-hosted PDF toolbox (merge/split/OCR/convert/sign) — NO access to the archive\n'
printf '    - app config: %s/configs   (OS disk, off the archive budget)\n' "$APP_DIR"
printf '    - listens on 127.0.0.1:%s ONLY — publish it with archive-proxy-setup.sh (pdf.<domain>)\n' "$STIRLING_PORT"
if [[ "${ASSUME_YES}" != "true" ]]; then
  read -rp $'\nProceed? [y/N] ' _ans
  [[ "${_ans}" =~ ^[Yy] ]] || { echo "Aborted; nothing was changed."; exit 0; }
fi

log "Creating ${APP_DIR} (config)"
sudo mkdir -p "$APP_DIR/configs"
sudo chown -R "$(id -u):$(id -g)" "$APP_DIR/configs"

log "Ensuring the shared '${DOCKER_NET}' network exists"
sudo docker network inspect "$DOCKER_NET" >/dev/null 2>&1 || sudo docker network create "$DOCKER_NET" >/dev/null

log "Writing docker-compose.yml (pinned ${IMAGE_TAG}, loopback-only, no archive access)"
# Only /configs is mounted (to persist settings). We deliberately do NOT mount /usr/share/tessdata —
# mounting an empty host dir there would hide the OCR language data bundled in the image.
sudo tee "$APP_DIR/docker-compose.yml" >/dev/null <<EOF
# Managed by archive-stirling-setup.sh — self-hosted PDF tools, fronted by Caddy. No archive access.
services:
  stirling-pdf:
    image: ${STIRLING_IMAGE}:${IMAGE_TAG}
    container_name: stirling-pdf
    environment:
      SYSTEM_DEFAULTLOCALE: "en-US"
      SYSTEM_ENABLEANALYTICS: "false"     # privacy: no usage analytics phoned home
      SECURITY_ENABLELOGIN: "false"       # no built-in login; Caddy fronts it with the family password
    ports:
      - "127.0.0.1:${STIRLING_PORT}:8080"   # loopback only — Caddy publishes it on the LAN
    volumes:
      - ${APP_DIR}/configs:/configs          # persisted settings (off the archive)
    networks:
      - ${DOCKER_NET}
    restart: unless-stopped
    stop_grace_period: 20s
networks:
  ${DOCKER_NET}:
    external: true
EOF

log "Validating the compose configuration"
( cd "$APP_DIR" && sudo docker compose config >/dev/null ) || die "docker compose config rejected the setup — not starting. Check ${APP_DIR}."
info "Configuration valid."

log "Starting Stirling-PDF (first run pulls the image — a few minutes)"
( cd "$APP_DIR" && sudo docker compose up -d )

log "Done — Stirling-PDF is starting."
cat <<EOF
    It listens on 127.0.0.1:${STIRLING_PORT} only. Make it reachable for the family (behind the same
    password as search) by running the front door:
        ./manage.sh   ->  Install  ->  One-URL front door     (or:  bash archive-proxy-setup.sh)
    then open    http://pdf.home/    (after the AdGuard rewrite the proxy step prints).

    Quick local check on the box itself (give it a minute to start):
        curl -sI http://127.0.0.1:${STIRLING_PORT}/ | head -1     (expect HTTP 200)

    Notes:
      - It has NO access to /srv/archive — you upload files through its web page; the masters are safe.
      - For Office-document conversions (Word/Excel -> PDF), redeploy with the 'fat' image:
          STIRLING_VARIANT=fat bash archive-stirling-setup.sh
      - App data is in ${APP_DIR}/configs on the OS disk (settings only; not part of the verified backup).
      - Manage:  archive-apps status   ·   cd ${APP_DIR} && sudo docker compose [ps|logs -f|restart|down]
      - Reachable on ${host_short}.local / ${lan_ip:-the LAN IP} only via the Caddy front door.
EOF
