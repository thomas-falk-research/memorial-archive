#!/usr/bin/env bash
#
# openarchiver/inventory-mailboxes.sh — READ-ONLY census of every mailbox file in the archive:
# which are genuinely distinct, which are copies of each other, and which to import FIRST.
#
# Why this exists: the archive holds ~60 PST files across many backup generations. Most are copies
# of each other. Importing them blindly would re-OCR the same scanned attachments a dozen times and
# fill the app with duplicate mail, for days of CPU. This produces a deduplicated, prioritised
# worklist instead.
#
# HOW IT DEDUPES CHEAPLY: two files of different sizes cannot be identical, so a file whose size is
# unique needs no hashing at all. Only files whose size collides get SHA-256'd. On this corpus that
# is a fraction of the ~70 GB, so the run takes minutes rather than an hour.
#
# WRITES NOTHING to the archive. Sources are opened read-only; the report goes to $OUT (your home
# directory by default).
#
#   bash inventory-mailboxes.sh                # full census + prioritised worklist
#   bash inventory-mailboxes.sh --no-hash      # sizes only (instant, no dedup within size groups)
#   OUT=~/somewhere bash inventory-mailboxes.sh
#
set -uo pipefail

ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"
OUT="${OUT:-$HOME/openarchiver-inventory}"
DO_HASH=1
[ "${1:-}" = "--no-hash" ] && DO_HASH=0

c_b=$'\033[1m'; c_y=$'\033[1;33m'; c_c=$'\033[0;36m'; c_0=$'\033[0m'
say(){ printf '%s\n' "$*"; }
hdr(){ printf '\n%s== %s%s\n' "$c_b" "$*" "$c_0"; }
note(){ printf '    %s%s%s\n' "$c_c" "$*" "$c_0"; }
die(){ printf 'FATAL %s\n' "$*" >&2; exit 1; }

case "$OUT" in "$ARCHIVE_ROOT"|"$ARCHIVE_ROOT"/*) die "OUT must not be inside the archive.";; esac
mkdir -p "$OUT" || die "cannot create $OUT"
LIST="$OUT/mailboxes.tsv"

hdr "Finding mailbox files under $ARCHIVE_ROOT (read-only)"
tmp_paths="$(mktemp)"; trap 'rm -f "$tmp_paths"' EXIT
if command -v plocate >/dev/null 2>&1 && [ -r "$ARCHIVE_ROOT/.plocate.db" ]; then
  plocate -d "$ARCHIVE_ROOT/.plocate.db" -i -0 --regex '\.(pst|ost)$' 2>/dev/null >"$tmp_paths"
  note "source: plocate database"
else
  find "$ARCHIVE_ROOT" -type f \( -iname '*.pst' -o -iname '*.ost' \) -print0 2>/dev/null >"$tmp_paths"
  note "source: find (plocate db unreadable)"
fi

# size <TAB> path, existing files only
: >"$LIST.raw"
while IFS= read -r -d '' f; do
  [ -f "$f" ] || continue
  sz="$(stat -c %s "$f" 2>/dev/null)" || continue
  [ "${sz:-0}" -gt 0 ] && printf '%s\t%s\n' "$sz" "$f" >>"$LIST.raw"
done <"$tmp_paths"

total="$(wc -l <"$LIST.raw")"
[ "$total" -gt 0 ] || die "no .pst/.ost files found under $ARCHIVE_ROOT"
bytes="$(awk -F'\t' '{s+=$1} END{print s}' "$LIST.raw")"
note "$total mailbox files, $(awk -v b="$bytes" 'BEGIN{printf "%.1f GiB", b/1073741824}') total"

# ---- dedup: hash only within size-collision groups ---------------------------------------------
hdr "Identifying duplicates"
: >"$LIST"
if [ "$DO_HASH" = 1 ]; then
  # Precompute the set of sizes that appear more than once, so the loop is a cheap membership test
  # instead of rescanning the whole list per file.
  collide_file="$OUT/.collide"
  awk -F'\t' '{c[$1]++} END{for (s in c) if (c[s] > 1) print s}' "$LIST.raw" | sort -n >"$collide_file"
  n_groups="$(wc -l <"$collide_file")"
  n_collide="$(awk -F'\t' 'NR==FNR{c[$1]=1; next} ($1 in c)' "$collide_file" "$LIST.raw" | wc -l)"
  note "$n_collide file(s) share a size with another and will be hashed ($n_groups size groups)"
  note "files with a unique size cannot be duplicates — they are not hashed"
  i=0
  while IFS=$'\t' read -r sz f; do
    if grep -qxF "$sz" "$collide_file"; then
      i=$((i+1)); printf '\r    hashing %d/%d…' "$i" "$n_collide" >&2
      h="$(sha256sum "$f" 2>/dev/null | awk '{print $1}')"
      printf '%s\t%s\t%s\n' "$sz" "${h:-HASHFAIL}" "$f" >>"$LIST"
    else
      printf '%s\t%s\t%s\n' "$sz" "UNIQUE-SIZE" "$f" >>"$LIST"
    fi
  done <"$LIST.raw"
  printf '\r%*s\r' 44 '' >&2
  rm -f "$collide_file"
else
  awk -F'\t' '{print $1"\tNOT-HASHED\t"$2}' "$LIST.raw" >"$LIST"
fi

# ---- report -------------------------------------------------------------------------------------
hdr "Distinct mailboxes (one row per unique file; copies listed beneath)"
# One line per unique mailbox: size, copy-count, first path, then the other paths joined by "|".
# Embedding newlines inside a record would break the reader below — an earlier version did exactly
# that and mangled every multi-copy row.
awk -F'\t' '
  {
    key = ($2 == "UNIQUE-SIZE" || $2 == "NOT-HASHED") ? $1 "|" $3 : $2
    if (!(key in seen)) { seen[key] = $3; size[key] = $1; order[++n] = key }
    else copies[key] = copies[key] "|" $3
    cnt[key]++
  }
  END {
    ub = 0
    for (i = 1; i <= n; i++) { k = order[i]; ub += size[k]
      printf "%s\t%d\t%s\t%s\n", size[k], cnt[k], seen[k], copies[k] }
    printf "%d\t%.2f\n", n, ub/1073741824 > "/dev/stderr"
  }' "$LIST" 2>"$OUT/.totals" | sort -t$'\t' -k1,1nr | \
while IFS=$'\t' read -r sz cnt path dups; do
  h="$(numfmt --to=iec --suffix=B "$sz" 2>/dev/null || printf '%sB' "$sz")"
  if [ "${cnt:-1}" -gt 1 ]; then
    printf '  %9s  %s(%d copies)%s  %s\n' "$h" "$c_y" "$cnt" "$c_0" "$path"
    printf '%s\n' "$dups" | tr '|' '\n' | sed '/^$/d; s|^|               also: |'
  else
    printf '  %9s  %s\n' "$h" "$path"
  fi
done

uniq_n="$(awk -F'\t' '{print $1}' "$OUT/.totals")"
uniq_g="$(awk -F'\t' '{print $2}' "$OUT/.totals")"
hdr "Dedup result"
note "$total files  ->  ${uniq_n} distinct mailboxes"
note "$(awk -v b="$bytes" 'BEGIN{printf "%.1f", b/1073741824}') GiB  ->  ${uniq_g} GiB to import"
note "every duplicate skipped is a mailbox we never re-OCR"

# ---- prioritised worklist -------------------------------------------------------------------------
hdr "SUGGESTED IMPORT ORDER — for finding 2009 estate documents"
cat <<'WHY'
    Reasoning, so you can disagree with it:
      1. law      — the Northern Trust / "Ms. Ratliff" cover letter was written by Mary K. Hartigan
                    ESQ. Estate correspondence handled professionally lands in the practice mailbox.
      2. historical / archive — Outlook auto-archive moves OLD mail out of the main mailbox. For
                    2009 mail surviving into 2013-2020 backups, this is where it went.
      3. personal — the estate is also family; worth covering.
      4. main     — Outlook MKH / Outlook1: the live mailbox, most likely already pruned of 2009.
      5. carved   — file-carver output from the Hitachi. Unnamed, possibly truncated or corrupt,
                    and probably duplicates of the above. Last, and expect failures.
    Within each tier, smallest first: the first import is also our RAM and throughput measurement.
WHY
say ""
awk -F'\t' '
  {
    key = ($2 == "UNIQUE-SIZE" || $2 == "NOT-HASHED") ? $1 "|" $3 : $2
    if (key in seen) next
    seen[key] = 1
    p = tolower($3); base = $3; sub(/.*\//, "", base); lb = tolower(base)
    if (p ~ /carved-raw/ || lb ~ /^f[0-9]+\.pst$/)      { tier = 5; name = "carved" }
    else if (lb ~ /law/)                                { tier = 1; name = "law" }
    else if (lb ~ /historical/)                         { tier = 2; name = "historical" }
    else if (lb ~ /archive/)                            { tier = 2; name = "archive" }
    else if (lb ~ /personal/)                           { tier = 3; name = "personal" }
    else if (lb ~ /outlook/)                            { tier = 4; name = "main" }
    else                                                { tier = 4; name = "other" }
    printf "%d\t%012d\t%s\t%s\t%s\n", tier, $1, name, $1, $3
  }' "$LIST" | sort -t$'\t' -k1,1n -k2,2n | head -12 | \
while IFS=$'\t' read -r _tier _pad name sz path; do
  printf '  %-11s %8s  %s\n' "$name" "$(numfmt --to=iec --suffix=B "$sz" 2>/dev/null || echo "${sz}B")" "$path"
done

hdr "NEXT"
cat <<NEXT
  Stage the first one (dry-run shows what it would do, changes nothing):
      bash openarchiver/stage-mailbox.sh "<path from the list above>"
      bash openarchiver/stage-mailbox.sh "<path>" --go

  Import ONE first and watch it: that import is also the measurement of RAM, time and
  storage growth that tells us whether the rest is affordable.
      watch -n5 free -h
      cd /srv/apps/openarchiver && sudo docker compose logs -f open-archiver

  Then verify your staged copies were left alone:
      bash openarchiver/verify-openarchiver.sh staged

  Full data: $LIST
NEXT
rm -f "$OUT/.totals" "$LIST.raw"
exit 0
