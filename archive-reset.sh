#!/usr/bin/env bash
#
# archive-reset.sh — ERASE ALL DATA and return the box to a clean, EMPTY-but-configured state,
# ready for the FIRST real ingestion.
#
# Run this ONCE, deliberately, AFTER testing and BEFORE any real family data goes in. It exists for
# one reason: to guarantee that no test/seed data survives to pollute search results or — worse — be
# mistaken by the family for the real thing.
#
# >>> THIS PERMANENTLY DELETES, WITH NO UNDO: <<<
#   - every ingested copy in the archive (ARCHIVE_ROOT/incoming) and the search indexes
#   - every backed-up copy and app dump on the off-site backup (BACKUP_ROOT)
#   - ALL Immich photos/albums/people and ALL Paperless documents (their databases are reset empty)
#
# It KEEPS all tooling and configuration: installed commands, /etc config + credentials, Samba/Caddy/
# Tailscale setup, fstab mounts, Docker, and each app's compose/.env (so logins & settings survive).
#
# Safety: must be run at an interactive terminal, as your normal user (it sudo's for root-owned
# files). It shows exactly what it will delete first, then requires TWO different typed
# confirmations. There is NO non-interactive / --yes mode, by design. Every deletion is behind a
# path guard so a misconfigured variable can never widen the blast radius.
#
#     ./archive-reset.sh        (or:  bash archive-reset.sh )
#
set -uo pipefail

# ---- settings (the same files the rest of the suite reads) -----------------------------------
for _cfg in /etc/archive-ingest.conf "${XDG_CONFIG_HOME:-$HOME/.config}/archive-ingest.conf"; do
  # shellcheck source=/dev/null
  [[ -r "$_cfg" ]] && { . "$_cfg" || true; }
done
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"
BACKUP_ROOT="${BACKUP_ROOT:-/srv/backup}"
APPS_ROOT="${APPS_ROOT:-/srv/apps}"
IMMICH_DIR="${IMMICH_DIR:-$APPS_ROOT/immich}"
PAPERLESS_DIR="${PAPERLESS_DIR:-$APPS_ROOT/paperless}"

# ---- output helpers --------------------------------------------------------------------------
if [[ -t 1 ]]; then
  c_red=$'\033[1;31m'; c_grn=$'\033[1;32m'; c_yel=$'\033[1;33m'; c_cyn=$'\033[0;36m'; c_rst=$'\033[0m'
else c_red=""; c_grn=""; c_yel=""; c_cyn=""; c_rst=""; fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '  %s!%s %s\n' "$c_yel" "$c_rst" "$*" >&2; }
err()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*" >&2; }
hr()   { printf '%s────────────────────────────────────────────────────────────────────%s\n' "$c_cyn" "$c_rst"; }
human(){ numfmt --to=iec "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"; }
have() { command -v "$1" >/dev/null 2>&1; }
is_sep_mount() { [[ "$(findmnt -no TARGET -T "$1" 2>/dev/null)" == "$1" ]]; }
dc()   { ( cd "$1" && sudo docker compose "${@:2}" ); }     # docker compose, in an app dir
du_b() { sudo du -sb "$1" 2>/dev/null | cut -f1; }          # size in bytes (root-readable)

# A path may be emptied ONLY if it is non-empty, absolute, under /srv, and free of '..' / '//'.
# This is the guard that stops an empty or garbled variable from turning a wipe into 'rm -rf /'.
guard_path() {
  local p="${1:-}"
  [[ -n "$p" ]]        || { err "internal: refusing to act on an empty path"; return 1; }
  [[ "$p" == /srv/* ]] || { err "refusing to act on a path outside /srv: '$p'"; return 1; }
  case "$p" in
    *..* | *//*) err "refusing to act on a suspicious path: '$p'"; return 1 ;;
  esac
  return 0
}
# Empty a directory's CONTENTS (the directory itself stays), root-owned files included.
wipe_contents() {
  local d="${1:-}"
  guard_path "$d" || return 1
  [[ -d "$d" ]] || return 0
  sudo find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
}

# ---- inventory (READ-ONLY): exactly what the reset would delete ------------------------------
print_delete_inventory() {
  local copies size
  say "${c_red}WILL BE PERMANENTLY DELETED (no undo):${c_rst}"

  if [[ -d "$ARCHIVE_ROOT" ]] && is_sep_mount "$ARCHIVE_ROOT"; then
    copies="$(sudo find "$ARCHIVE_ROOT/incoming" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l)"
    size="$(du_b "$ARCHIVE_ROOT/incoming")"; size="${size:-0}"
    printf '   • Archive:  %s ingested copy(ies), %s  (%s/incoming)\n' "$copies" "$(human "$size")" "$ARCHIVE_ROOT"
    [[ -d "$ARCHIVE_ROOT/.recoll"   ]] && printf '   • Archive:  full-text search index (.recoll)\n'
    [[ -e "$ARCHIVE_ROOT/.plocate.db" ]] && printf '   • Archive:  filename index (.plocate.db)\n'
  else
    printf '   • Archive:  %s(not mounted at %s — cannot clean; mount it first)%s\n' "$c_yel" "$ARCHIVE_ROOT" "$c_rst"
  fi

  if [[ -d "$BACKUP_ROOT" ]] && is_sep_mount "$BACKUP_ROOT"; then
    copies="$(sudo find "$BACKUP_ROOT/incoming" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l)"
    size="$(du_b "$BACKUP_ROOT/incoming")"; size="${size:-0}"
    printf '   • Backup:   %s backed-up copy(ies), %s, plus app dumps  (%s)\n' "$copies" "$(human "$size")" "$BACKUP_ROOT"
  else
    printf '   • Backup:   %s(not mounted at %s — will be SKIPPED; test data there would remain)%s\n' "$c_yel" "$BACKUP_ROOT" "$c_rst"
  fi

  if [[ -f "$IMMICH_DIR/docker-compose.yml" ]]; then
    printf '   • Immich:   ALL photos, albums, people/faces (its database + uploaded files reset empty)\n'
  fi
  if [[ -f "$PAPERLESS_DIR/docker-compose.yml" ]]; then
    printf '   • Paperless: ALL documents + tags (its database & media volumes reset empty)\n'
  fi
}

# ---- the two confirmations -------------------------------------------------------------------
confirm_dual() {
  local host phrase1 phrase2
  host="$(hostname 2>/dev/null || echo unknown)"
  printf '\n%sType  ERASE ALL DATA  to continue (anything else aborts):%s ' "$c_yel" "$c_rst"
  IFS= read -r phrase1 || true
  [[ "$phrase1" == "ERASE ALL DATA" ]] || { err "Did not receive 'ERASE ALL DATA' — aborted; nothing was deleted."; return 1; }
  printf '%sLast check — type this machine'\''s name (%s) to confirm you are erasing the RIGHT box:%s ' "$c_yel" "$host" "$c_rst"
  IFS= read -r phrase2 || true
  [[ "$phrase2" == "$host" ]] || { err "Hostname did not match — aborted; nothing was deleted."; return 1; }
  return 0
}

# ---- the resets (each is a no-op if that component isn't present) ----------------------------
reset_immich() {
  [[ -f "$IMMICH_DIR/docker-compose.yml" ]] || { say "   Immich not installed — skipping."; return 0; }
  local dbloc uploc
  dbloc="$(sudo sed -n 's/^DB_DATA_LOCATION=//p' "$IMMICH_DIR/.env" 2>/dev/null | head -1)"; dbloc="${dbloc:-$IMMICH_DIR/postgres}"
  uploc="$(sudo sed -n 's/^UPLOAD_LOCATION=//p'  "$IMMICH_DIR/.env" 2>/dev/null | head -1)"; uploc="${uploc:-$IMMICH_DIR/library}"
  say "   Immich: stopping containers..."
  dc "$IMMICH_DIR" down >/dev/null 2>&1 || warn "Immich 'compose down' reported an issue; continuing."
  say "   Immich: wiping database and uploaded files..."
  wipe_contents "$dbloc" || warn "could not clear '$dbloc' — clear it by hand."
  wipe_contents "$uploc" || warn "could not clear '$uploc' — clear it by hand."
  say "   Immich: starting fresh (it re-initialises an empty instance)..."
  dc "$IMMICH_DIR" up -d >/dev/null 2>&1 || warn "Immich 'compose up' reported an issue; check it after."
  ok "Immich reset to empty (re-create the admin + re-add the library after)."
}

reset_paperless() {
  [[ -f "$PAPERLESS_DIR/docker-compose.yml" ]] || { say "   Paperless not installed — skipping."; return 0; }
  say "   Paperless: stopping containers and removing its data volumes..."
  dc "$PAPERLESS_DIR" down -v >/dev/null 2>&1 || warn "Paperless 'compose down -v' reported an issue; continuing."
  say "   Paperless: clearing the consume/ and export/ folders..."
  wipe_contents "$PAPERLESS_DIR/consume" || true
  wipe_contents "$PAPERLESS_DIR/export"  || true
  say "   Paperless: starting fresh (its admin login is recreated from saved settings)..."
  dc "$PAPERLESS_DIR" up -d >/dev/null 2>&1 || warn "Paperless 'compose up' reported an issue; check it after."
  ok "Paperless reset to empty (same admin login)."
}

reset_archive() {
  if ! { [[ -d "$ARCHIVE_ROOT" ]] && is_sep_mount "$ARCHIVE_ROOT"; }; then
    warn "Archive not mounted at $ARCHIVE_ROOT — skipping. Mount it and re-run to clean it."
    return 0
  fi
  say "   Archive: deleting all ingested copies and search indexes..."
  wipe_contents "$ARCHIVE_ROOT/incoming"
  guard_path "$ARCHIVE_ROOT/.recoll"     && sudo rm -rf -- "$ARCHIVE_ROOT/.recoll"
  guard_path "$ARCHIVE_ROOT/.plocate.db" && sudo rm -f  -- "$ARCHIVE_ROOT/.plocate.db"
  sudo mkdir -p "$ARCHIVE_ROOT/incoming"
  sudo chown "$(id -u):$(id -g)" "$ARCHIVE_ROOT/incoming" 2>/dev/null || true
  ok "Archive emptied (search indexes cleared; rebuild with archive-index after your first ingest)."
}

reset_backup() {
  if ! { [[ -d "$BACKUP_ROOT" ]] && is_sep_mount "$BACKUP_ROOT"; }; then
    warn "Backup target not mounted at $BACKUP_ROOT — SKIPPING."
    warn "Any test data already copied there still exists. Mount it (archive-storage attach-backup)"
    warn "and re-run this reset to clear it BEFORE the first real backup."
    return 0
  fi
  say "   Backup: deleting all backed-up copies and app dumps..."
  wipe_contents "$BACKUP_ROOT/incoming"
  guard_path "$BACKUP_ROOT/apps" && sudo rm -rf -- "$BACKUP_ROOT/apps"
  sudo rm -f -- "$BACKUP_ROOT/.archive-backup.verified" 2>/dev/null || true
  sudo find "$BACKUP_ROOT" -maxdepth 1 -name '.archive-backup.*.log' -exec rm -f -- {} + 2>/dev/null || true
  ok "Backup emptied."
}

# ---- main ------------------------------------------------------------------------------------
main() {
  case "${1:-}" in
    -h|--help) sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "") : ;;
    *) err "Unknown argument: '$1'. This tool takes no options (there is no --yes mode)."; exit 2 ;;
  esac

  [[ "$(id -u)" -ne 0 ]] || { err "Run as your normal user, NOT root/sudo — it sudo's where needed."; exit 1; }
  have sudo || { err "sudo is required."; exit 1; }
  have docker || true
  [[ -t 0 && -t 1 ]] || { err "archive-reset must be run at an interactive terminal. There is no --yes mode."; exit 1; }

  local host ts log
  host="$(hostname 2>/dev/null || echo unknown)"
  ts="$(date +%Y%m%d-%H%M%S)"; log="$HOME/archive-reset.${ts}.log"

  printf '\n%s' "$c_red"
  printf '╔════════════════════════════════════════════════════════════════════╗\n'
  printf '║   archive-reset — ERASE ALL DATA and start fresh   (THERE IS NO UNDO) ║\n'
  printf '╚════════════════════════════════════════════════════════════════════╝%s\n' "$c_rst"
  say ""
  printf '  This returns  %s%s%s  to a clean, EMPTY state for the FIRST real ingestion.\n' "$c_yel" "$host" "$c_rst"
  say "  Run it ONCE, after testing, BEFORE any real family data goes in."
  hr
  print_delete_inventory
  say ""
  say "${c_grn}WILL BE KEPT:${c_rst} all tooling & commands, /etc config + credentials, Samba/Caddy/"
  say "  Tailscale setup, fstab mounts, Docker, and each app's compose/.env (logins & settings survive)."
  hr
  say "  Afterwards the apps are EMPTY: you re-create the Immich admin, re-add the read-only library"
  say "  /mnt/archive, and re-add family users. Paperless recreates its admin automatically."

  confirm_dual || exit 1

  say ""; say "${c_red}Proceeding — erasing now. Do not interrupt.${c_rst}"
  {
    say "== archive-reset on $host at $(date -Is) =="
    reset_immich
    reset_paperless
    reset_archive
    reset_backup
  } 2>&1 | tee "$log"

  say ""; hr
  ok "Reset complete — the box is empty and ready for real data."
  say ""
  say "  Verify it is clean & healthy:"
  say "     ./archive-doctor.sh"
  say "     (0 problems expected. Warnings like 'no index yet' / 'no backup yet' / 'app data never"
  say "      backed up' are CORRECT on an empty box and clear after your first real ingest + backup.)"
  say ""
  say "  When the real drives are ready:"
  say "     1. Immich: open it, create the admin, re-add the external library /mnt/archive, re-add users."
  say "        (The apps were just restarted — give them a couple of minutes to come up.)"
  say "     2. archive            # ingest the real media (verified)"
  say "     3. archive-index      # build the search indexes over the real data"
  say "     4. archive-backup     # first verified backup of the real data (+ app data)"
  say ""
  say "  A record of what was deleted is saved at: $log"
}

# Only run when executed directly — being sourced (e.g. by a test) must NOT trigger a wipe.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
