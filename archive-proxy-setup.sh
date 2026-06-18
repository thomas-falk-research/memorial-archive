#!/usr/bin/env bash
#
# archive-proxy-setup.sh — one front door for the family apps.
#
# Replaces the per-app ports with friendly hostnames via a single Caddy on port 80:
#   archive.<domain>  -> a portal page (Photos / Documents / Search buttons)  [also the default
#                        page for the machine's IP / hostname / any unmatched name]
#   photos.<domain>   -> Immich        (reverse proxy to 127.0.0.1:2283)
#   docs.<domain>     -> Paperless-ngx (reverse proxy to 127.0.0.1:8000)
#   search.<domain>   -> recoll web UI (reverse proxy to 127.0.0.1:8088, keeps its password)
#   files.<domain>    -> copyparty file browser (127.0.0.1:3923, same password) — only if installed
#
# Pair this with DNS rewrites in AdGuard Home: point those names at the mini-PC's LAN IP. The
# config accepts any hostname, so it also works over Tailscale once you route/resolve the names.
#
# Run as a REGULAR user with sudo. Run AFTER archive-webui-setup.sh (for the search service+login)
# and after the app stacks are up.
#
set -euo pipefail
umask 022
trap 'printf "\n\033[1;31mERROR\033[0m: command failed at line %s\n" "$LINENO" >&2' ERR

# ---- Configuration (override via environment) ------------------------------------------------
BASE_DOMAIN="${BASE_DOMAIN:-home}"
SITE_TITLE="${SITE_TITLE:-Family Archive}"
PORTAL_DIR="${PORTAL_DIR:-/srv/apps/portal}"
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
IMMICH_UPSTREAM="${IMMICH_UPSTREAM:-127.0.0.1:2283}"
PAPERLESS_UPSTREAM="${PAPERLESS_UPSTREAM:-127.0.0.1:8000}"
SEARCH_UPSTREAM="${SEARCH_UPSTREAM:-127.0.0.1:8088}"
COPYPARTY_UPSTREAM="${COPYPARTY_UPSTREAM:-127.0.0.1:3923}"
COPYPARTY_DIR="${COPYPARTY_DIR:-/srv/apps/copyparty}"
CZKAWKA_UPSTREAM="${CZKAWKA_UPSTREAM:-127.0.0.1:5800}"
CZKAWKA_DIR="${CZKAWKA_DIR:-/srv/apps/czkawka}"
SEARCH_USER="${SEARCH_USER:-family}"

PHOTOS_HOST="photos.${BASE_DOMAIN}"
DOCS_HOST="docs.${BASE_DOMAIN}"
SEARCH_HOST="search.${BASE_DOMAIN}"
FILES_HOST="files.${BASE_DOMAIN}"
DUPES_HOST="dupes.${BASE_DOMAIN}"
PORTAL_HOST="archive.${BASE_DOMAIN}"

# The Files browser (copyparty) is only routed/shown if it's installed — it serves anonymous-read on
# loopback, so (like search) Caddy must put it behind the family password.
copyparty_installed=false
[[ -d "$COPYPARTY_DIR" ]] && copyparty_installed=true
# czkawka (duplicate finder) is an admin tool: routed behind the same password if installed, but NOT
# shown as a family portal tile. It serves a no-auth GUI on loopback, so Caddy must gate it too.
czkawka_installed=false
[[ -d "$CZKAWKA_DIR" ]] && czkawka_installed=true

ASSUME_YES=false
usage() {
  cat <<USAGE
Usage: ${0##*/} [--yes|-y] [--help|-h]
  --yes, -y   skip the confirmation prompt; generate a search password if none exists
  --help, -h  show this help and exit
Env overrides: BASE_DOMAIN (default 'home'), SITE_TITLE, and the *_UPSTREAM addresses.
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
export DEBIAN_FRONTEND=noninteractive
sudo -v
command -v caddy >/dev/null 2>&1 || { log "Installing Caddy"; sudo apt-get update -y; sudo apt-get install -y caddy; }

lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

log "This will make Caddy the single front door on port 80, using sudo:"
printf '    %-18s -> portal page (Photos / Documents / Search)\n' "${PORTAL_HOST}"
printf '    %-18s -> Immich        (%s)\n' "${PHOTOS_HOST}" "$IMMICH_UPSTREAM"
printf '    %-18s -> Paperless-ngx (%s)\n' "${DOCS_HOST}" "$PAPERLESS_UPSTREAM"
printf '    %-18s -> recoll search (%s, keeps its login)\n' "${SEARCH_HOST}" "$SEARCH_UPSTREAM"
[[ "$copyparty_installed" == true ]] && printf '    %-18s -> files browser (%s, same login)\n' "${FILES_HOST}" "$COPYPARTY_UPSTREAM"
[[ "$czkawka_installed" == true ]] && printf '    %-18s -> duplicate finder (%s, same login; admin tool, no portal tile)\n' "${DUPES_HOST}" "$CZKAWKA_UPSTREAM"
printf '    portal also answers on the IP (%s) and any unmatched name\n' "${lan_ip:-this host}"
if [[ "${ASSUME_YES}" != "true" ]]; then
  read -rp $'\nProceed? [y/N] ' _ans
  [[ "${_ans}" =~ ^[Yy] ]] || { echo "Aborted; nothing was changed."; exit 0; }
fi

# ---- Reuse the existing recoll-search password (set by archive-webui-setup.sh) ----------------
log "Resolving the search login"
search_hash=""
if sudo test -f "$CADDYFILE"; then
  search_hash="$(sudo awk '$1=="basic_auth"||$1=="basicauth"{a=1} a&&$1=="'"$SEARCH_USER"'"{print $2; exit}' "$CADDYFILE" 2>/dev/null || true)"
fi
if [[ -n "$search_hash" ]]; then
  info "Reusing the existing '${SEARCH_USER}' search password."
else
  warn "No existing search password found in ${CADDYFILE}."
  if [[ "${ASSUME_YES}" == "true" ]]; then
    pw="$(openssl rand -base64 12 2>/dev/null || head -c 9 /dev/urandom | base64)"; GEN_SEARCH_PW="$pw"
  else
    read -rsp "Set a password for the '${SEARCH_USER}' search login: " pw; echo
    read -rsp "Confirm: " pw2; echo
    [[ -n "$pw" && "$pw" == "$pw2" ]] || die "Passwords empty or didn't match."
  fi
  search_hash="$(caddy hash-password --plaintext "$pw" 2>/dev/null)" || die "caddy hash-password failed."
  unset pw pw2
fi

# Caddy renamed basicauth -> basic_auth in 2.8; detect what this build accepts.
auth_dir="basic_auth"; probe="$(mktemp)"
printf 'http://x {\n  %s {\n    %s %s\n  }\n}\n' "$auth_dir" "$SEARCH_USER" "$search_hash" > "$probe"
caddy validate --adapter caddyfile --config "$probe" >/dev/null 2>&1 || auth_dir="basicauth"
rm -f "$probe"

# Optional portal tile + Caddy route for the Files browser (only when copyparty is installed).
files_card=""; files_dns=""
if [[ "$copyparty_installed" == true ]]; then
  files_card="$(cat <<HTMLCARD
    <a class="card" href="http://${FILES_HOST}/"><span class="emoji">📁</span>
      <span>Browse Files<br><span class="desc">open or download any file</span></span></a>
HTMLCARD
)"
  files_dns="$(printf '        %-16s -> %s' "${FILES_HOST}" "${lan_ip:-<mini-PC IP>}")"
fi
dupes_dns=""
if [[ "$czkawka_installed" == true ]]; then
  dupes_dns="$(printf '        %-16s -> %s' "${DUPES_HOST}" "${lan_ip:-<mini-PC IP>}")"
fi

# ---- Portal page -----------------------------------------------------------------------------
log "Writing the portal page to ${PORTAL_DIR}"
sudo mkdir -p "$PORTAL_DIR"
sudo tee "$PORTAL_DIR/index.html" >/dev/null <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${SITE_TITLE}</title>
<style>
  :root { color-scheme: light dark; }
  body { margin:0; min-height:100vh; display:flex; flex-direction:column; align-items:center;
         justify-content:center; gap:1.5rem; font-family:-apple-system,Segoe UI,Roboto,sans-serif;
         background:#0f1115; color:#e8eaed; padding:2rem; box-sizing:border-box; }
  h1 { font-weight:600; font-size:1.6rem; margin:0 0 .25rem; text-align:center; }
  p.sub { margin:0 0 1rem; color:#9aa0a6; text-align:center; }
  .grid { display:grid; gap:1rem; width:100%; max-width:420px; }
  a.card { display:flex; align-items:center; gap:1rem; text-decoration:none; color:inherit;
           background:#1b1e24; border:1px solid #2a2e36; border-radius:16px; padding:1.25rem 1.5rem;
           font-size:1.25rem; font-weight:600; transition:transform .08s ease, background .15s ease; }
  a.card:hover { background:#222732; transform:translateY(-1px); }
  .emoji { font-size:1.9rem; line-height:1; }
  .desc { font-size:.85rem; font-weight:400; color:#9aa0a6; }
  footer { color:#5f6368; font-size:.8rem; }
</style>
</head>
<body>
  <div>
    <h1>${SITE_TITLE}</h1>
    <p class="sub">Choose what to open</p>
  </div>
  <div class="grid">
    <a class="card" href="http://${PHOTOS_HOST}/"><span class="emoji">🖼️</span>
      <span>Photos &amp; Videos<br><span class="desc">browse the photo timeline</span></span></a>
    <a class="card" href="http://${DOCS_HOST}/"><span class="emoji">📄</span>
      <span>Documents<br><span class="desc">scanned papers, PDFs, letters</span></span></a>
    <a class="card" href="http://${SEARCH_HOST}/"><span class="emoji">🔎</span>
      <span>Search Everything<br><span class="desc">find any file by word or name</span></span></a>
${files_card}
  </div>
  <footer>${PORTAL_HOST}</footer>
</body>
</html>
HTML

# ---- Caddyfile -------------------------------------------------------------------------------
log "Writing ${CADDYFILE} (backing up the current one)"
[[ -f "${CADDYFILE}.preproxy" ]] || sudo cp -a "$CADDYFILE" "${CADDYFILE}.preproxy" 2>/dev/null || true
sudo tee "$CADDYFILE" >/dev/null <<CADDY
# Managed by archive-proxy-setup.sh — single front door on port 80.
{
	auto_https off
}

# Portal page; also the default for the IP / hostname / any unmatched host.
:80 {
	root * ${PORTAL_DIR}
	file_server
}

http://${PHOTOS_HOST} {
	reverse_proxy ${IMMICH_UPSTREAM}
}

http://${DOCS_HOST} {
	reverse_proxy ${PAPERLESS_UPSTREAM}
}

http://${SEARCH_HOST} {
	${auth_dir} {
		${SEARCH_USER} ${search_hash}
	}
	reverse_proxy ${SEARCH_UPSTREAM}
}
CADDY

# Append the Files (copyparty) route only when installed. copyparty serves anonymous-read on
# loopback, so — exactly like search — Caddy gates it with the family password.
if [[ "$copyparty_installed" == true ]]; then
  sudo tee -a "$CADDYFILE" >/dev/null <<CADDY2

http://${FILES_HOST} {
	${auth_dir} {
		${SEARCH_USER} ${search_hash}
	}
	reverse_proxy ${COPYPARTY_UPSTREAM}
}
CADDY2
  info "Added the Files browser route: ${FILES_HOST} -> ${COPYPARTY_UPSTREAM} (password-protected)."
fi

# Append the duplicate-finder (czkawka) route only when installed — an admin tool, behind the same
# password. Caddy proxies its noVNC WebSocket transparently.
if [[ "$czkawka_installed" == true ]]; then
  sudo tee -a "$CADDYFILE" >/dev/null <<CADDY3

http://${DUPES_HOST} {
	${auth_dir} {
		${SEARCH_USER} ${search_hash}
	}
	reverse_proxy ${CZKAWKA_UPSTREAM}
}
CADDY3
  info "Added the duplicate-finder route: ${DUPES_HOST} -> ${CZKAWKA_UPSTREAM} (password-protected)."
fi

log "Validating and reloading Caddy"
if sudo caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1; then
  sudo systemctl enable --now caddy >/dev/null 2>&1 || true
  sudo systemctl reload caddy 2>/dev/null || sudo systemctl restart caddy
  info "Caddy reloaded (search auth directive: ${auth_dir})."
else
  [[ -f "${CADDYFILE}.preproxy" ]] && sudo cp -a "${CADDYFILE}.preproxy" "$CADDYFILE"
  die "Caddy config invalid — reverted. Check ${CADDYFILE}."
fi

if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  sudo ufw allow 80/tcp >/dev/null 2>&1 || true
  info "opened port 80 in ufw for the local network."
fi

log "Done — the front door is up."
cat <<EOF
    Next: add these DNS rewrites in AdGuard Home (Filters -> DNS rewrites), all to ${lan_ip:-<mini-PC LAN IP>}:
        ${PORTAL_HOST}   -> ${lan_ip:-<mini-PC IP>}
        ${PHOTOS_HOST}   -> ${lan_ip:-<mini-PC IP>}
        ${DOCS_HOST}     -> ${lan_ip:-<mini-PC IP>}
        ${SEARCH_HOST}   -> ${lan_ip:-<mini-PC IP>}
${files_dns}
${dupes_dns}

    Then, from any device using AdGuard for DNS:
        http://${PORTAL_HOST}/     <- the one address to remember (portal with buttons)
        http://${PHOTOS_HOST}/     http://${DOCS_HOST}/     http://${SEARCH_HOST}/

    Notes:
      - The portal also loads at  http://${lan_ip:-<mini-PC IP>}/  right now (before DNS), but its
        buttons need the names above to resolve.
      - Paperless: so its login works under the new name, set in /srv/apps/paperless/docker-compose.env
          PAPERLESS_URL=http://${DOCS_HOST}
        then:  cd /srv/apps/paperless && sudo docker compose up -d
      - Over Tailscale later: advertise your LAN subnet from the mini-PC and set AdGuard as the
        tailnet DNS, and these same names work remotely (no changes here).
      - Edit the portal look any time: ${PORTAL_DIR}/index.html  (then it's served as-is).
EOF
[[ -n "${GEN_SEARCH_PW:-}" ]] && warn "Generated search password: ${GEN_SEARCH_PW} (save it now)."
