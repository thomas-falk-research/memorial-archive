#!/usr/bin/env bash
# ci/restic-roundtrip.sh — prove the encrypted backup can actually be RESTORED.
#
# "A backup you can't restore is worthless." There's no Docker or real off-site target in CI, but the
# restic path is fully exercisable: this drives the ACTUAL `archive-restic` wrapper (extracted from
# archive-restic-setup.sh, the same way the shellcheck pass does) end to end against a scratch archive
# and repository, and asserts the guarantees the family's recovery depends on:
#
#   1. backup initialises the repo, snapshots with the project's excludes, verifies, writes its marker;
#   2. a restore brings the data back byte-for-byte, and the rebuildable index (.recoll) is excluded;
#   3. an OLDER snapshot still holds the original after a later edit (point-in-time recovery);
#   4. a damaged repository is caught loudly by `restic check` (silent rot is the nightmare).
#
# Driving the real wrapper means a regression in our backup logic fails here. Needs the `restic`
# binary (CI installs it; locally it self-skips if absent). Runs as any user — the backup/restore/
# check path never uses sudo — and touches only a mktemp scratch dir.
set -uo pipefail
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$(repo_root)" || exit 1

if ! command -v restic >/dev/null 2>&1; then
  warn "restic not installed — skipping the backup/restore drill (CI installs it; locally: apt install restic)."
  exit 0
fi
printf 'using %s\n' "$(restic version 2>/dev/null | head -1)"

fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Extract the real installed-command body so we test our wrapper, not a reimplementation.
extract_embedded_commands "$WORK/cmds"
WR="$WORK/cmds/archive-restic-setup.sh__archive-restic.sh"
[[ -s "$WR" ]] || { bad "could not extract the archive-restic wrapper from archive-restic-setup.sh"; exit 1; }

# Scratch archive (incoming/ layout) with deliberately awkward files + a rebuildable index dir that
# MUST be excluded; a separate scratch backup dir; a throwaway passphrase.
A="$WORK/archive"; B="$WORK/backup"; D="$A/incoming/selftest/20260101/data"
mkdir -p "$D/nested" "$A/.recoll" "$B" "$WORK/xdg"
printf 'original-A\n'        > "$D/a.txt"
printf 'has spaces\n'        > "$D/with spaces.txt"
printf 'unicode\n'           > "$D/café-ünïcode-名前.txt"
printf 'decoy manifest\n'    > "$D/SHA256SUMS"          # a SOURCE file named like our metadata
: > "$D/empty.bin"                                       # zero-byte file
head -c 65536 /dev/urandom   > "$D/blob.bin"            # binary
printf 'leaf\n'              > "$D/nested/leaf.txt"
printf 'rebuildable index\n' > "$A/.recoll/xapiandb"    # must NOT be in the backup
printf 'scratch-passphrase-%s\n' "$RANDOM$RANDOM$$" > "$WORK/pass"; chmod 600 "$WORK/pass"

# Drive the wrapper with everything pointed at scratch (no sudo, no real config touched). The scratch
# settings go in the XDG config (sourced LAST by the command body), NOT just the environment: an
# installed /etc/archive-ingest.conf is sourced first and its plain assignments would otherwise
# override exported env vars — hijacking ARCHIVE_ROOT/BACKUP_ROOT so the drill ran against real paths.
cat > "$WORK/xdg/archive-ingest.conf" <<CONF
ARCHIVE_ROOT=$A
BACKUP_ROOT=$B
RESTIC_REPO=$B/restic
RESTIC_PASSWORD_FILE=$WORK/pass
REQUIRE_SEPARATE_BACKUP=false
MIN_FREE_GIB=0
CONF
wr() { XDG_CONFIG_HOME="$WORK/xdg" bash "$WR" "$@"; }

hdr "1. backup + verify (archive-restic backup)"
if wr backup >"$WORK/b1.log" 2>&1 && [[ -f "$B/.archive-restic.verified" ]]; then
  ok "first snapshot created, verified by restic check, and the verified-marker written"
else
  bad "archive-restic backup did not complete and verify"; sed 's/^/      /' "$WORK/b1.log"; fails=1
fi
# Capture the (only) snapshot id now, for the point-in-time test below.
first_id="$(wr snapshots --json 2>/dev/null | grep -oE '"short_id":"[0-9a-f]+"' | head -1 | sed -E 's/.*:"([0-9a-f]+)".*/\1/')"

hdr "2. restore latest — data returns byte-identical, rebuildable index excluded"
if wr restore latest --target "$WORK/r_latest" >/dev/null 2>&1; then
  if diff -r "$A/incoming" "$WORK/r_latest$A/incoming" >/dev/null 2>&1; then
    ok "restored incoming/ is byte-identical to the source"
  else
    bad "restored data differs from the source"; fails=1
  fi
  if [[ -e "$WORK/r_latest$A/.recoll" ]]; then
    bad ".recoll index was NOT excluded — backups would carry rebuildable cruft"; fails=1
  else
    ok "rebuildable index (.recoll) correctly excluded from the snapshot"
  fi
else
  bad "restore latest failed"; fails=1
fi

hdr "3. point-in-time recovery — an older snapshot still has the original"
printf 'MODIFIED-A\n' > "$D/a.txt"
if wr backup >/dev/null 2>&1 && [[ -n "$first_id" ]] \
   && wr restore "$first_id" --target "$WORK/r_first" >/dev/null 2>&1; then
  if [[ "$(cat "$WORK/r_first$A/incoming/selftest/20260101/data/a.txt" 2>/dev/null)" == "original-A" ]]; then
    ok "restoring the first snapshot returns the ORIGINAL file (recovery from a later edit/ransomware)"
  else
    bad "point-in-time restore did not return the original content"; fails=1
  fi
else
  bad "could not take a second snapshot and restore the first (id='${first_id:-}')"; fails=1
fi

hdr "4. corruption is caught (restic check fails on a damaged repo)"
pack="$(find "$B/restic/data" -type f 2>/dev/null | head -1)"
if [[ -n "$pack" ]]; then
  # Delete a referenced pack to simulate loss/on-disk damage. (restic writes packs read-only, so
  # truncating one fails as a normal user; rm needs only directory write, so it works as any user —
  # and a missing pack is exactly what a plain `restic check` is built to catch.)
  rm -f "$pack"
  if wr check >/dev/null 2>&1; then
    bad "restic check PASSED on a corrupted repo — corruption would go unnoticed"; fails=1
  else
    ok "restic check fails loudly on a damaged repository"
  fi
else
  bad "no pack file found to corrupt — repo layout unexpected"; fails=1
fi

hdr "Summary"
if (( fails )); then bad "restic backup/restore drill FAILED — see above."; else ok "restic backup/restore drill passed."; fi
exit "$fails"
