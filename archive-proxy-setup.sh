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
STIRLING_UPSTREAM="${STIRLING_UPSTREAM:-127.0.0.1:8082}"
STIRLING_DIR="${STIRLING_DIR:-/srv/apps/stirling}"
DOCMOST_UPSTREAM="${DOCMOST_UPSTREAM:-127.0.0.1:3000}"
DOCMOST_DIR="${DOCMOST_DIR:-/srv/apps/docmost}"
SEARCH_USER="${SEARCH_USER:-family}"

PHOTOS_HOST="photos.${BASE_DOMAIN}"
DOCS_HOST="docs.${BASE_DOMAIN}"
SEARCH_HOST="search.${BASE_DOMAIN}"
FILES_HOST="files.${BASE_DOMAIN}"
DUPES_HOST="dupes.${BASE_DOMAIN}"
PDF_HOST="pdf.${BASE_DOMAIN}"
DOCMOST_HOST="docmost.${BASE_DOMAIN}"
PORTAL_HOST="archive.${BASE_DOMAIN}"

# The Files browser (copyparty) is only routed/shown if it's installed — it serves anonymous-read on
# loopback, so (like search) Caddy must put it behind the family password.
copyparty_installed=false
[[ -d "$COPYPARTY_DIR" ]] && copyparty_installed=true
# czkawka (duplicate finder) is an admin tool: routed behind the same password if installed, but NOT
# shown as a family portal tile. It serves a no-auth GUI on loopback, so Caddy must gate it too.
czkawka_installed=false
[[ -d "$CZKAWKA_DIR" ]] && czkawka_installed=true
# Stirling-PDF is a family-usable tool: routed AND shown as a portal tile when installed.
stirling_installed=false
[[ -d "$STIRLING_DIR" ]] && stirling_installed=true
# Docmost is a read-WRITE notes/wiki with its OWN logins — routed AND shown as a portal tile, but
# (like Immich/Paperless) WITHOUT the Caddy password, since it authenticates its own users.
docmost_installed=false
[[ -d "$DOCMOST_DIR" ]] && docmost_installed=true

ASSUME_YES=false
RESET_SEARCH_PW="${RESET_SEARCH_PW:-}"
usage() {
  cat <<USAGE
Usage: ${0##*/} [--yes|-y] [--reset-search-password] [--help|-h]
  --yes, -y                 skip the confirmation prompt; generate a search password if none exists
  --reset-search-password   set a NEW family/search password (same as RESET_SEARCH_PW=1)
  --help, -h                show this help and exit
Env overrides: BASE_DOMAIN (default 'home'), SITE_TITLE, RESET_SEARCH_PW, and the *_UPSTREAM addresses.
USAGE
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)  ASSUME_YES=true ;;
    --reset-search-password) RESET_SEARCH_PW=1 ;;
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
[[ "$stirling_installed" == true ]] && printf '    %-18s -> PDF tools (%s, same login)\n' "${PDF_HOST}" "$STIRLING_UPSTREAM"
[[ "$docmost_installed" == true ]] && printf '    %-18s -> notes/wiki (%s, its OWN login)\n' "${DOCMOST_HOST}" "$DOCMOST_UPSTREAM"
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
if [[ -n "$search_hash" && "$RESET_SEARCH_PW" != "1" ]]; then
  info "Reusing the existing '${SEARCH_USER}' search password."
else
  if [[ "$RESET_SEARCH_PW" == "1" && -n "$search_hash" ]]; then
    warn "Resetting the '${SEARCH_USER}' search/family password (RESET_SEARCH_PW)."
  else
    warn "No existing search password found in ${CADDYFILE}."
  fi
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
pdf_card=""; pdf_dns=""
if [[ "$stirling_installed" == true ]]; then
  pdf_card="$(cat <<HTMLCARD
    <a class="card" href="http://${PDF_HOST}/"><span class="emoji">🛠️</span>
      <span>PDF Tools<br><span class="desc">merge, split, OCR, convert PDFs</span></span></a>
HTMLCARD
)"
  pdf_dns="$(printf '        %-16s -> %s' "${PDF_HOST}" "${lan_ip:-<mini-PC IP>}")"
fi
notes_card=""; notes_dns=""
if [[ "$docmost_installed" == true ]]; then
  notes_card="$(cat <<HTMLCARD
    <a class="card" href="http://${DOCMOST_HOST}/"><span class="emoji">📝</span>
      <span>Notes &amp; Memories<br><span class="desc">write a biography, notes, to-dos</span></span></a>
HTMLCARD
)"
  notes_dns="$(printf '        %-16s -> %s' "${DOCMOST_HOST}" "${lan_ip:-<mini-PC IP>}")"
fi

# Direct-access buttons (LAN IP + Tailscale IP) under the tiles for the apps that are actually
# published on the network AND carry their own auth: Photos (Immich) and Documents (Paperless) keep
# their own login, and Search keeps the family password (on its WEBUI_PORT front). These work with no
# DNS at all. The other tiles (Files/PDF/Notes) stay name-only on purpose — their password lives at
# the Caddy front door, so a direct IP:port would BYPASS it; reach those via the *.home names once the
# AdGuard rewrites below are set.
ts_ip=""
if command -v tailscale >/dev/null 2>&1; then ts_ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"; fi
IMMICH_PORT="${IMMICH_UPSTREAM##*:}"
PAPERLESS_PORT="${PAPERLESS_UPSTREAM##*:}"
WEBUI_PORT="${WEBUI_PORT:-8080}"   # password-protected search web UI (set up by archive-webui-setup.sh)
# Only offer the direct Search buttons if that web UI is actually listening (it is optional/separate).
webui_present=false
if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${WEBUI_PORT}$"; then
  webui_present=true
fi

# Build a small row of "LAN <ip:port>" / "Tailscale <ip:port>" links for a given port.
iplinks_row() {  # $1 = port; prints a <div class="iplinks">..</div>, or nothing if no IP is known
  local port="$1" row=""
  [[ -n "$lan_ip" ]] && row+="<a class=\"ip\" href=\"http://${lan_ip}:${port}/\">🏠 LAN ${lan_ip}:${port}</a>"
  [[ -n "$ts_ip"  ]] && row+="<a class=\"ip\" href=\"http://${ts_ip}:${port}/\">🔒 Tailscale ${ts_ip}:${port}</a>"
  [[ -n "$row" ]] && printf '    <div class="iplinks">%s</div>' "$row"
  return 0
}
photos_iplinks="$(iplinks_row "$IMMICH_PORT")"
docs_iplinks="$(iplinks_row "$PAPERLESS_PORT")"
search_iplinks=""
[[ "$webui_present" == true ]] && search_iplinks="$(iplinks_row "$WEBUI_PORT")"
info "Direct app buttons → LAN ${lan_ip:-<unknown>}${ts_ip:+, Tailscale ${ts_ip}} (Photos/Documents${webui_present:+/Search})."

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
  .iplinks { display:flex; flex-wrap:wrap; gap:.5rem; margin:-.4rem 0 .2rem; justify-content:center; }
  a.ip { font-size:.78rem; font-weight:500; text-decoration:none; color:#9aa0a6;
         background:#15181e; border:1px solid #2a2e36; border-radius:8px; padding:.3rem .6rem; }
  a.ip:hover { background:#222732; color:#e8eaed; }
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
${photos_iplinks}
    <a class="card" href="http://${DOCS_HOST}/"><span class="emoji">📄</span>
      <span>Documents<br><span class="desc">scanned papers, PDFs, letters</span></span></a>
${docs_iplinks}
    <a class="card" href="http://${SEARCH_HOST}/"><span class="emoji">🔎</span>
      <span>Search Everything<br><span class="desc">find any file by word or name</span></span></a>
${search_iplinks}
${files_card}
${pdf_card}
${notes_card}
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

# Append the PDF tools (Stirling-PDF) route only when installed — behind the family password.
if [[ "$stirling_installed" == true ]]; then
  sudo tee -a "$CADDYFILE" >/dev/null <<CADDY4

http://${PDF_HOST} {
	${auth_dir} {
		${SEARCH_USER} ${search_hash}
	}
	reverse_proxy ${STIRLING_UPSTREAM}
}
CADDY4
  info "Added the PDF tools route: ${PDF_HOST} -> ${STIRLING_UPSTREAM} (password-protected)."
fi

# Append the Notes (Docmost) route only when installed. Docmost has its OWN logins, so — like
# Immich/Paperless — it is NOT behind the Caddy password (just a plain reverse_proxy). Its APP_URL
# was set to this same host so login cookies/links line up; Caddy proxies its WebSockets transparently.
if [[ "$docmost_installed" == true ]]; then
  sudo tee -a "$CADDYFILE" >/dev/null <<CADDY5

http://${DOCMOST_HOST} {
	reverse_proxy ${DOCMOST_UPSTREAM}
}
CADDY5
  info "Added the Notes route: ${DOCMOST_HOST} -> ${DOCMOST_UPSTREAM} (Docmost handles its own login)."
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
${pdf_dns}
${notes_dns}

    Then, from any device using AdGuard for DNS:
        http://${PORTAL_HOST}/     <- the one address to remember (portal with buttons)
        http://${PHOTOS_HOST}/     http://${DOCS_HOST}/     http://${SEARCH_HOST}/

    Notes:
      - The portal also loads at  http://${lan_ip:-<mini-PC IP>}/  right now, before any DNS. Photos,
        Documents and Search show direct "LAN" and "Tailscale" buttons there that work without DNS
        (each keeps its own login / the family password); the Files/PDF/Notes name-buttons still need
        the rewrites above to resolve.
      - Paperless: so its login works under the new name, set in /srv/apps/paperless/docker-compose.env
          PAPERLESS_URL=http://${DOCS_HOST}
        then:  cd /srv/apps/paperless && sudo docker compose up -d
      - Over Tailscale later: advertise your LAN subnet from the mini-PC and set AdGuard as the
        tailnet DNS, and these same names work remotely (no changes here).
      - Edit the portal look any time: ${PORTAL_DIR}/index.html  (then it's served as-is).
EOF
[[ -n "${GEN_SEARCH_PW:-}" ]] && warn "Generated search password: ${GEN_SEARCH_PW} (save it now)."
