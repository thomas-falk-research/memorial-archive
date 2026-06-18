#!/usr/bin/env bash
#
# archive-doctor.sh — one-shot, READ-ONLY health check for the memorial-archive server.
#
# It inspects everything the suite sets up — storage and mounts (including writability, a read-only
# remount, fstab 'nofail', free space and disk SMART health), the archive and its integrity markers,
# the on-site/off-site backup, file permissions and credentials, the search index, the family apps
# (Immich, Paperless), the Caddy front door and friendly .home names, and the installed commands —
# and prints a plain-English check for each, with a concrete "fix:" next step for anything wrong.
#
# It NEVER changes anything, so it is always safe to run — especially right after setup or an update:
#
#     ./archive-doctor.sh
#
# Run it as your normal user (it never needs sudo). Exit status: 0 if nothing FAILED (warnings are
# allowed), 1 if any check FAILED — so it can also gate a scheduled job.
#
set -uo pipefail

# Where this script (and its sibling *-setup.sh) live — used to detect "stale install" drift below.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
arch_src=""
if [[ -d "$ARCHIVE_ROOT" ]] && is_sep_mount "$ARCHIVE_ROOT"; then
  src="$(findmnt -no SOURCE -T "$ARCHIVE_ROOT" 2>/dev/null)"; arch_src="$src"
  avail="$(df -PB1 "$ARCHIVE_ROOT" 2>/dev/null | awk 'NR==2{print $4}')"; avail="${avail:-0}"
  used_b="$(du -sb --exclude='lost+found' --exclude='.recoll' --exclude='.plocate.db' --exclude='.derived' "$ARCHIVE_ROOT" 2>/dev/null | cut -f1)"; used_b="${used_b:-0}"
  used_g=$(( used_b / 1024 / 1024 / 1024 ))
  ok "Archive on its own volume (${src}); ${used_g} GiB used, $(human "$avail") free."
  # Silent-failure guards: a read-only remount (filesystem errors) or wrong ownership both make every
  # future ingest fail, yet nothing else looks wrong until you try to copy.
  if [[ ",$(findmnt -no OPTIONS -T "$ARCHIVE_ROOT" 2>/dev/null)," == *,ro,* ]]; then
    no "Archive is mounted READ-ONLY — new ingests will fail. Filesystem errors can force this (a failing disk?)."
    fix "check 'dmesg | tail -50'; unmount and fsck, or replace the drive (back up first)"
  elif [[ -w "$ARCHIVE_ROOT" ]]; then
    ok "Archive is writable by $(id -un) (ingest can write here)."
  else
    no "Archive is NOT writable by $(id -un) — ingest-verify can't create copies."
    fix "give your user ownership: sudo chown $(id -un):$(id -gn) ${ARCHIVE_ROOT}"
  fi
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
  if [[ -n "$arch_src" && "$bsrc" == "$arch_src" ]]; then
    no "Backup and archive are the SAME volume (${bsrc}) — one disk failure loses BOTH copies."
    fix "attach a separate backup target: archive-storage attach-backup"
  fi
else
  wn "No backup target mounted at ${BACKUP_ROOT}."
  fix "attach one: archive-storage attach-backup   (external drive, or NFS/SMB share)"
fi

# The OS disk carries the apps' data, Docker images and logs — if it fills, they fail quietly.
root_avail="$(df -PB1 / 2>/dev/null | awk 'NR==2{print $4}')"; root_avail="${root_avail:-0}"
root_pct="$(df -P / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')"; root_pct="${root_pct:-0}"
if   (( root_pct >= 95 )); then no "OS disk (/) is ${root_pct}% full ($(human "$root_avail") free) — apps/Docker/logs can fail."; fix "free space on /, e.g. prune Docker images: sudo docker system prune -a"
elif (( root_pct >= 90 )); then wn "OS disk (/) is ${root_pct}% full ($(human "$root_avail") free)."
else ok "OS disk (/) has $(human "$root_avail") free (${root_pct}% used)."; fi

# ---- 2b. boot safety (fstab nofail) ----------------------------------------------------------
hdr "Boot safety (fstab)"
if [[ -r /etc/fstab ]]; then
  for mp in "$ARCHIVE_ROOT" "$BACKUP_ROOT"; do
    fline="$(awk -v m="$mp" '$1 !~ /^#/ && $2==m {print; exit}' /etc/fstab)"
    if [[ -z "$fline" ]]; then
      note "${mp}: no /etc/fstab entry (mounted by hand, or not persistent across reboot)."
    elif [[ ",$(printf '%s' "$fline" | awk '{print $4}')," == *,nofail,* ]]; then
      ok "${mp}: fstab entry has 'nofail' (a missing drive can't block boot)."
    else
      no "${mp}: fstab entry is MISSING 'nofail' — a missing/failed drive can hang boot."
      fix "add nofail to its options in /etc/fstab (archive-storage attach-* does this for you)"
    fi
  done
else
  note "No readable /etc/fstab."
fi

# ---- 2c. disk health (SMART; best-effort — reading it usually needs privileges) ---------------
hdr "Disk health (SMART)"
if ! have smartctl; then
  note "smartctl not installed — can't check drive SMART health.  (sudo apt install smartmontools)"
else
  declare -A _smart_seen=()
  for entry in "OS:/" "Archive:${ARCHIVE_ROOT}"; do
    lbl="${entry%%:*}"; path="${entry#*:}"
    [[ -d "$path" ]] || continue
    dsrc="$(findmnt -no SOURCE -T "$path" 2>/dev/null)"
    [[ "$dsrc" == /dev/* ]] || { note "${lbl} (${path}): not a plain local disk — skipping SMART."; continue; }
    pk="$(lsblk -no PKNAME "$dsrc" 2>/dev/null | head -1)"; disk="${pk:+/dev/$pk}"; disk="${disk:-$dsrc}"
    [[ -n "${_smart_seen[$disk]:-}" ]] && continue; _smart_seen[$disk]=1
    sout="$(smartctl -H "$disk" 2>/dev/null)"
    if   [[ -z "$sout" ]]; then note "${lbl} (${disk}): SMART needs privileges here — run: sudo smartctl -H ${disk}"
    elif printf '%s' "$sout" | grep -qiE 'PASSED|result: *ok'; then ok "${lbl} disk ${disk}: SMART self-assessment PASSED."
    elif printf '%s' "$sout" | grep -qiE 'FAIL'; then no "${lbl} disk ${disk}: SMART reports FAILING — copy data off and replace it NOW."; fix "investigate: sudo smartctl -a ${disk}"
    else note "${lbl} (${disk}): SMART status unclear — run: sudo smartctl -H ${disk}"; fi
  done
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

# ---- 4b. permissions & credentials -----------------------------------------------------------
hdr "Permissions & credentials"
if [[ -e /etc/archive-backup.cred ]]; then
  cred_perm="$(stat -c '%a' /etc/archive-backup.cred 2>/dev/null)"; cred_own="$(stat -c '%U' /etc/archive-backup.cred 2>/dev/null)"
  if [[ "$cred_own" == root && "$cred_perm" == 600 ]]; then
    ok "Backup credentials (/etc/archive-backup.cred) are root-owned and 0600."
  else
    no "Backup credentials (/etc/archive-backup.cred) are ${cred_own:-?}:${cred_perm:-?} — secrets readable by others."
    fix "sudo chown root:root /etc/archive-backup.cred && sudo chmod 600 /etc/archive-backup.cred"
  fi
else
  note "No /etc/archive-backup.cred (only needed for a password-protected SMB/CIFS backup share)."
fi
if [[ -e /etc/archive-ingest.conf ]]; then
  conf_perm="$(stat -c '%a' /etc/archive-ingest.conf 2>/dev/null)"
  if [[ "${conf_perm: -1}" =~ [2367] ]]; then
    wn "/etc/archive-ingest.conf is world-writable (${conf_perm}) — anyone could change archive settings."
    fix "sudo chmod o-w /etc/archive-ingest.conf"
  else
    ok "Config /etc/archive-ingest.conf is not world-writable (${conf_perm})."
  fi
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
  for entry in "Immich:2283:immich" "Paperless:8000:paperless" "Files (copyparty):3923:copyparty" "Duplicates (czkawka):5800:czkawka" "PDF tools (Stirling):8082:stirling" "Notes (Docmost):3000:docmost"; do
    nm="${entry%%:*}"; rest="${entry#*:}"; port="${rest%%:*}"; dir="${rest#*:}"
    listening "$port"; lp=$?
    if   [[ $lp -eq 0 ]]; then ok "${nm} is responding on :${port}."
    elif [[ -d "$APPS_ROOT/$dir" ]]; then
      no "${nm} is deployed but not responding on :${port}."
      fix "cd ${APPS_ROOT}/${dir} && sudo docker compose up -d   (then: sudo docker compose logs -f)"
    else note "${nm} not deployed (optional)."; fi
  done
fi
if [[ -x /usr/local/bin/archive-apps ]]; then
  note "Manage every app from one place:  archive-apps status · archive-apps update · archive-apps logs <app>"
elif [[ -d "$APPS_ROOT" ]] && [[ -n "$(find "$APPS_ROOT" -mindepth 2 -maxdepth 2 -name docker-compose.yml -print -quit 2>/dev/null)" ]]; then
  note "Tip: 'archive-apps-setup.sh' installs one command (archive-apps) to update/inspect all apps at once."
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
  fn_names=(archive photos docs search)
  [[ -d "$APPS_ROOT/copyparty" ]] && fn_names+=(files)
  [[ -d "$APPS_ROOT/czkawka" ]] && fn_names+=(dupes)
  [[ -d "$APPS_ROOT/stirling" ]] && fn_names+=(pdf)
  [[ -d "$APPS_ROOT/docmost" ]] && fn_names+=(docmost)
  for n in "${fn_names[@]}"; do
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
# Encrypted, deduplicated off-site snapshots (restic), if set up — checked by its own verified marker.
if have archive-restic && [[ -d "$BACKUP_ROOT" ]] && is_sep_mount "$BACKUP_ROOT"; then
  rmarker="$BACKUP_ROOT/.archive-restic.verified"
  if [[ -f "$rmarker" ]]; then
    rmts="$(stat -c %Y "$rmarker" 2>/dev/null || echo 0)"; rage_d=$(( ( $(date +%s) - rmts ) / 86400 ))
    if (( rage_d > BACKUP_STALE_DAYS )); then wn "Encrypted (restic) snapshot last verified ${rage_d} day(s) ago (older than ${BACKUP_STALE_DAYS})."; fix "archive-restic backup"
    else ok "Encrypted (restic) snapshot verified ${rage_d} day(s) ago."; fi
  else
    wn "Restic is installed but has no verified encrypted snapshot yet."
    fix "run one: archive-restic backup"
  fi
fi

# ---- 9b. family app data backup (their DB/tags/uploads live outside the archive) -------------
hdr "App data backup"
app_inst=false
for _d in immich paperless docmost; do [[ -d "$APPS_ROOT/$_d" ]] && app_inst=true; done
if [[ "$app_inst" != true ]]; then
  note "No family apps installed (optional) — nothing extra to back up."
elif [[ -d "$BACKUP_ROOT" ]] && is_sep_mount "$BACKUP_ROOT"; then
  amarker="$BACKUP_ROOT/apps/.apps-backup.verified"
  if [[ -f "$amarker" ]]; then
    amts="$(stat -c %Y "$amarker" 2>/dev/null || echo 0)"; aage=$(( ( $(date +%s) - amts ) / 86400 ))
    if (( aage > BACKUP_STALE_DAYS )); then
      wn "App data (Immich/Paperless/Docmost — their DBs, tags, uploads) last backed up ${aage} day(s) ago (older than ${BACKUP_STALE_DAYS})."
      fix "run a verified backup — it includes the apps: archive-backup"
    else
      ok "App data backed up ${aage} day(s) ago (Immich/Paperless/Docmost — DBs, tags, uploads)."
    fi
  else
    wn "Family apps (Immich/Paperless/Docmost) are installed but their OWN data has never been backed up."
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
  [archive-credentials]=archive-credentials-setup.sh
  [archive-restic]=archive-restic-setup.sh
)
missing=0
for cmd in safe-mount ingest-verify archive-verify archive archive-index archive-search archive-find archive-storage archive-backup; do
  if have "$cmd"; then :; else no "Command '${cmd}' is not installed."; fix "run ${from[$cmd]}"; missing=$((missing+1)); fi
done
(( missing == 0 )) && ok "All core commands are installed."

# Version drift (the "stale-install trap"): a git pull updates these repo files but NOT the commands
# already in /usr/local/bin. When run from the checkout, flag any setup script that is newer than the
# command(s) it installed, so an out-of-date command can't masquerade as current. Warning only — the
# fix (re-run the setup) is always safe and idempotent. Skipped for non-git copies (e.g. a ZIP).
if [[ -d "$SCRIPT_DIR/.git" ]]; then
  declare -A _drift_seen=()
  _drift_checked=0; _drift_found=0
  for cmd in "${!from[@]}"; do
    s="${from[$cmd]}"
    have "$cmd" || continue
    [[ -f "$SCRIPT_DIR/$s" ]] || continue
    _drift_checked=1
    cmt="$(stat -c %Y "$(command -v "$cmd")" 2>/dev/null || echo 0)"
    smt="$(stat -c %Y "$SCRIPT_DIR/$s" 2>/dev/null || echo 0)"
    if (( smt > cmt )) && [[ -z "${_drift_seen[$s]:-}" ]]; then
      wn "${s} is newer than its installed command(s) — they may be out of date (stale-install trap)."
      fix "refresh them: ./manage.sh → Update   (or: bash ${s})"
      _drift_seen[$s]=1; _drift_found=1
    fi
  done
  (( _drift_checked == 1 && _drift_found == 0 )) && ok "Installed commands match the repo (no stale-install drift)."
else
  note "After a 'git pull', re-run the matching *-setup.sh to refresh installed commands (they don't update on their own)."
fi

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
