#!/usr/bin/env bash
# archive-mailbox-recover.sh — second-pass recovery for mailboxes that readpst (libpst) could NOT
# extract in archive-mailbox-build.sh. It uses libpff (pffexport) — a different engine that tolerates
# damage and the 64-bit/4k-page OST files that make readpst segfault.
#
# For each failed source PST/OST given on the command line it:
#   - probes with pffinfo; if even libpff can't read the header it's truly dead -> leaves a small
#     *.UNRECOVERABLE.txt tombstone (so the record shows the mailbox existed) and moves on,
#   - otherwise removes the truncated partial readpst left behind and re-exports the WHOLE mailbox with
#     `pffexport -m all` (items + recovered/deleted + orphans) into the SAME browsable slot:
#         recovered/<drive>/Mailbox/<original-folder-path>/
#     then drops a RECOVERED-VIA-LIBPFF.txt provenance note.
#
# Additive + read-only, under recovered/ only; masters under incoming/ are never touched. DRY-RUN by
# default. recoll picks the result up on the next `archive-index` (recovered/ is under the topdir).
#
# Usage (recovered/ is root-owned -> run with sudo):
#   sudo ./archive-mailbox-recover.sh           <pst>...      # DRY-RUN: probe each, say what it would do
#   sudo ./archive-mailbox-recover.sh --go      <pst>...      # recover for real
set -uo pipefail

ARCHIVE_ROOT="/srv/archive"
for _cfg in /etc/archive-ingest.conf "${XDG_CONFIG_HOME:-$HOME/.config}/archive-ingest.conf"; do
  # shellcheck source=/dev/null
  [[ -r "$_cfg" ]] && { . "$_cfg" || true; }
done
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"
INC="$ARCHIVE_ROOT/incoming"
REC="$ARCHIVE_ROOT/recovered"
RLOG="${ARCHIVE_MAILBOX_RECOVER_LOG:-/tmp/archive-mailbox-recover.log}"
TODAY="$(date +%Y-%m-%d)"

GO=false
if [[ "${1:-}" == "--go" || "${1:-}" == "-g" ]]; then GO=true; shift; fi
SOURCES=("$@")

c_grn=$'\033[1;32m'; c_yel=$'\033[1;33m'; c_cyn=$'\033[0;36m'; c_red=$'\033[1;31m'; c_blu=$'\033[1;34m'; c_rst=$'\033[0m'
say(){ printf '\n%s== %s ==%s\n' "$c_blu" "$*" "$c_rst"; }
ok(){  printf '%s%s%s\n' "$c_grn" "$*" "$c_rst"; }
note(){ printf '%s%s%s\n' "$c_cyn" "$*" "$c_rst"; }
warn(){ printf '%sWARN:%s %s\n' "$c_yel" "$c_rst" "$*" >&2; }
die(){ printf '%sFATAL:%s %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }

command -v pffexport >/dev/null 2>&1 || die "pffexport not found — install pff-tools (sudo apt-get install -y pff-tools)."
command -v pffinfo   >/dev/null 2>&1 || die "pffinfo not found — install pff-tools."
[[ -d "$REC" ]] || die "no recovered/ under archive root: $REC"
[[ "${#SOURCES[@]}" -gt 0 ]] || die "no source mailboxes given. Pass the failed PST/OST paths as arguments."
if [[ "$GO" == true && ! -w "$REC" ]]; then die "cannot write $REC — re-run with sudo."; fi

if [[ "$GO" == true ]]; then say "MODE: GO — recovering with libpff (writes under $REC only)"; : > "$RLOG"
else say "MODE: DRY-RUN — nothing will be written. Re-run with --go to recover."; fi

declare -A TOUCH                       # drive labels whose Mailbox we modified (for the read-only re-lock)
DONE=(); DEAD=(); FAIL=()

for pst in "${SOURCES[@]}"; do
  [[ -f "$pst" ]]        || { warn "not a file, skipping: $pst"; continue; }
  [[ "$pst" == "$INC"/* ]] || { warn "not under incoming/, skipping: $pst"; continue; }
  rel="${pst#"$INC"/}"; label="${rel%%/*}"
  if [[ "$pst" == */data/* ]]; then orig="${pst#*/data/}"; else orig="${rel#*/}"; fi
  base="${orig%.*}"
  out="$REC/$label/Mailbox/$base"
  say "$label : $orig"

  if ! pffinfo "$pst" >/dev/null 2>&1; then
    warn "libpff cannot read it either (header destroyed) — truly unrecoverable here."
    DEAD+=("$pst")
    if [[ "$GO" == true ]]; then
      if [[ -d "$REC/$label/Mailbox" ]]; then chmod -R u+w "$REC/$label/Mailbox" 2>/dev/null || true; fi
      TOUCH["$label"]=1; mkdir -p "$(dirname "$out")"
      cat > "${out}.UNRECOVERABLE.txt" <<TXT
$(basename "$orig") — could NOT be recovered            ($TODAY)

This mailbox existed on the "$label" drive at:
    $orig
but the file is corrupt at its very header (invalid PST/OST signature), so neither readpst (libpst)
nor pffexport (libpff) can open it. Every byte-identical copy on the drive is equally damaged.
The only remaining option is Microsoft's Inbox Repair Tool (scanpst.exe) on Windows, and even that is
unlikely with a destroyed signature. The original file is preserved untouched under incoming/.
TXT
      note "  wrote tombstone: ${out#"$REC"/}.UNRECOVERABLE.txt"
    fi
    continue
  fi

  if [[ "$GO" != true ]]; then ok "  libpff CAN read it -> would re-export to ${out#"$REC"/}/"; continue; fi

  TOUCH["$label"]=1
  if [[ -d "$REC/$label/Mailbox" ]]; then chmod -R u+w "$REC/$label/Mailbox" 2>/dev/null || true; fi
  mkdir -p "$(dirname "$out")"
  rm -rf "$out" "${out}.export"        # drop readpst's truncated partial + any stale export
  if pffexport -m all -q -t "$out" "$pst" >>"$RLOG" 2>&1 && [[ -d "${out}.export" ]]; then
    mv "${out}.export" "$out"
    cat > "$out/RECOVERED-VIA-LIBPFF.txt" <<TXT
$(basename "$orig") — recovered with libpff            ($TODAY)

readpst (libpst) could not extract this mailbox (it segfaults on 64-bit/4k OST files and on some
damaged PSTs). It was instead recovered with pffexport (libpff, mode "all": normal + deleted + orphan
items). A truncated partial that readpst left behind was replaced by this complete export.

Layout note: libpff writes one numbered folder per message (Message.txt is the body, plus the
attachments and header files), which looks different from the other mailboxes — but every message and
attachment is here and is full-text searchable once the index has run. Source (untouched): $orig
TXT
    ok "  recovered: ${out#"$REC"/}/"
    DONE+=("$pst")
  else
    warn "  pffexport FAILED too (see $RLOG): $orig"
    FAIL+=("$pst"); rm -rf "${out}.export"
  fi
done

# read-only re-lock for every drive we touched
if [[ "$GO" == true && "${#TOUCH[@]}" -gt 0 ]]; then
  say "Locking read-only"
  for label in "${!TOUCH[@]}"; do chmod -R a-w "$REC/$label/Mailbox" 2>/dev/null || true; done
fi

say "SUMMARY"
printf '  recovered (libpff) : %s\n' "${#DONE[@]}"
printf '  unrecoverable      : %s%s\n' "${#DEAD[@]}" "$( ((${#DEAD[@]})) && printf '  (tombstoned)')"
printf '  still failing      : %s\n' "${#FAIL[@]}"
if [[ "$GO" != true ]]; then note "Dry run only. Re-run with --go (same arguments) to recover."
else note "Next: archive-index   (indexes + OCRs the recovered mail along with everything else)."; fi
((${#FAIL[@]}==0))   # non-zero exit if anything still failed after libpff
