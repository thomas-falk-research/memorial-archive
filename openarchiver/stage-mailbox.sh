#!/usr/bin/env bash
#
# openarchiver/stage-mailbox.sh — put a COPY of a real mailbox where Open Archiver can import it,
# and prove the master was never touched.
#
# Open Archiver's behaviour toward its source file is undocumented, and its import directory is
# mounted read-only precisely because we do not trust it with anything irreplaceable. This script is
# the only sanctioned way to get a real mailbox in front of it:
#
#   * the master is opened READ-ONLY and is never the thing handed to the app
#   * the master is checksummed BEFORE and AFTER the copy, and the run FAILS if it changed by a byte
#   * the copy is verified byte-for-byte against the master (sha256), not merely "cp said ok"
#   * free space is checked first, so a half-written copy is not the failure mode
#   * a provenance line is appended, so months from now the copy in import/ still says where it came
#     from and when
#   * it REFUSES to move, refuses to overwrite, and never deletes anything
#
# DRY-RUN by default. Add --go to actually copy.
#
#   bash stage-mailbox.sh "/srv/archive/incoming/.../Outlook MKH.pst"
#   bash stage-mailbox.sh "/srv/archive/incoming/.../Outlook MKH.pst" --go
#   bash stage-mailbox.sh --list          # what is currently staged
#
set -uo pipefail

APP_DIR="${OPENARCHIVER_DIR:-/srv/apps/openarchiver}"
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"
IMPORT_DIR="$APP_DIR/import"
MANIFEST="$IMPORT_DIR/PROVENANCE.tsv"
MIN_FREE_MULT="${MIN_FREE_MULT:-3}"     # need this many times the file size free, for headroom

c_b=$'\033[1m'; c_r=$'\033[1;31m'; c_g=$'\033[1;32m'; c_y=$'\033[1;33m'; c_0=$'\033[0m'
say(){ printf '%s\n' "$*"; }
hdr(){ printf '\n%s== %s%s\n' "$c_b" "$*" "$c_0"; }
ok(){ printf '  %sOK%s %s\n' "$c_g" "$c_0" "$*"; }
warn(){ printf '  %sWARN%s %s\n' "$c_y" "$c_0" "$*" >&2; }
die(){ printf '%sFATAL%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }

GO=0; SRC=""
for a in "$@"; do
  case "$a" in
    --go) GO=1 ;;
    --list)
      hdr "Staged in $IMPORT_DIR"
      find "$IMPORT_DIR" -maxdepth 1 -type f -printf '  %10s  %p\n' 2>/dev/null | sort -k2
      [ -f "$MANIFEST" ] && { say ""; say "  provenance:"; sed 's/^/    /' "$MANIFEST"; }
      exit 0 ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) SRC="$a" ;;
  esac
done
[ -n "$SRC" ] || die "usage: ${0##*/} <path-to-mailbox> [--go]   (or --list)"

[ -e "$SRC" ] || die "not found: $SRC"
[ -f "$SRC" ] || die "not a regular file: $SRC"
[ -r "$SRC" ] || die "not readable: $SRC"
[ -d "$APP_DIR" ] || die "Open Archiver is not installed at $APP_DIR"

base="$(basename "$SRC")"
dst="$IMPORT_DIR/$base"
size="$(stat -c %s "$SRC")"
size_h="$(du -h "$SRC" | cut -f1)"

hdr "Staging a COPY for import"
say "  master (read-only) : $SRC"
say "  size               : $size_h"
say "  copy destination   : $dst"

case "$SRC" in
  "$ARCHIVE_ROOT"/*) ok "source is inside the archive — it will be read, never written" ;;
  *) warn "source is OUTSIDE $ARCHIVE_ROOT — make sure this is the file you mean" ;;
esac

# Refuse to overwrite. Re-staging a name that already exists is how you silently import the wrong file.
[ -e "$dst" ] && die "already staged: $dst
    Remove it deliberately if you mean to replace it — this script will not overwrite."

# Space: the copy plus headroom, on the OS disk (the archive is not involved).
avail_kb="$(df -Pk "$IMPORT_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
need_kb=$(( size * MIN_FREE_MULT / 1024 ))   # multiply BEFORE dividing, or a small file rounds to 0
say "  free on target fs  : $(( avail_kb / 1024 )) MiB   (want >= $(( need_kb / 1024 )) MiB)"
[ "${avail_kb:-0}" -ge "$need_kb" ] || die "not enough free space on the target filesystem."

if [ "$GO" != 1 ]; then
  say ""
  say "  (dry-run — nothing copied. Add --go to stage it.)"
  exit 0
fi

hdr "Checksumming the master BEFORE the copy"
before="$(sha256sum "$SRC" | awk '{print $1}')" || die "could not read the master"
ok "$before"

hdr "Copying"
# --preserve=timestamps keeps the original mtime on the copy, which is real provenance, not decoration.
# No --remove-source-files, no mv, ever.
if ! cp --preserve=timestamps "$SRC" "$dst" 2>/dev/null; then
  sudo cp --preserve=timestamps "$SRC" "$dst" || die "copy failed"
  sudo chown "$(id -u):$(id -g)" "$dst" 2>/dev/null || true
fi
ok "copied"

hdr "Verifying"
after="$(sha256sum "$SRC" | awk '{print $1}')"
copy_sum="$(sha256sum "$dst" | awk '{print $1}')"

if [ "$after" != "$before" ]; then
  die "THE MASTER CHANGED DURING THE COPY.
    before: $before
    after : $after
    Something is writing to the archive. Stop and investigate before going further."
fi
ok "master is byte-identical before and after (never written to)"

if [ "$copy_sum" != "$before" ]; then
  rm -f "$dst" 2>/dev/null || sudo rm -f "$dst"
  die "the copy does not match the master — removed the bad copy.
    master: $before
    copy  : $copy_sum"
fi
ok "copy verified byte-for-byte against the master"
ok "  $copy_sum"

# Provenance: months from now, the copy in import/ must still be able to say where it came from.
if [ ! -f "$MANIFEST" ]; then
  printf 'staged_utc\tsha256\tbytes\tstaged_as\tmaster_path\n' >"$MANIFEST" 2>/dev/null \
    || sudo sh -c "printf 'staged_utc\tsha256\tbytes\tstaged_as\tmaster_path\n' > '$MANIFEST'"
fi
line="$(date -u +%Y-%m-%dT%H:%M:%SZ)	$copy_sum	$size	$base	$SRC"
printf '%s\n' "$line" >>"$MANIFEST" 2>/dev/null || sudo sh -c "printf '%s\n' '$line' >> '$MANIFEST'"
ok "provenance recorded in $MANIFEST"

hdr "NEXT"
cat <<NEXT
  1. Record the pre-import checksum so the source gate has a baseline to compare against:
       bash openarchiver/verify-openarchiver.sh source

  2. In the web UI: Ingestion sources -> add source
       type: PST (or Mbox / EML, matching the file)
       path: /import/$base

  3. After the import job finishes, prove the app left your copy alone:
       bash openarchiver/verify-openarchiver.sh source

  The master at
       $SRC
  was read only, and is byte-identical to before this ran. Nothing in the archive was modified.
NEXT
exit 0
