#!/usr/bin/env bash
# ci/backup-roundtrip.sh — prove the plain rsync mirror (archive-backup) is faithful and verified.
#
# The restic drill covers the encrypted snapshots; this covers the other backup path — the browsable,
# tool-free mirror `archive-backup` writes to /srv/backup. It drives the REAL archive-backup wrapper
# (extracted from archive-storage-setup.sh) against a scratch archive + backup dir, with the app-data
# step off (BACKUP_APPS=false — that part needs Docker), and asserts the guarantees the family relies
# on:
#
#   1. a backup mirrors the archive, re-verifies every SHA256SUMS at the destination, writes its marker;
#   2. the mirror is byte-identical to the source, and the rebuildable index (.recoll) is excluded;
#   3. it is ADDITIVE — a file later removed from the source is retained in the backup;
#   4. the verification has TEETH — a silently corrupted backup copy fails and is NOT marked verified.
#
# Needs only rsync + sha256sum (both standard), no Docker and no sudo, scratch dir only — so it runs
# in the static CI job and via ./ci/run.sh. Driving the real wrapper means a regression in our backup
# logic (the excludes, the destination verify, the additive guarantee, the marker) fails here.
set -uo pipefail
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$(repo_root)" || exit 1

for t in rsync sha256sum; do
  command -v "$t" >/dev/null 2>&1 || { warn "$t not installed — skipping the rsync backup/restore drill."; exit 0; }
done

fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

extract_embedded_commands "$WORK/cmds"
BK="$WORK/cmds/archive-storage-setup.sh__archive-backup.sh"
[[ -s "$BK" ]] || { bad "could not extract the archive-backup wrapper from archive-storage-setup.sh"; exit 1; }

# Scratch archive with one verified copy (BagIt-ish: data/ + a real SHA256SUMS) + a rebuildable index
# dir that MUST be excluded; a separate scratch backup dir.
A="$WORK/archive"; B="$WORK/backup"; COPY="$A/incoming/selftest/20260101"; D="$COPY/data"
mkdir -p "$D/nested" "$A/.recoll" "$B" "$WORK/xdg"
printf 'original-A\n'        > "$D/a.txt"
printf 'has spaces\n'        > "$D/with spaces.txt"
printf 'unicode\n'           > "$D/café-ünïcode-名前.txt"
: > "$D/empty.bin"
head -c 65536 /dev/urandom   > "$D/blob.bin"
printf 'leaf\n'              > "$D/nested/leaf.txt"
printf 'provenance\n'        > "$COPY/PROVENANCE.txt"
printf 'rebuildable index\n' > "$A/.recoll/xapiandb"
( cd "$COPY" && find data -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > SHA256SUMS )

# Put the scratch settings in the XDG config, NOT just the environment. The command body sources
# /etc/archive-ingest.conf and THEN the XDG one, and those plain assignments override exported env
# vars — so on a box where the tools are installed, an /etc config would otherwise hijack
# ARCHIVE_ROOT/BACKUP_ROOT and the drill could run against real paths. The XDG file is sourced LAST,
# so it wins (the same isolation archive-selftest.sh uses).
cat > "$WORK/xdg/archive-ingest.conf" <<CONF
ARCHIVE_ROOT=$A
BACKUP_ROOT=$B
REQUIRE_SEPARATE_BACKUP=false
BACKUP_APPS=false
MIN_FREE_GIB=0
CONF
bk() { XDG_CONFIG_HOME="$WORK/xdg" bash "$BK"; }  # archive-backup takes no subcommand

hdr "1. backup + verify (archive-backup)"
if bk >"$WORK/b1.log" 2>&1 && [[ -f "$B/.archive-backup.verified" ]]; then
  ok "archive mirrored, every manifest re-verified at the destination, verified-marker written"
else
  bad "archive-backup did not complete and verify"; sed 's/^/      /' "$WORK/b1.log"; fails=1
fi

hdr "2. mirror is byte-identical; rebuildable index excluded"
if diff -r "$A/incoming" "$B/incoming" >/dev/null 2>&1; then
  ok "backup incoming/ is byte-identical to the source (a tool-free, browsable restore)"
else
  bad "backup differs from the source"; fails=1
fi
if [[ -e "$B/.recoll" ]]; then
  bad ".recoll index was NOT excluded — backups would carry rebuildable cruft"; fails=1
else
  ok "rebuildable index (.recoll) correctly excluded from the mirror"
fi

hdr "3. additive — a file removed from the source is retained in the backup"
rm -f "$D/with spaces.txt"   # source loses a file (accidental delete / ransomware on the live disk)
if bk >/dev/null 2>&1 && [[ -f "$B/incoming/selftest/20260101/data/with spaces.txt" ]]; then
  ok "the backup kept the file the source lost (additive — it never deletes)"
else
  bad "the backup dropped a file that was removed from the source"; fails=1
fi

hdr "4. verification has teeth — a silently corrupted backup copy is caught"
victim="$B/incoming/selftest/20260101/data/a.txt"; src="$D/a.txt"
printf 'X' | dd of="$victim" bs=1 seek=0 conv=notrunc status=none 2>/dev/null  # flip a byte, same size
touch -r "$src" "$victim"                                                       # match mtime so rsync skips it
if bk >/dev/null 2>&1 || [[ -f "$B/.archive-backup.verified" ]]; then
  bad "a corrupted backup copy was NOT caught — the backup would be wrongly blessed"; fails=1
else
  ok "a corrupted backup copy fails the manifest check and is NOT marked verified"
fi

hdr "Summary"
if (( fails )); then bad "rsync backup/restore drill FAILED — see above."; else ok "rsync backup/restore drill passed."; fi
exit "$fails"
