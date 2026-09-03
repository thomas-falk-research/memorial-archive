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
#      The one sanctioned alternative is this host's Tailscale address (--tailscale), which reaches
#      your own devices over WireGuard and stays invisible to the LAN. 0.0.0.0 is refused outright.
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
OPENARCHIVER_PORT="${OPENARCHIVER_PORT:-3010}"     # 3000 is taken by Docmost.
# Which interface the port is published on. Loopback by default: the app is then reachable only
# through Caddy or an SSH tunnel. The ONLY other accepted value is this host's Tailscale address
# (100.64.0.0/10), which exposes it to the tailnet and nothing else — WireGuard-encrypted, subject
# to your Tailscale ACLs, and invisible from the LAN. 0.0.0.0 and LAN addresses are refused: an
# archive of a deceased attorney's correspondence should not be one firewall rule away from the
# whole subnet. Use --tailscale to set this and ORIGIN together.
OPENARCHIVER_BIND="${OPENARCHIVER_BIND:-}"
OPENARCHIVER_IMAGE="${OPENARCHIVER_IMAGE:-logiclabshq/open-archiver}"
OA_PG_IMAGE="${OA_PG_IMAGE:-postgres:17-alpine}"   # pinned MAJOR — never change it on an existing DB
OA_VALKEY_IMAGE="${OA_VALKEY_IMAGE:-valkey/valkey:8-alpine}"
OA_MEILI_IMAGE="${OA_MEILI_IMAGE:-getmeili/meilisearch:v1.38}"
OA_TIKA_IMAGE="${OA_TIKA_IMAGE:-apache/tika:3.2.2.0-full}"   # -full bundles OCR; the minimal image cannot read scans
# 5 minutes. Deliberately generous: a timeout that is too long costs one stalled worker, a timeout
# that is too short costs the document. See the note beside PDF_PARSE_TIMEOUT_MS in the .env below.
OA_PDF_TIMEOUT_MS="${OA_PDF_TIMEOUT_MS:-300000}"
FALLBACK_VERSION="v0.5.2"                          # recorded pin; audited by ci/version-audit.sh
DOCKER_NET="${ARCHIVE_DOCKER_NET:-memorial}"
BASE_DOMAIN="${BASE_DOMAIN:-home}"

ASSUME_YES=false
ALLOW_UPGRADE=false
WANT_TAILSCALE=false
WANT_LOOPBACK=false
usage() {
  cat <<USAGE
Usage: ${0##*/} [--yes|-y] [--upgrade] [--help|-h]
  --yes, -y   skip the confirmation prompt
  --upgrade   advance an existing install to the latest upstream release
              (without it, a re-run keeps the tag already deployed)
  --tailscale publish on this host's Tailscale address instead of loopback, and set
              ORIGIN/APP_URL to match. Both must move together or logins break.
  --loopback  publish on 127.0.0.1 only (the default), and set ORIGIN to the SSH-tunnel URL
  --help, -h  show this help and exit
Env overrides: OPENARCHIVER_VERSION (exact tag), OPENARCHIVER_DIR, OPENARCHIVER_PORT,
               OPENARCHIVER_BIND (127.0.0.1 or a 100.64.0.0/10 Tailscale address),
               OPENARCHIVER_URL, BASE_DOMAIN.
USAGE
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)  ASSUME_YES=true ;;
    --upgrade) ALLOW_UPGRADE=true ;;
    --tailscale) WANT_TAILSCALE=true ;;
    --loopback)  WANT_LOOPBACK=true ;;
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
# The access URL is REUSED on a re-run, exactly like the secrets below it, and for the same reason.
#
# ORIGIN/APP_URL decide which origin SvelteKit will accept form posts from. Defaulting them to
# mail.<domain> on every run meant that re-running this script to change something unrelated — a
# timeout, an image tag — would silently repoint ORIGIN and lock the operator out of the URL they
# were actually using (e.g. an SSH tunnel on 127.0.0.1:8931). The login page would load and the
# login would simply fail. Changing how the app is reached must be a DELIBERATE act, so it now takes
# an explicit OPENARCHIVER_URL; otherwise whatever the install already answers on is preserved.
OPENARCHIVER_URL_REQUESTED="${OPENARCHIVER_URL:-}"

sudo -v
sudo docker info >/dev/null 2>&1 || die "Docker isn't available/running. Run provision.sh (and start Docker) first."

# ---- Version resolution (never floats; same discipline as the Paperless guard) -----------------
installed_tag=""
if sudo test -f "$APP_DIR/docker-compose.yml"; then
  # The obvious expression is wrong here. `sed -n 's#.*open-archiver:##p'` also matches the SERVICE
  # NAME line — `  open-archiver:` — which appears FIRST in the file and yields an empty string, so
  # head -1 returns nothing and the script concludes there is no install at all. It then falls
  # through to FALLBACK_VERSION and reports "pinned default for a fresh install" on a box that has
  # been running for days.
  #
  # Benign only by coincidence: today FALLBACK_VERSION equals the deployed tag. The day this pin is
  # bumped while a box still runs the older release, a plain re-run would silently UPGRADE it —
  # exactly what pinning exists to prevent, and it would announce a fresh install while doing it.
  #
  # Requiring at least one non-space character after the colon excludes the service-name line.
  installed_tag="$(sudo grep -oE 'open-archiver:[^[:space:]"]+' "$APP_DIR/docker-compose.yml" 2>/dev/null \
    | head -1 | sed 's|.*:||' | tr -d '[:space:]')"
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

# ---- Publish-interface resolution ---------------------------------------------------------------
# is_loopback / is_tailnet — the ONLY two accepted binds. Everything else is refused, by name, with
# the reason: this stack holds privileged legal correspondence, and "reachable from the LAN" is a
# materially different exposure from "reachable from my own devices over WireGuard".
is_loopback(){ [[ "$1" == "127.0.0.1" ]]; }
is_tailnet(){
  # Tailscale hands out CGNAT space, 100.64.0.0/10 — i.e. 100.64.x.x through 100.127.x.x. Matching
  # a bare "100." would also accept 100.200.x.x, which is ordinary public address space.
  [[ "$1" =~ ^100\.([0-9]{1,3})\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  local o2="${BASH_REMATCH[1]}"
  (( o2 >= 64 && o2 <= 127 ))
}

tailscale_ip(){
  command -v tailscale >/dev/null 2>&1 || return 1
  tailscale ip -4 2>/dev/null | head -1 | tr -d '[:space:]'
}

installed_bind=""
if sudo test -f "$APP_DIR/docker-compose.yml"; then
  installed_bind="$(sudo grep -oE '"[0-9.]+:[0-9]+:3000"' "$APP_DIR/docker-compose.yml" 2>/dev/null \
    | head -1 | tr -d '"' | cut -d: -f1)"
fi

bind_source=""
if [[ "$WANT_TAILSCALE" == true && "$WANT_LOOPBACK" == true ]]; then
  die "--tailscale and --loopback are mutually exclusive."
elif [[ "$WANT_TAILSCALE" == true ]]; then
  OPENARCHIVER_BIND="$(tailscale_ip)" || true
  [[ -n "$OPENARCHIVER_BIND" ]] || die "--tailscale: could not read this host's Tailscale address.
    Is tailscaled running and logged in?   tailscale status ; tailscale ip -4"
  bind_source="--tailscale"
elif [[ "$WANT_LOOPBACK" == true ]]; then
  OPENARCHIVER_BIND="127.0.0.1"; bind_source="--loopback"
elif [[ -n "$OPENARCHIVER_BIND" ]]; then
  bind_source="requested explicitly"
elif [[ -n "$installed_bind" ]]; then
  OPENARCHIVER_BIND="$installed_bind"; bind_source="reused from the existing install"
else
  OPENARCHIVER_BIND="127.0.0.1"; bind_source="default"
fi

if is_loopback "$OPENARCHIVER_BIND"; then
  bind_kind="loopback"
elif is_tailnet "$OPENARCHIVER_BIND"; then
  bind_kind="tailnet"
else
  die "refusing to publish on '${OPENARCHIVER_BIND}'.
    Accepted: 127.0.0.1 (loopback), or this host's Tailscale address in 100.64.0.0/10.
    0.0.0.0 would expose an archive of privileged legal correspondence to every interface,
    and a LAN address to the whole subnet. Neither is a decision this script will make for you.
    For tailnet access:   bash ${0##*/} --tailscale"
fi

# ---- Access URL resolution (explicit request, else what is already deployed, else default) ------
installed_url=""
if sudo test -f "$APP_DIR/.env"; then
  installed_url="$(sudo sed -n 's/^APP_URL=//p' "$APP_DIR/.env" 2>/dev/null | head -1)"
fi
if [[ -n "$OPENARCHIVER_URL_REQUESTED" ]]; then
  OPENARCHIVER_URL="$OPENARCHIVER_URL_REQUESTED"; url_source="requested explicitly"
elif [[ "$bind_source" == "--tailscale" ]]; then
  # The bind and the origin are one decision, not two. Moving the port to the tailnet without moving
  # ORIGIN produces an app that loads and then rejects every form post — the exact failure that looks
  # like a broken login and isn't. --tailscale therefore sets both.
  OPENARCHIVER_URL="http://${OPENARCHIVER_BIND}:${OPENARCHIVER_PORT}"; url_source="derived from --tailscale"
elif [[ -n "$installed_url" ]]; then
  OPENARCHIVER_URL="$installed_url";             url_source="reused from the existing install"
else
  OPENARCHIVER_URL="http://mail.${BASE_DOMAIN}"; url_source="default for a fresh install"
fi

# The bind and ORIGIN must agree, or the app loads and rejects every form post. This is the check
# that makes the pair impossible to ship half-changed — including via a plain re-run that reuses one
# and not the other.
if [[ "$bind_kind" == "tailnet" ]]; then
  want_origin="http://${OPENARCHIVER_BIND}:${OPENARCHIVER_PORT}"
  if [[ "$OPENARCHIVER_URL" != "$want_origin" ]]; then
    die "the publish address and ORIGIN disagree.
    publishing on : ${OPENARCHIVER_BIND}:${OPENARCHIVER_PORT}
    ORIGIN would be: ${OPENARCHIVER_URL}
    SvelteKit accepts form posts only from ORIGIN, so the UI would load and then reject every
    submission — including 'add ingestion source'. Set them together:
        bash ${0##*/} --tailscale
    or name the URL yourself:
        OPENARCHIVER_URL='${want_origin}' bash ${0##*/}"
  fi
fi

host_short="$(hostname -s 2>/dev/null || hostname)"
lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

log "This will deploy Open Archiver ${OPENARCHIVER_VERSION} with Docker, using sudo:"
printf '    - version: %s  (%s)\n' "$OPENARCHIVER_VERSION" "$version_source"
printf '    - publishes on: %s:%s  (%s, %s)\n' "$OPENARCHIVER_BIND" "$OPENARCHIVER_PORT" "$bind_kind" "$bind_source"
printf '    - ORIGIN/APP_URL: %s  (%s)\n' "$OPENARCHIVER_URL" "$url_source"
if [[ -n "$installed_url" && "$OPENARCHIVER_URL" != "$installed_url" ]]; then
  warn "This CHANGES how the app is reached: ${installed_url} -> ${OPENARCHIVER_URL}"
  warn "  Logins at the old URL will stop working the moment this finishes."
fi
if [[ -n "$installed_bind" && "$OPENARCHIVER_BIND" != "$installed_bind" ]]; then
  warn "This CHANGES the published interface: ${installed_bind} -> ${OPENARCHIVER_BIND}"
  [[ "$bind_kind" == "tailnet" ]] && \
    warn "  The app becomes reachable from every device on your tailnet. It stays invisible to the LAN."
fi
printf '    - 5 services: app + PostgreSQL + Valkey + Meilisearch + Tika (a JVM) — budget ~4 GB RAM\n'
printf '    - app data in Docker volumes on the OS disk (off the archive budget); the archive is NEVER mounted\n'
printf '    - import mail by copying files into: %s/import   (mounted READ-ONLY into the app)\n' "$APP_DIR"
if [[ "$bind_kind" == "loopback" ]]; then
  printf '    - listens on 127.0.0.1:%s ONLY — publish it with archive-proxy-setup.sh (mail.<domain>)\n' "$OPENARCHIVER_PORT"
else
  printf '    - listens on the TAILNET at %s:%s — reachable from your Tailscale devices, not the LAN\n' "$OPENARCHIVER_BIND" "$OPENARCHIVER_PORT"
fi
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
MEILI_INDEXING_BATCH=500

REDIS_HOST=openarchiver-valkey
REDIS_PORT=6379
REDIS_PASSWORD=${redis_pw}
REDIS_TLS_ENABLED=false
# REDIS_USER is deliberately UNSET: our valkey uses plain --requirepass (no ACL users), so
# password-only auth is correct. Upstream's example value would not authenticate here.

# --- Storage. STORAGE_TYPE is REQUIRED: the backend throws "Invalid STORAGE_TYPE: undefined"
# at config load and every backend process dies, leaving a frontend that loads but can never
# reach its API. Learned the hard way — see docs/OPENARCHIVER-ASSESSMENT.md.
STORAGE_TYPE=local
STORAGE_LOCAL_ROOT_PATH=/var/lib/open-archiver
BODY_SIZE_LIMIT=100M

TIKA_URL=http://openarchiver-tika:9998
# OCR is the expensive operation: 1-3 SECONDS PER PAGE, measured on this box. Upstream's 20 s
# default is fine for born-digital PDFs and far too short for what we are actually indexing — a
# 25-page faxed will needs 25-75 s of OCR alone. When this expires the document is still imported,
# just indexed WITHOUT its text and without an error, so the search comes back empty for a document
# that is sitting right there. That is the one failure mode this archive cannot tolerate.
PDF_PARSE_TIMEOUT_MS=${OA_PDF_TIMEOUT_MS}

JWT_EXPIRES_IN=7d
RATE_LIMIT_WINDOW_MS=60000
RATE_LIMIT_MAX_REQUESTS=100
RETENTION_BATCH_SIZE=1000

# Deliberate policy for this archive:
ENABLE_DELETION=false
INGESTION_WORKER_CONCURRENCY=2
ALL_INCLUSIVE_ARCHIVE=true
# No live connectors are configured, so the scheduler has nothing to do — but it must still
# parse a valid cron expression or it exits.
SYNC_FREQUENCY=0 3 * * *
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
      - "${OPENARCHIVER_BIND}:${OPENARCHIVER_PORT}:3000"
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

# ---- Prove the BACKEND came up -----------------------------------------------------------------
# The app container runs a frontend AND a backend. A bad .env kills only the backend, and the
# frontend keeps serving happily — you get a UI that loads, cannot answer "is there an admin yet?",
# and silently falls back to a login page you can never get past. This script used to print
# "Done — Open Archiver is starting" in exactly that state. It does not any more.
log "Waiting for the backend to listen on :4000 (this is where a bad .env shows itself)"
backend_up=false
for _i in $(seq 1 36); do
  if sudo docker exec openarchiver-app node -e \
      'require("net").connect(4000,"127.0.0.1").on("connect",()=>{console.log("OPEN");process.exit(0)}).on("error",()=>process.exit(1))' \
      2>/dev/null | grep -q OPEN; then
    backend_up=true; break
  fi
  sleep 5
done

if [[ "$backend_up" != true ]]; then
  warn "THE BACKEND NEVER CAME UP."
  warn "The web UI will load and show a sign-in page, but no account can ever be created through it."
  printf '\n    Backend errors from the log:\n'
  ( cd "$APP_DIR" && sudo docker compose logs open-archiver 2>/dev/null ) \
    | grep -iE 'Error:|FATAL|ECONNREFUSED|Invalid ' | grep -v 'Proxy request failed' | head -15 | sed 's/^/      /'
  cat <<FAILED

    Most likely a missing or invalid value in ${APP_DIR}/.env — the backend validates its config at
    startup and exits on the first bad one, taking the API and all three workers with it.

    Full log:   cd ${APP_DIR} && sudo docker compose logs open-archiver | head -80
    Try again:  bash ${0##*/} --yes      (re-runs are safe; secrets are preserved)
FAILED
  exit 1
fi
info "backend is listening — the API, workers and UI are all up."

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
        curl -sI ${OPENARCHIVER_URL}/ | head -1     (expect HTTP 200 or a redirect)

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
