#!/usr/bin/env bash
#
# openarchiver/dedup-experiment.sh — does Open Archiver deduplicate messages ACROSS sources?
#
# This decides whether importing all 75 distinct PSTs is completeness or catastrophe. They are backup
# GENERATIONS of overlapping mailboxes, not 75 separate mailboxes:
#
#   * if it dedupes  -> import everything. Storage and time are far below what 61 GiB implies, and
#                       the family gets one clean copy of each message.
#   * if it doesn't  -> the family gets ~10 copies of every email, which is precisely the duplicate
#                       clutter that sent us looking for a document manager in the first place.
#
# The experiment uses two 63 MB archive mailboxes from different backup dates: different files
# (different SHA-256), near-certainly overlapping content.
#
# It measures from the DATABASE, not the dashboard, and it does not merely infer from row counts —
# it looks for the same message appearing twice, which is the thing we actually care about.
#
# Run the steps in order; each tells you what to do in the UI before the next.
#   bash dedup-experiment.sh step1     # stage A, record the baseline
#   ...import A in the UI...
#   bash dedup-experiment.sh step2     # record after-A, stage B
#   ...import B in the UI...
#   bash dedup-experiment.sh step3     # record after-B and give the verdict
#   bash dedup-experiment.sh reset     # forget the recorded state (does not touch the app)
#
# Reads the archive READ-ONLY (via stage-mailbox.sh). Writes only its own state file and the staged
# copies. Never deletes anything from the app.
#
set -uo pipefail

APP_DIR="${OPENARCHIVER_DIR:-/srv/apps/openarchiver}"
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"
STATE="${STATE:-$HOME/openarchiver-inventory/dedup-experiment.tsv}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PG="openarchiver-postgres"
PSQL_DB="${PSQL_DB:-open_archive}"
PSQL_USER="${PSQL_USER:-openarchiver}"

A="${A:-$ARCHIVE_ROOT/incoming/mary-ext-wd-160g/20260618-163133/data/July 10 2013/archive.pst}"
B="${B:-$ARCHIVE_ROOT/incoming/mary-ext-wd-160g/20260618-163133/data/Feb 14 2018/my outlook data/archive old.pst}"

c_b=$'\033[1m'; c_r=$'\033[1;31m'; c_g=$'\033[1;32m'; c_y=$'\033[1;33m'; c_0=$'\033[0m'
say(){ printf '%s\n' "$*"; }
hdr(){ printf '\n%s== %s%s\n' "$c_b" "$*" "$c_0"; }
ok(){ printf '  %sOK%s %s\n' "$c_g" "$c_0" "$*"; }
warn(){ printf '  %sWARN%s %s\n' "$c_y" "$c_0" "$*" >&2; }
die(){ printf '%sFATAL%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }

mkdir -p "$(dirname "$STATE")" 2>/dev/null

q(){ sudo docker exec "$PG" psql -U "$PSQL_USER" -d "$PSQL_DB" -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
alive(){ sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$PG"; }

# The schema is not documented, so discover the column that identifies a message rather than guessing.
id_col(){
  local c
  for c in message_id messageid message_id_header messageId; do
    if [ "$(q "select count(*) from information_schema.columns where table_name='archived_emails' and column_name='$c'")" = "1" ]; then
      printf '%s' "$c"; return 0
    fi
  done
  return 1
}
total(){ q "select count(*) from archived_emails"; }
record(){ printf '%s\t%s\t%s\n' "$1" "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$STATE"; }
get(){ awk -F'\t' -v k="$1" '$1==k{v=$2} END{print v}' "$STATE" 2>/dev/null; }

alive || die "$PG is not running — start the stack first."

# stage_or_accept <path> — stage a copy, or accept one that is already there IF it matches the
# master. Dying because a previous attempt already staged the file would strand the experiment
# halfway, and re-staging is not always possible (deletion may be disabled).
stage_or_accept(){
  local src="$1"; local dst
  dst="$APP_DIR/import/$(basename "$src")"
  if [ -e "$dst" ]; then
    local m c
    m="$(sha256sum "$src" 2>/dev/null | awk '{print $1}')"
    c="$(sha256sum "$dst" 2>/dev/null | awk '{print $1}')"
    if [ -n "$m" ] && [ "$m" = "$c" ]; then
      ok "already staged and byte-identical to the master — reusing it"
      return 0
    fi
    die "a DIFFERENT file is already staged as $(basename "$dst").
    staged: ${c:-unreadable}
    master: ${m:-unreadable}
    Resolve that before continuing — do not import a file you cannot account for."
  fi
  bash "$HERE/stage-mailbox.sh" "$src" --go
}

case "${1:-help}" in
# ------------------------------------------------------------------------------------------------
step1)
  hdr "STEP 1 — baseline, then stage mailbox A"
  base="$(total)"; [ -n "$base" ] || die "could not read a message count from the database."
  record baseline "$base"
  ok "messages currently archived: $base"
  ic="$(id_col || true)"
  if [ -n "$ic" ]; then ok "message-identity column: archived_emails.$ic"; record idcol "$ic"
  else warn "no message-id column found; step 3 will fall back to subject+date matching"; fi
  say ""
  stage_or_accept "$A" || die "staging A failed"
  record file_a "$(basename "$A")"
  hdr "NOW, IN THE UI"
  say "  Ingestion sources -> add source"
  say "    Provider      : PST Import"
  say "    Import method : Local Path"
  say "    Local path    : /import/$(basename "$A")"
  say "    Advanced options:"
  printf '      %sPreserve Original File  = CHECKED%s   (unchecked, it deletes your staged copy;\n' "$c_g" "$c_0"
  say "                                            the read-only mount would make that FAIL loudly)"
  printf '      %sMerge into existing     = UNCHECKED%s (we are testing whether a SEPARATE source\n' "$c_g" "$c_0"
  say "                                            deduplicates — that is the question for 75 sources)"
  say "  Wait for the job to FINISH, then run:   bash ${0##*/} step2"
  ;;
# ------------------------------------------------------------------------------------------------
step2)
  hdr "STEP 2 — record the effect of A, then stage mailbox B"
  base="$(get baseline)"; [ -n "$base" ] || die "no baseline recorded — run step1 first."
  after_a="$(total)"; [ -n "$after_a" ] || die "could not read the message count."
  record after_a "$after_a"
  ok "before A: $base    after A: $after_a    A contributed: $((after_a - base)) messages"
  [ "$((after_a - base))" -gt 0 ] || warn "A added nothing — did the import actually finish?"
  say ""
  stage_or_accept "$B" || die "staging B failed"
  record file_b "$(basename "$B")"
  hdr "NOW, IN THE UI"
  say "  Add a SECOND, separate source (do not merge it into the first):"
  say "    Provider      : PST Import"
  say "    Import method : Local Path"
  say "    Local path    : /import/$(basename "$B")"
  printf '      %sPreserve Original File  = CHECKED%s\n' "$c_g" "$c_0"
  printf '      %sMerge into existing     = UNCHECKED%s  <- important: merging would answer a\n' "$c_g" "$c_0"
  say "                                             different question than the one we are asking"
  say "  Wait for the job to FINISH, then run:   bash ${0##*/} step3"
  ;;
# ------------------------------------------------------------------------------------------------
step3)
  hdr "STEP 3 — the verdict"
  base="$(get baseline)"; after_a="$(get after_a)"; ic="$(get idcol)"
  [ -n "$after_a" ] || die "no after-A figure recorded — run step2 first."
  after_b="$(total)"; record after_b "$after_b"
  a_added=$((after_a - base)); b_added=$((after_b - after_a))
  say "  baseline        : $base"
  say "  after mailbox A : $after_a   (+$a_added)"
  say "  after mailbox B : $after_b   (+$b_added)"

  # The direct question: is any single message now present more than once?
  dupe_groups=""; worst=""
  if [ -n "$ic" ]; then
    dupe_groups="$(q "select count(*) from (select $ic from archived_emails where $ic is not null group by $ic having count(*)>1) t")"
    worst="$(q "select max(c) from (select count(*) c from archived_emails where $ic is not null group by $ic) t")"
  else
    dupe_groups="$(q "select count(*) from (select subject, sent_at from archived_emails group by subject, sent_at having count(*)>1) t")"
  fi
  say "  messages present more than once: ${dupe_groups:-unknown}${worst:+   (worst case: $worst copies)}"

  hdr "VERDICT"
  if [ -z "$dupe_groups" ]; then
    warn "could not run the duplicate query — decide from the counts above, carefully."
  elif [ "$dupe_groups" -eq 0 ]; then
    ok "DEDUPLICATES. No message appears twice after importing two overlapping mailboxes."
    say "  -> Importing all 75 distinct PSTs is safe for usability. Overlap collapses; the family"
    say "     sees one copy of each message. Storage and time will be well under the 61 GiB figure."
  elif [ "$b_added" -gt 0 ] && [ "$a_added" -gt 0 ] && [ "$((b_added * 100 / a_added))" -lt 25 ]; then
    ok "MOSTLY DEDUPLICATES. B added only $b_added messages against A's $a_added"
    say "  ...but $dupe_groups message(s) do appear more than once, so it is not perfect."
    say "  -> Importing everything is still reasonable; expect some duplicate results in the UI."
  else
    printf '  %sDOES NOT DEDUPLICATE.%s B added %s messages and %s message(s) now appear more than once.\n' \
      "$c_r" "$c_0" "$b_added" "$dupe_groups"
    say "  -> Do NOT import all 75. The family would get roughly ten copies of every email, which is"
    say "     the duplicate clutter this tool was meant to solve."
    say "  -> BEFORE giving up on completeness, re-test with \"Merge into existing ingestion\" CHECKED."
    say "     That option likely exists precisely for multiple generations of one mailbox, and may"
    say "     turn this answer around. Run:  bash ${0##*/} reset  then repeat with merge enabled."
    say "  -> If merging does not dedupe either, import ONE generation per mailbox lineage: the"
    say "     newest law / historical / archive / personal / main, keeping the rest as fallback."
  fi
  say ""
  say "  State: $STATE"
  say "  The staged copies are still in $APP_DIR/import — verify they were untouched with:"
  say "      bash openarchiver/verify-openarchiver.sh staged"
  ;;
# ------------------------------------------------------------------------------------------------
adopt-a)
  # A was imported before the experiment was wired up — adopt the current state as "after A" so the
  # run can continue. The duplicate-group query in step3 is the primary evidence and does not depend
  # on the baseline, so this loses only the a_added/b_added ratio.
  hdr "ADOPT — treat the current archive as the post-A state"
  cur="$(total)"; [ -n "$cur" ] || die "could not read the message count."
  ic="$(id_col || true)"
  : >"$STATE"
  record baseline 0
  record after_a "$cur"
  [ -n "$ic" ] && record idcol "$ic"
  ok "recorded after_a = $cur messages${ic:+, identity column $ic}"
  warn "baseline is unknown, so step3's A-vs-B ratio is not meaningful — the duplicate query is."
  say ""
  stage_or_accept "$B" || die "staging B failed"
  hdr "NOW, IN THE UI"
  say "  Add a SECOND, separate source:"
  say "    Provider: PST Import   ·   Import method: Local Path"
  say "    Local path: /import/$(basename "$B")"
  printf '      %sPreserve Original File  = CHECKED%s\n' "$c_g" "$c_0"
  printf '      %sMerge into existing     = UNCHECKED%s\n' "$c_g" "$c_0"
  say "  Wait for the job to FINISH, then run:   bash ${0##*/} step3"
  ;;
check)
  # Point-in-time reading. Use it around any import to see whether duplication grew — including the
  # "Merge into existing ingestion" test, which needs no deletion and no clean slate.
  hdr "CURRENT STATE"
  ic="$(get idcol)"; [ -n "$ic" ] || ic="$(id_col || true)"
  cur="$(total)"
  say "  messages archived: ${cur:-unknown}"
  if [ -n "$ic" ]; then
    dg="$(q "select count(*) from (select $ic from archived_emails where $ic is not null group by $ic having count(*)>1) t")"
    wc_="$(q "select max(c) from (select count(*) c from archived_emails where $ic is not null group by $ic) t")"
    dr="$(q "select count(*)-count(distinct $ic) from archived_emails where $ic is not null")"
    say "  distinct messages present more than once: ${dg:-?}   (worst case: ${wc_:-?} copies)"
    say "  redundant rows (stored copies beyond the first): ${dr:-?}"
  fi
  say ""
  say "  To test whether MERGE deduplicates — no deletion or clean slate needed:"
  say "    1. note the numbers above"
  say "    2. import a mailbox you have ALREADY imported, this time with"
  say "       \"Merge into existing ingestion\" CHECKED, targeting the source that holds it"
  say "    3. run this again."
  say "  If the count barely moves, merge deduplicates. If it jumps by the mailbox's full message"
  say "  count, it does not, and duplication is simply the price of completeness."
  ;;
reset) : >"$STATE"; ok "cleared $STATE (the app and its data were not touched)" ;;
*)
  say "Usage: ${0##*/} [step1|step2|adopt-a|step3|check|reset]"
  say ""
  say "  adopt-a: use when mailbox A was already imported outside this flow (creating an"
  say "           ingestion source starts the import immediately)."
  say ""
  say "  Decides whether importing all 75 distinct PSTs gives completeness or ten copies of"
  say "  every email. Uses two 63 MB archive mailboxes from different backup dates."
  say "  A: $A"
  say "  B: $B"
  ;;
esac
