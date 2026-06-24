#!/usr/bin/env bash
# archive-mailbox-build.sh — give EVERY ingested drive the same browsable mailbox treatment that the
# 1 TB Hitachi got by hand, so a non-technical family member can traverse each drive's Outlook email
# (Inbox / Sent / the folders she filed things into) and open every attachment as a normal file.
#
# For each drive under <archive>/incoming it:
#   1. finds every Outlook PST/OST,
#   2. de-duplicates byte-identical copies (backup folders repeat the same mailbox many times),
#   3. explodes each UNIQUE mailbox into loose files with `readpst -S` (one file per message AND per
#      attachment) at:   <archive>/recovered/<drive>/Mailbox/<original-folder-path>/
#
# recoll indexes this automatically (recovered/ sits under the archive root and is NOT skipped), so the
# same mail becomes full-text searchable and OCR'd on the next `archive-index` — no --attachments needed,
# because the loose attachments now live in the browsable tree instead of the hidden .derived sidecar.
#
# It only ADDS a derived, read-only view under recovered/; it never touches the verified masters under
# incoming/. Safe to re-run (incremental). DEFAULTS TO DRY-RUN — it writes nothing until you pass --go.
#
# Usage (recovered/ is root-owned, so run with sudo):
#   sudo ./archive-mailbox-build.sh           # DRY-RUN: list every drive, every mailbox, sizes + space plan
#   sudo ./archive-mailbox-build.sh --go      # actually extract
#
# Reads ARCHIVE_ROOT from /etc/archive-ingest.conf (default /srv/archive), same as archive-index.
set -uo pipefail

# ---- config -----------------------------------------------------------------------------------------
ARCHIVE_ROOT="/srv/archive"
for _cfg in /etc/archive-ingest.conf "${XDG_CONFIG_HOME:-$HOME/.config}/archive-ingest.conf"; do
  # shellcheck source=/dev/null
  [[ -r "$_cfg" ]] && { . "$_cfg" || true; }
done
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"
INC="$ARCHIVE_ROOT/incoming"
REC="$ARCHIVE_ROOT/recovered"
LOG="${ARCHIVE_MAILBOX_LOG:-/tmp/archive-mailbox-build.log}"
TODAY="$(date +%Y-%m-%d)"
GO=false
case "${1:-}" in --go|-g) GO=true ;; --dry-run|"") GO=false ;; *) printf 'unknown arg: %s (use --go or nothing for dry-run)\n' "$1" >&2; exit 2 ;; esac

c_grn=$'\033[1;32m'; c_yel=$'\033[1;33m'; c_cyn=$'\033[0;36m'; c_red=$'\033[1;31m'; c_blu=$'\033[1;34m'; c_rst=$'\033[0m'
say(){ printf '\n%s== %s ==%s\n' "$c_blu" "$*" "$c_rst"; }
ok(){  printf '%s%s%s\n' "$c_grn" "$*" "$c_rst"; }
note(){ printf '%s%s%s\n' "$c_cyn" "$*" "$c_rst"; }
warn(){ printf '%sWARN:%s %s\n' "$c_yel" "$c_rst" "$*" >&2; }
die(){ printf '%sFATAL:%s %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }
human(){ numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"; }

command -v readpst  >/dev/null 2>&1 || die "readpst not found (install libpst / run archive-search-setup.sh)."
command -v md5sum   >/dev/null 2>&1 || die "md5sum not found."
[[ -d "$INC" ]] || die "no incoming/ under archive root: $INC"
[[ -d "$REC" ]] || die "no recovered/ under archive root: $REC"
if [[ "$GO" == true && ! -w "$REC" ]]; then die "cannot write $REC — re-run with sudo."; fi

if [[ "$GO" == true ]]; then say "MODE: GO — will extract (writes under $REC only)"; : > "$LOG"
else say "MODE: DRY-RUN — nothing will be written. Re-run with --go to extract."; fi
note "Archive root : $ARCHIVE_ROOT"
note "Reads from   : $INC   (masters, untouched)"
note "Writes to    : $REC/<drive>/Mailbox/   (derived, read-only)"

# ---- pass 1: discover, de-duplicate, build the worklist ---------------------------------------------
declare -A SEEN          # "label|md5" -> first source path (kept copy)
declare -A U_CNT D_CNT   # per-drive unique / duplicate counts
declare -A U_BYTES       # per-drive unique bytes
WORK="$(mktemp)"; DUPS="$(mktemp)"; trap 'rm -f "$WORK" "$DUPS"' EXIT
TOT_UNIQ=0; TOT_DUP=0; TOT_BYTES=0; N_DRIVES=0

mapfile -d '' DRIVE_DIRS < <(find "$INC" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
[[ "${#DRIVE_DIRS[@]}" -gt 0 ]] || die "no drives found under $INC"

for drive in "${DRIVE_DIRS[@]}"; do
  label="$(basename "$drive")"
  N_DRIVES=$((N_DRIVES+1))
  say "drive: $label"
  found=0
  while IFS= read -r -d '' pst; do
    found=$((found+1))
    after="${pst#"$drive"/}"
    if [[ "$after" == */data/* ]]; then orig="${after#*/data/}"; else orig="$after"; fi   # strip <timestamp>/data/
    base="${orig%.*}"                                                                       # drop .pst/.ost
    out="$REC/$label/Mailbox/$base"
    md5="$(md5sum -- "$pst" | awk '{print $1}')"
    sz="$(stat -c %s -- "$pst" 2>/dev/null || echo 0)"
    key="$label|$md5"
    if [[ -n "${SEEN[$key]:-}" ]]; then
      D_CNT[$label]=$(( ${D_CNT[$label]:-0} + 1 )); TOT_DUP=$((TOT_DUP+1))
      printf '%s\tIS A BYTE-FOR-BYTE COPY OF\t%s\n' "$pst" "${SEEN[$key]}" >> "$DUPS"
      printf '   %sdup%s  %-10s %s\n' "$c_yel" "$c_rst" "$(human "$sz")" "$orig"
      continue
    fi
    SEEN[$key]="$pst"
    U_CNT[$label]=$(( ${U_CNT[$label]:-0} + 1 )); TOT_UNIQ=$((TOT_UNIQ+1))
    U_BYTES[$label]=$(( ${U_BYTES[$label]:-0} + sz )); TOT_BYTES=$((TOT_BYTES+sz))
    printf '   %suniq%s %-10s %s\n' "$c_grn" "$c_rst" "$(human "$sz")" "$orig"
    printf '%s\t%s\t%s\n' "$pst" "$out" "$label" >> "$WORK"
  done < <(find "$drive" -type f \( -iname '*.pst' -o -iname '*.ost' \) -print0 2>/dev/null | sort -z)
  [[ "$found" -eq 0 ]] && note "   (no PST/OST on this drive)"
  printf '   -> %s unique, %s duplicate, %s to extract\n' "${U_CNT[$label]:-0}" "${D_CNT[$label]:-0}" "$(human "${U_BYTES[$label]:-0}")"
done

# ---- space plan -------------------------------------------------------------------------------------
need_b=$(( TOT_BYTES * 16 / 10 ))                                  # readpst -S expands a bit; budget x1.6
free_b=$(( $(df -Pk "$REC" | awk 'NR==2{print $4}') * 1024 ))
say "PLAN"
printf '  drives scanned     : %s\n' "$N_DRIVES"
printf '  mailboxes (unique) : %s   (%s after de-dup, %s duplicate copies skipped)\n' "$TOT_UNIQ" "$(human "$TOT_BYTES")" "$TOT_DUP"
printf '  est. space needed  : ~%s  (unique PST size x1.6)\n' "$(human "$need_b")"
printf '  free on recovered/ : %s\n' "$(human "$free_b")"

if [[ "$TOT_UNIQ" -eq 0 ]]; then ok "No mailboxes to extract. Done."; exit 0; fi

if [[ "$GO" != true ]]; then
  say "DRY-RUN COMPLETE"
  note "Review the per-drive lists above. To extract, re-run:   sudo $0 --go"
  note "Then make it searchable + OCR'd:                         sudo -u <archive-user> archive-index"
  exit 0
fi

[[ "$free_b" -ge "$need_b" ]] || die "not enough free space (need ~$(human "$need_b"), have $(human "$free_b"))."

# ---- pass 2: extract (GO only) ----------------------------------------------------------------------
say "EXTRACTING ($TOT_UNIQ mailboxes) — log: $LOG"
declare -A TOUCHED       # labels we wrote to (for provenance + read-only lock)
FAILS=()
while IFS=$'\t' read -r pst out label; do
  TOUCHED[$label]=1
  # unlock if a prior run locked this drive's Mailbox read-only
  if [[ -d "$REC/$label/Mailbox" ]]; then chmod -R u+w "$REC/$label/Mailbox" 2>/dev/null || true; fi
  if [[ -d "$out" && "$out" -nt "$pst" ]]; then note "  up-to-date: ${out#"$REC"/}"; continue; fi
  mkdir -p "$out"
  if readpst -S -o "$out" "$pst" >>"$LOG" 2>&1; then ok "  extracted : ${out#"$REC"/}"
  else warn "  readpst FAILED (kept in failure list): $pst"; FAILS+=("$pst"); rmdir "$out" 2>/dev/null || true; fi
done < "$WORK"

# ---- provenance + read-only lock --------------------------------------------------------------------
say "Writing provenance + locking read-only"
for label in "${!TOUCHED[@]}"; do
  mboot="$REC/$label/Mailbox"
  [[ -d "$mboot" ]] || continue
  cat > "$mboot/README.txt" <<TXT
$label — recovered Outlook email

These are the email mailboxes recovered from the "$label" drive, exploded so you can
browse them like normal folders. Open any folder (Inbox, Sent, Deleted Items, and the
folders she filed things into); each email and each attachment is a separate file you
can open, search, and print. Everything here is read-only.

Recovered $TODAY. See PROVENANCE.txt for exactly where this came from and how it was made.
TXT
  cat > "$mboot/PROVENANCE.txt" <<TXT
PROVENANCE — $label / Mailbox            (built $TODAY)

Source     : every Outlook PST/OST found under $INC/$label
Method     : readpst -S (each message AND attachment written as a separate, browsable file)
De-dup     : byte-identical mailboxes (md5) appear in many backup folders; each unique
             mailbox was extracted once. See DUPLICATES.txt for the copies that were skipped
             (nothing was lost — they were exact copies of a mailbox that IS here).
Note       : this is a derived, read-only VIEW. The verified master files remain untouched
             under $INC/$label. The same mail is also full-text searchable (and scanned
             attachments OCR'd) through the archive search once 'archive-index' has run.
TXT
  # per-drive duplicate + failure manifests (provenance: account for every copy)
  awk -F'\t' -v d="$INC/$label/" '$1 ~ d' "$DUPS" > "$mboot/DUPLICATES.txt" 2>/dev/null || true
  [[ -s "$mboot/DUPLICATES.txt" ]] || rm -f "$mboot/DUPLICATES.txt"
  chmod -R a-w "$mboot" 2>/dev/null || true
done

if [[ "${#FAILS[@]}" -gt 0 ]]; then
  warn "${#FAILS[@]} mailbox(es) could not be extracted (likely corrupt PST/OST). Listed below and in $LOG:"
  printf '   %s\n' "${FAILS[@]}"
fi

say "DONE"
ok "Built browsable Mailbox/ for ${#TOUCHED[@]} drive(s) under $REC/"
note "Next — make it searchable + OCR'd (indexes recovered/ automatically):"
note "    archive-index            # run as your normal archive user, in tmux (long: OCR over all attachments)"
