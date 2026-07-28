#!/usr/bin/env bash
#
# archive-openarchiver-setup.sh — mail-native archive & search (Open Archiver) for the family.
#
# Deploys Open Archiver as a PINNED Docker Compose stack (app + PostgreSQL + Valkey + Meilisearch +
# Apache Tika). It answers the one question none of the other tools can: "everything to or from this
# correspondent, in this date range, that has an attachment" — and it searches the TEXT INSIDE those
# attachments. It also imports PST/Mbox/EML natively, offline.
#
# HARDENED against the upstream compose, deliberately, in six places (see docs/OPENARCHIVER-ASSESSMENT.md):
#   1. MEILI_NO_ANALYTICS=true — Meilisearch collects analytics from every instance that does not opt
#      out, and upstream's compose does not set it. Nothing on this box phones home.
#   2. Loopback-only publishing (127.0.0.1) — upstream publishes on every interface. Caddy fronts it.
#   3. Container names namespaced 'openarchiver-*' — upstream claims the GLOBAL names 'postgres',
#      'valkey', 'meilisearch' and 'tika' on the Docker daemon, which would collide with other stacks.
#   4. Generated secrets — upstream defaults include POSTGRES_PASSWORD 'password' and MEILI_MASTER_KEY
#      'aSampleMasterKey'.
#   5. The archive is NEVER mounted. Mail is imported from COPIES placed in ./import, which is mounted
#      READ-ONLY so the app cannot alter or delete even the copy.
#   6. ENABLE_DELETION=false — the app's own deletion feature stays off.
#
# The Google Workspace / Microsoft 365 / IMAP connectors are the only parts that reach the internet.
# They are never configured. Do not configure them.
#
# Run as a REGULAR user with sudo (NOT via `sudo ./...`). Requires Docker (provision.sh).
#
set -euo pipefail
umask 022
trap 'printf "\n\033[1;31mERROR\033[0m: command failed at line %s\n" "$LINENO" >&2' ERR

# ---- Configuration (override via environment) ------------------------------------------------
APP_DIR="${OPENARCHIVER_DIR:-/srv/apps/openarchiver}"
OPENARCHIVER_VERSION="${OPENARCHIVER_VERSION:-}"   # empty = keep what's installed (pinned default on a fresh box)
OPENARCHIVER_PORT="${OPENARCHIVER_PORT:-3010}"     # 127.0.0.1 only. 3000 is taken by Docmost.
OPENARCHIVER_IMAGE="${OPENARCHIVER_IMAGE:-logiclabshq/open-archiver}"
OA_PG_IMAGE="${OA_PG_IMAGE:-postgres:17-alpine}"   # pinned MAJOR — never change it on an existing DB
OA_VALKEY_IMAGE="${OA_VALKEY_IMAGE:-valkey/valkey:8-alpine}"
OA_MEILI_IMAGE="${OA_MEILI_IMAGE:-getmeili/meilisearch:v1.38}"
OA_TIKA_IMAGE="${OA_TIKA_IMAGE:-apache/tika:3.2.2.0-full}"   # -full bundles OCR; the minimal image cannot read scans
FALLBACK_VERSION="v0.5.2"                          # recorded pin; audited by ci/version-audit.sh
DOCKER_NET="${ARCHIVE_DOCKER_NET:-memorial}"
BASE_DOMAIN="${BASE_DOMAIN:-home}"

ASSUME_YES=false
ALLOW_UPGRADE=false
usage() {
  cat <<USAGE
Usage: ${0##*/} [--yes|-y] [--upgrade] [--help|-h]
  --yes, -y   skip the confirmation prompt
  --upgrade   advance an existing install to the latest upstream release
              (without it, a re-run keeps the tag already deployed)
  --help, -h  show this help and exit
Env overrides: OPENARCHIVER_VERSION (exact tag), OPENARCHIVER_DIR, OPENARCHIVER_PORT, BASE_DOMAIN.
USAGE
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)  ASSUME_YES=true ;;
    --upgrade) ALLOW_UPGRADE=true ;;
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
OPENARCHIVER_URL="${OPENARCHIVER_URL:-http://mail.${BASE_DOMAIN}}"

sudo -v
sudo docker info >/dev/null 2>&1 || die "Docker isn't available/running. Run provision.sh (and start Docker) first."

# ---- Version resolution (never floats; same discipline as the Paperless guard) -----------------
installed_tag=""
if sudo test -f "$APP_DIR/docker-compose.yml"; then
  installed_tag="$(sudo sed -n 's#.*open-archiver:##p' "$APP_DIR/docker-compose.yml" 2>/dev/null | head -1 | tr -d '[:space:]')"
fi
version_source=""
if [[ -n "$OPENARCHIVER_VERSION" ]]; then
  version_source="requested explicitly"
elif [[ "$ALLOW_UPGRADE" == true ]]; then
  info "Resolving the latest Open Archiver release..."
  OPENARCHIVER_VERSION="$(git ls-remote --tags --refs https://github.com/LogicLabs-OU/OpenArchiver 'v*' 2>/dev/null \
    | awk -F/ '{print $NF}' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
  version_source="latest upstream"
  [[ -n "$OPENARCHIVER_VERSION" ]] || { OPENARCHIVER_VERSION="$FALLBACK_VERSION"; version_source="pinned fallback"; warn "Release lookup failed; using ${OPENARCHIVER_VERSION}."; }
elif [[ -n "$installed_tag" ]]; then
  OPENARCHIVER_VERSION="$installed_tag"; version_source="already installed (no drift; use --upgrade to advance)"
else
  OPENARCHIVER_VERSION="$FALLBACK_VERSION"; version_source="pinned default for a fresh install"
fi
# This project's IMAGE tags keep the leading 'v' (unlike Paperless/Docmost), e.g. v0.5.2.
OPENARCHIVER_VERSION="v${OPENARCHIVER_VERSION#v}"
IMAGE_TAG="$OPENARCHIVER_VERSION"

host_short="$(hostname -s 2>/dev/null || hostname)"
lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

log "This will deploy Open Archiver ${OPENARCHIVER_VERSION} with Docker, using sudo:"
printf '    - version: %s  (%s)\n' "$OPENARCHIVER_VERSION" "$version_source"
printf '    - 5 services: app + PostgreSQL + Valkey + Meilisearch + Tika (a JVM) — budget ~4 GB RAM\n'
printf '    - app data in Docker volumes on the OS disk (off the archive budget); the archive is NEVER mounted\n'
printf '    - import mail by copying files into: %s/import   (mounted READ-ONLY into the app)\n' "$APP_DIR"
printf '    - listens on 127.0.0.1:%s ONLY — publish it with archive-proxy-setup.sh (mail.<domain>)\n' "$OPENARCHIVER_PORT"
printf '    - hardened: Meilisearch telemetry OFF, secrets generated, deletion disabled, no cloud connectors\n'
if [[ "${ASSUME_YES}" != "true" ]]; then
  read -rp $'\nProceed? [y/N] ' _ans
  [[ "${_ans}" =~ ^[Yy] ]] || { echo "Aborted; nothing was changed."; exit 0; }
fi

log "Creating ${APP_DIR} (with import/)"
sudo mkdir -p "$APP_DIR/import"
sudo chown "$(id -u):$(id -g)" "$APP_DIR/import"

log "Writing .env (secrets generated once; reused on every re-run)"
# Reuse existing secrets so a re-run never invalidates sessions, locks the app out of its own
# database, or — worst of all — makes already-encrypted stored mail unreadable.
db_pw=""; jwt=""; enc=""; meili=""; redis_pw=""; storage_key=""
if sudo test -f "$APP_DIR/.env"; then
  db_pw="$(sudo sed -n 's/^POSTGRES_PASSWORD=//p'       "$APP_DIR/.env" 2>/dev/null | head -1)"
  jwt="$(sudo sed -n 's/^JWT_SECRET=//p'                "$APP_DIR/.env" 2>/dev/null | head -1)"
  enc="$(sudo sed -n 's/^ENCRYPTION_KEY=//p'            "$APP_DIR/.env" 2>/dev/null | head -1)"
  meili="$(sudo sed -n 's/^MEILI_MASTER_KEY=//p'        "$APP_DIR/.env" 2>/dev/null | head -1)"
  redis_pw="$(sudo sed -n 's/^REDIS_PASSWORD=//p'       "$APP_DIR/.env" 2>/dev/null | head -1)"
  storage_key="$(sudo sed -n 's/^STORAGE_ENCRYPTION_KEY=//p' "$APP_DIR/.env" 2>/dev/null | head -1)"
fi
gen_hex() { openssl rand -hex "$1" 2>/dev/null || head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
[[ -n "$db_pw"       ]] || db_pw="$(gen_hex 16)"
[[ -n "$jwt"         ]] || jwt="$(gen_hex 32)"
[[ -n "$enc"         ]] || enc="$(gen_hex 32)"        # 32 BYTES = 64 hex chars, per upstream
[[ -n "$meili"       ]] || meili="$(gen_hex 24)"
[[ -n "$redis_pw"    ]] || redis_pw="$(gen_hex 16)"
[[ -n "$storage_key" ]] || storage_key="$(gen_hex 32)"

sudo tee "$APP_DIR/.env" >/dev/null <<ENVEOF
# Managed by archive-openarchiver-setup.sh — SECRETS. Keep private (chmod 600).
# Losing ENCRYPTION_KEY / STORAGE_ENCRYPTION_KEY makes stored mail unreadable: back this file up.
NODE_ENV=production
PORT_FRONTEND=3000
PORT_BACKEND=4000
APP_URL=${OPENARCHIVER_URL}
ORIGIN=${OPENARCHIVER_URL}
STORAGE_LOCAL_ROOT_PATH=/var/lib/open-archiver

JWT_SECRET=${jwt}
ENCRYPTION_KEY=${enc}
STORAGE_ENCRYPTION_KEY=${storage_key}

POSTGRES_DB=open_archive
POSTGRES_USER=openarchiver
POSTGRES_PASSWORD=${db_pw}
DATABASE_URL=postgresql://openarchiver:${db_pw}@openarchiver-postgres:5432/open_archive

MEILI_MASTER_KEY=${meili}
MEILI_HOST=http://openarchiver-meilisearch:7700
MEILI_NO_ANALYTICS=true

REDIS_HOST=openarchiver-valkey
REDIS_PORT=6379
REDIS_PASSWORD=${redis_pw}

TIKA_URL=http://openarchiver-tika:9998

# Deliberate policy for this archive:
ENABLE_DELETION=false
INGESTION_WORKER_CONCURRENCY=2
ALL_INCLUSIVE_ARCHIVE=true
ENVEOF
sudo chmod 600 "$APP_DIR/.env"

log "Ensuring the shared '${DOCKER_NET}' network exists"
sudo docker network inspect "$DOCKER_NET" >/dev/null 2>&1 || sudo docker network create "$DOCKER_NET" >/dev/null

log "Writing docker-compose.yml (pinned: ${IMAGE_TAG}, ${OA_PG_IMAGE}, ${OA_VALKEY_IMAGE}, ${OA_MEILI_IMAGE}, ${OA_TIKA_IMAGE})"
sudo tee "$APP_DIR/docker-compose.yml" >/dev/null <<EOF
# Managed by archive-openarchiver-setup.sh — mail archive, fronted by Caddy.
# HARDENED vs upstream: loopback-only ports, namespaced container names, Meilisearch telemetry OFF,
# generated secrets, and the archive is never mounted (mail arrives as COPIES in ./import, READ-ONLY).
services:
  open-archiver:
    image: ${OPENARCHIVER_IMAGE}:${IMAGE_TAG}
    container_name: openarchiver-app
    depends_on:
      - postgres
      - valkey
      - meilisearch
      - tika
    env_file:
      - .env
    ports:
      - "127.0.0.1:${OPENARCHIVER_PORT}:3000"
    volumes:
      - openarchiver_data:/var/lib/open-archiver
      - ${APP_DIR}/import:/import:ro
    networks:
      - default
      - ${DOCKER_NET}
    restart: unless-stopped
  postgres:
    image: ${OA_PG_IMAGE}
    container_name: openarchiver-postgres
    environment:
      POSTGRES_DB: open_archive
      POSTGRES_USER: openarchiver
      POSTGRES_PASSWORD: "\${POSTGRES_PASSWORD}"
    volumes:
      - openarchiver_pgdata:/var/lib/postgresql/data
    restart: unless-stopped
  valkey:
    image: ${OA_VALKEY_IMAGE}
    container_name: openarchiver-valkey
    command: valkey-server --requirepass "\${REDIS_PASSWORD}"
    volumes:
      - openarchiver_valkeydata:/data
    restart: unless-stopped
  meilisearch:
    image: ${OA_MEILI_IMAGE}
    container_name: openarchiver-meilisearch
    environment:
      MEILI_MASTER_KEY: "\${MEILI_MASTER_KEY}"
      MEILI_NO_ANALYTICS: "true"
      MEILI_SCHEDULE_SNAPSHOT: "86400"
    volumes:
      - openarchiver_meilidata:/meili_data
    restart: unless-stopped
  tika:
    image: ${OA_TIKA_IMAGE}
    container_name: openarchiver-tika
    restart: unless-stopped
volumes:
  openarchiver_data:
  openarchiver_pgdata:
  openarchiver_valkeydata:
  openarchiver_meilidata:
networks:
  ${DOCKER_NET}:
    external: true
EOF

log "Validating the compose configuration"
( cd "$APP_DIR" && sudo docker compose config >/dev/null ) || die "docker compose config rejected the setup — not starting. Check ${APP_DIR}."
info "Configuration valid."

# Prove the hardening actually landed, rather than trusting that it did.
log "Verifying the hardening"
cfg="$( cd "$APP_DIR" && sudo docker compose config 2>/dev/null )"
hard_ok=true
grep -q 'MEILI_NO_ANALYTICS' <<<"$cfg" || { warn "MEILI_NO_ANALYTICS missing from the rendered config"; hard_ok=false; }
if grep -E '^\s+-\s+"?[0-9]+:[0-9]+' <<<"$cfg" | grep -qv '127\.0\.0\.1'; then
  warn "a port is published on all interfaces"; hard_ok=false
fi
grep -q '/import:ro' <<<"$cfg" || grep -q 'read_only: true' <<<"$cfg" || warn "the import mount is not read-only — check the compose"
[[ "$hard_ok" == true ]] && info "hardening verified in the rendered config."

log "Starting Open Archiver (first run pulls ~5 images and initialises the database — several minutes)"
( cd "$APP_DIR" && sudo docker compose up -d )

log "Done — Open Archiver is starting."
cat <<EOF
    BEFORE you put any family mail in it, run the verification (no real data involved):
        bash openarchiver/verify-openarchiver.sh all

    It proves, on synthetic data: the hardening is live, the stack works with egress BLOCKED,
    Tika really OCRs an image-only attachment (otherwise attachment-content search is blind to
    every scanned fax we are hunting), and an imported file is left byte-identical.

    Then reach it via the front door:
      1. ./manage.sh -> Install -> One-URL front door   (adds the mail.${BASE_DOMAIN} route)
      2. Open ${OPENARCHIVER_URL} and CREATE THE ADMIN ACCOUNT FIRST — do it promptly, before
         sharing the address, so nobody else can claim it.

    Local check on the box (give it a few minutes to migrate the DB):
        curl -sI http://127.0.0.1:${OPENARCHIVER_PORT}/ | head -1     (expect HTTP 200 or a redirect)

    To import mail: copy (never move) the file into ${APP_DIR}/import, then add an ingestion
    source of type PST/Mbox/EML in the web UI pointing at  /import/<filename>.
      - That directory is mounted READ-ONLY, so the app cannot alter or delete your copy.
      - The archive itself is NOT mounted into any container, by design.

    Notes:
      - Secrets are in ${APP_DIR}/.env (chmod 600). ENCRYPTION_KEY and STORAGE_ENCRYPTION_KEY are
        NOT recoverable — without them the stored mail is unreadable. Save that file.
      - NEVER configure the Google Workspace / Microsoft 365 / IMAP connectors. They are the only
        parts that reach the internet.
      - The index is rebuildable from the source mail, so this stack is derived data, not a master.
      - Manage:  archive-apps status   ·   cd ${APP_DIR} && sudo docker compose [ps|logs -f|restart|down]
      - Remove entirely:  cd ${APP_DIR} && sudo docker compose down -v
      - Reachable on ${host_short}.local / ${lan_ip:-the LAN IP} only via the Caddy front door.
EOF
exit 0
