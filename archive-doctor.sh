#!/usr/bin/env bash
#
# archive-doctor.sh — one-shot, READ-ONLY health check for the memorial-archive server.
#
# It inspects everything the suite sets up — storage and mounts, the archive and its integrity
# markers, the on-site/off-site backup, the search index, the family apps (Immich, Paperless),
# the Caddy front door and friendly .home names, and the installed commands — and prints a
# plain-English check for each, with a concrete "fix:" next step for anything that isn't healthy.
#
# It NEVER changes anything, so it is always safe to run — especially right after setup or an update:
#
#     ./archive-doctor.sh
#
# Run it as your normal user (it never needs sudo). Exit status: 0 if nothing FAILED (warnings are
# allowed), 1 if any check FAILED — so it can also gate a scheduled job.
#
set -uo pipefail

# ---- settings (the same files the other tools read) ------------------------------------------
for _cfg in /etc/archive-ingest.conf "${XDG_CONFIG_HOME:-$HOME/.config}/archive-ingest.conf"; do
  # shellcheck source=/dev/null
  [[ -r "$_cfg" ]] && { . "$_cfg" || true; }
done
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"
BACKUP_ROOT="${BACKUP_ROOT:-/srv/backup}"
APPS_ROOT="${APPS_ROOT:-/srv/apps}"
MAX_ARCHIVE_GIB="${MAX_ARCHIVE_GIB:-1800}"
MIN_FREE_GIB="${MIN_FREE_GIB:-10}"
BASE_DOMAIN="${BASE_DOMAIN:-home}"
RECOLL_CONFDIR="${RECOLL_CONFDIR:-${ARCHIVE_ROOT}/.recoll}"
PLOCATE_DB="${PLOCATE_DB:-${ARCHIVE_ROOT}/.plocate.db}"
BACKUP_STALE_DAYS="${BACKUP_STALE_DAYS:-30}"

# ---- output helpers --------------------------------------------------------------------------
if [[ -t 1 ]]; then
  c_red=$'\033[1;31m'; c_grn=$'\033[1;32m'; c_yel=$'\033[1;33m'; c_cyn=$'\033[0;36m'; c_dim=$'\033[2m'; c_rst=$'\033[0m'
else c_red=""; c_grn=""; c_yel=""; c_cyn=""; c_dim=""; c_rst=""; fi
n_ok=0; n_warn=0; n_fail=0
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; n_ok=$((n_ok+1)); }
wn()   { printf '  %s!%s %s\n' "$c_yel" "$c_rst" "$*"; n_warn=$((n_warn+1)); }
no()   { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*"; n_fail=$((n_fail+1)); }
note() { printf '  %s·%s %s\n' "$c_dim" "$c_rst" "$*"; }
fix()  { printf '      %s↳ fix: %s%s\n' "$c_cyn" "$*" "$c_rst"; }
hdr()  { printf '\n%s━━ %s%s\n' "$c_cyn" "$*" "$c_rst"; }
human(){ numfmt --to=iec "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"; }
have() { command -v "$1" >/dev/null 2>&1; }

is_sep_mount() { [[ "$(findmnt -no TARGET -T "$1" 2>/dev/null)" == "$1" ]]; }
listening() {  # $1 = port. return 0 = yes, 1 = no, 2 = can't tell
  have ss || return 2
  [[ -n "$(ss -Htln "sport = :$1" 2>/dev/null)" ]]
}
http_code() {  # $1 = hostname, resolved to 127.0.0.1 so we test the front door regardless of DNS
  curl -s -o /dev/null -m 6 -w '%{http_code}' --resolve "$1:80:127.0.0.1" "http://$1/" 2>/dev/null || echo 000
}

printf '%s' "$c_cyn"
printf '╭───────────────────────────────────────────╮\n'
printf '│  archive-doctor — memorial-archive health   │\n'
printf '╰───────────────────────────────────────────╯%s\n' "$c_rst"
printf '%shost: %s   date: %s%s\n' "$c_dim" "$(hostname 2>/dev/null || echo '?')" "$(date '+%Y-%m-%d %H:%M')" "$c_rst"

# ---- 1. settings -----------------------------------------------------------------------------
hdr "Settings"
if [[ -r /etc/archive-ingest.conf ]]; then
  ok "Config found: /etc/archive-ingest.conf"
else
  no "No /etc/archive-ingest.conf — the tools fall back to defaults."
  fix "run archive-ingest-setup.sh (it writes the config)"
fi
note "archive=${ARCHIVE_ROOT}  backup=${BACKUP_ROOT}  cap=${MAX_ARCHIVE_GIB} GiB  domain=*.${BASE_DOMAIN}"

# ---- 2. storage & mounts ---------------------------------------------------------------------
hdr "Storage"
if [[ -d "$ARCHIVE_ROOT" ]] && is_sep_mount "$ARCHIVE_ROOT"; then
  src="$(findmnt -no SOURCE -T "$ARCHIVE_ROOT" 2>/dev/null)"
  avail="$(df -PB1 "$ARCHIVE_ROOT" 2>/dev/null | awk 'NR==2{print $4}')"; avail="${avail:-0}"
  used_b="$(du -sb --exclude='lost+found' --exclude='.recoll' --exclude='.plocate.db' "$ARCHIVE_ROOT" 2>/dev/null | cut -f1)"; used_b="${used_b:-0}"
  used_g=$(( used_b / 1024 / 1024 / 1024 ))
  ok "Archive on its own volume (${src}); ${used_g} GiB used, $(human "$avail") free."
  if   (( used_g >= MAX_ARCHIVE_GIB ));            then no "Archive is OVER the ${MAX_ARCHIVE_GIB} GiB soft cap."; fix "stop ingesting, or raise MAX_ARCHIVE_GIB / add storage"
  elif (( used_g * 10 >= MAX_ARCHIVE_GIB * 9 ));   then wn "Archive is within 10% of the ${MAX_ARCHIVE_GIB} GiB soft cap."; fi
elif [[ -d "$ARCHIVE_ROOT" ]]; then
  no "Archive (${ARCHIVE_ROOT}) is NOT a separate volume — it's on the OS disk."
  fix "attach the external archive disk: archive-storage attach-archive"
else
  no "Archive path ${ARCHIVE_ROOT} does not exist."
  fix "run archive-ingest-setup.sh, then archive-storage attach-archive"
fi

if [[ -d "$BACKUP_ROOT" ]] && is_sep_mount "$BACKUP_ROOT"; then
  bsrc="$(findmnt -no SOURCE -T "$BACKUP_ROOT" 2>/dev/null)"
  bavail="$(df -PB1 "$BACKUP_ROOT" 2>/dev/null | awk 'NR==2{print $4}')"; bavail="${bavail:-0}"
  ok "Backup target mounted (${bsrc}); $(human "$bavail") free."
else
  wn "No backup target mounted at ${BACKUP_ROOT}."
  fix "attach one: archive-storage attach-backup   (external drive, or NFS/SMB share)"
fi

# ---- 3. archive contents & integrity ---------------------------------------------------------
hdr "Archive integrity"
if [[ -d "$ARCHIVE_ROOT/incoming" ]]; then
  copies="$(find "$ARCHIVE_ROOT/incoming" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l)"
  incs="$(find "$ARCHIVE_ROOT/incoming" -name .INCOMPLETE 2>/dev/null | wc -l)"
  missing_manifest="$(find "$ARCHIVE_ROOT/incoming" -mindepth 2 -maxdepth 2 -type d \! -exec test -e '{}/SHA256SUMS' \; -print 2>/dev/null | wc -l)"
  note "${copies} verified copy(ies) under incoming/."
  if (( incs > 0 )); then
    no "${incs} copy(ies) marked .INCOMPLETE (a failed/partial ingest — not trustworthy)."
    fix "re-run the ingest from source, or delete the .INCOMPLETE folder(s): find ${ARCHIVE_ROOT}/incoming -name .INCOMPLETE"
  else
    ok "No .INCOMPLETE markers (no partial ingests)."
  fi
  if (( copies > 0 && missing_manifest > 0 )); then
    wn "${missing_manifest} copy(ies) have no SHA256SUMS manifest."
    fix "re-ingest those, or run a scrub: archive-verify"
  elif (( copies > 0 )); then
    ok "Every copy has a SHA256SUMS manifest."
    note "for a full bit-rot scrub (re-hash everything), run: archive-verify"
  fi
else
  note "Nothing ingested yet (no ${ARCHIVE_ROOT}/incoming)."
fi

# ---- 4. read-only safety ---------------------------------------------------------------------
hdr "Read-only safety"
if [[ -f /etc/udev/rules.d/99-archive-no-automount.rules ]]; then
  ok "USB auto-mount is disabled (udev rule present)."
else
  wn "USB auto-mount udev rule is missing — media could mount writable on plug-in."
  fix "re-run archive-ingest-setup.sh"
fi

# ---- 5. search index -------------------------------------------------------------------------
hdr "Search index"
if [[ -d "$RECOLL_CONFDIR" ]] && [[ -n "$(find "$RECOLL_CONFDIR" \( -name xapiandb -o -name '*.dbi' \) -print -quit 2>/dev/null)" ]]; then
  ok "Full-text index present (${RECOLL_CONFDIR})."
elif [[ -d "$RECOLL_CONFDIR" ]]; then
  wn "recoll config dir exists but the index looks empty."; fix "build it: archive-index"
else
  wn "No full-text index yet (${RECOLL_CONFDIR})."; fix "build it: archive-index   (after each ingest)"
fi
if [[ -s "$PLOCATE_DB" ]]; then ok "Filename index present (${PLOCATE_DB})."
else wn "No filename index yet (${PLOCATE_DB})."; fix "build it: archive-index"; fi

# ---- 6. family apps (by listening port — no docker access needed) ----------------------------
hdr "Family apps"
if ! have ss; then
  note "Can't check service ports ('ss' not found)."
else
  for entry in "Immich:2283:immich" "Paperless:8000:paperless"; do
    nm="${entry%%:*}"; rest="${entry#*:}"; port="${rest%%:*}"; dir="${rest#*:}"
    listening "$port"; lp=$?
    if   [[ $lp -eq 0 ]]; then ok "${nm} is responding on :${port}."
    elif [[ -d "$APPS_ROOT/$dir" ]]; then
      no "${nm} is deployed but not responding on :${port}."
      fix "cd ${APPS_ROOT}/${dir} && sudo docker compose up -d   (then: sudo docker compose logs -f)"
    else note "${nm} not deployed (optional)."; fi
  done
fi

# ---- 7. front door (Caddy) -------------------------------------------------------------------
hdr "Front door (Caddy)"
have_caddy=false; have ss || true
if have caddy; then have_caddy=true; fi
on80=1; on8080=1; on8088=1
if have ss; then listening 80; on80=$?; listening 8080; on8080=$?; listening 8088; on8088=$?; fi
if [[ "$have_caddy" == true ]]; then
  if systemctl is-active --quiet caddy 2>/dev/null; then ok "Caddy service is active."
  else wn "Caddy service is not active."; fix "sudo systemctl enable --now caddy"; fi
fi
if [[ $on80 -eq 0 ]]; then ok "Front door is up on :80 (friendly-name portal)."; fi
if [[ $on8080 -eq 0 ]]; then ok "Search web UI is up on :8080."; fi
if [[ $on8088 -eq 0 ]]; then ok "recoll search backend is up on 127.0.0.1:8088."
elif [[ $on80 -eq 0 || $on8080 -eq 0 ]]; then wn "recoll search backend (127.0.0.1:8088) isn't responding."; fix "re-run archive-webui-setup.sh, or check its systemd service"; fi
if [[ "$have_caddy" != true && $on80 -ne 0 && $on8080 -ne 0 ]]; then
  note "No web front end configured yet (optional)."
  fix "search UI: archive-webui-setup.sh   ·   one-URL portal: archive-proxy-setup.sh"
fi

# ---- 8. friendly names (only meaningful once the :80 front door is up) ------------------------
if [[ $on80 -eq 0 ]] && have curl; then
  hdr "Friendly names (tested through the front door)"
  for n in archive photos docs search; do
    name="${n}.${BASE_DOMAIN}"; code="$(http_code "$name")"
    case "$code" in
      000)     no  "${name} → no response from the front door." ; fix "sudo systemctl status caddy; re-run archive-proxy-setup.sh" ;;
      401)     ok  "${name} → ${code} (password prompt — correct for search)." ;;
      2*|30*)  ok  "${name} → ${code}." ;;
      5*)      wn  "${name} → ${code} (front door routes OK, but the app behind it is down — see 'Family apps' above)." ;;
      4*)      wn  "${name} → ${code} (front door reachable, but this route looks misconfigured)." ; fix "re-run archive-proxy-setup.sh" ;;
      *)       wn  "${name} → ${code} (unexpected — check the front door)." ;;
    esac
  done
  if ! getent hosts "archive.${BASE_DOMAIN}" >/dev/null 2>&1; then
    note "These names don't resolve from this machine itself — fine if the box doesn't use AdGuard for DNS; family devices that do will reach them. (The LAN IP always works: http://$(hostname -I 2>/dev/null | awk '{print $1}')/ )"
  fi
fi

# ---- 9. backup freshness ---------------------------------------------------------------------
hdr "Backup freshness"
if [[ -d "$BACKUP_ROOT" ]] && is_sep_mount "$BACKUP_ROOT"; then
  marker="$BACKUP_ROOT/.archive-backup.verified"
  haslog="$(find "$BACKUP_ROOT" -maxdepth 1 -name '.archive-backup.*.log' -print -quit 2>/dev/null)"
  if [[ -f "$marker" ]]; then
    mts="$(stat -c %Y "$marker" 2>/dev/null || echo 0)"; age_d=$(( ( $(date +%s) - mts ) / 86400 ))
    if (( age_d > BACKUP_STALE_DAYS )); then wn "Last VERIFIED backup was ${age_d} day(s) ago (older than ${BACKUP_STALE_DAYS})."; fix "run a fresh verified backup: archive-backup"
    else ok "Last VERIFIED backup was ${age_d} day(s) ago."; fi
  elif [[ -n "$haslog" ]]; then
    no "A backup has run but did NOT verify (it failed or was interrupted) — don't trust it."
    fix "re-run it and watch for 'Backup verified': archive-backup"
  else
    wn "No backup has run yet."
    fix "run the first verified backup: archive-backup"
  fi
else
  note "Skipped (no backup target mounted)."
fi

# ---- 9b. family app data backup (their DB/tags/uploads live outside the archive) -------------
hdr "App data backup"
app_inst=false
for _d in immich paperless; do [[ -d "$APPS_ROOT/$_d" ]] && app_inst=true; done
if [[ "$app_inst" != true ]]; then
  note "No family apps installed (optional) — nothing extra to back up."
elif [[ -d "$BACKUP_ROOT" ]] && is_sep_mount "$BACKUP_ROOT"; then
  amarker="$BACKUP_ROOT/apps/.apps-backup.verified"
  if [[ -f "$amarker" ]]; then
    amts="$(stat -c %Y "$amarker" 2>/dev/null || echo 0)"; aage=$(( ( $(date +%s) - amts ) / 86400 ))
    if (( aage > BACKUP_STALE_DAYS )); then
      wn "App data (Immich DB+uploads / Paperless export) last backed up ${aage} day(s) ago (older than ${BACKUP_STALE_DAYS})."
      fix "run a verified backup — it includes the apps: archive-backup"
    else
      ok "App data backed up ${aage} day(s) ago (Immich DB + uploads / Paperless export)."
    fi
  else
    wn "Immich/Paperless are installed but their OWN data has never been backed up."
    fix "run a verified backup — it now includes them: archive-backup"
  fi
else
  note "App data backup: skipped (no backup target mounted)."
fi

# ---- 10. installed commands ------------------------------------------------------------------
hdr "Installed commands"
declare -A from=(
  [safe-mount]=archive-ingest-setup.sh [ingest-verify]=archive-ingest-setup.sh
  [archive-verify]=archive-ingest-setup.sh [archive]=archive-ingest-setup.sh
  [archive-index]=archive-search-setup.sh [archive-search]=archive-search-setup.sh
  [archive-find]=archive-search-setup.sh
  [archive-storage]=archive-storage-setup.sh [archive-backup]=archive-storage-setup.sh
)
missing=0
for cmd in safe-mount ingest-verify archive-verify archive archive-index archive-search archive-find archive-storage archive-backup; do
  if have "$cmd"; then :; else no "Command '${cmd}' is not installed."; fix "run ${from[$cmd]}"; missing=$((missing+1)); fi
done
(( missing == 0 )) && ok "All core commands are installed."
note "After a 'git pull', re-run the matching *-setup.sh to refresh installed commands (they don't update on their own)."

# ---- summary ---------------------------------------------------------------------------------
printf '\n%s────────── summary ──────────%s\n' "$c_cyn" "$c_rst"
printf '  %s%d ok%s   %s%d warning(s)%s   %s%d problem(s)%s\n' \
  "$c_grn" "$n_ok" "$c_rst" "$c_yel" "$n_warn" "$c_rst" "$c_red" "$n_fail" "$c_rst"
if (( n_fail > 0 )); then
  printf '  %sSome checks FAILED — see the ✗ lines and their "fix:" above.%s\n' "$c_red" "$c_rst"; exit 1
elif (( n_warn > 0 )); then
  printf '  %sHealthy, with warnings (✗ none). The "!" items are worth doing when you can.%s\n' "$c_yel" "$c_rst"; exit 0
else
  printf '  %sEverything looks healthy.%s\n' "$c_grn" "$c_rst"; exit 0
fi
