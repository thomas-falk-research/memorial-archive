#!/usr/bin/env bash
# rag-pilot/run.sh — Phase-1 RAG pilot orchestrator: Docling -> BGE-M3 -> Milvus Lite, over a SMALL
# scanned-PDF subset, to MEASURE feasibility on this box. See README.md for the full safety rationale.
#
# Strictly additive & reversible:
#   * everything lives under $RAG_HOME on the NVMe (never the archive HDD / /srv/archive)
#   * sources are read ONLY; nothing is ever written under the archive
#   * the recoll/Xapian index is never opened, locked, or touched
#   * one heavy model loads at a time (parse and embed are separate processes)
#   * a memory floor aborts a stage rather than risk swapping the family services
#   * Docling runs per-file under an OS-level `timeout` (its own document_timeout is broken)
#   * `teardown --go` removes the whole pilot in one command
# Mutating subcommands DRY-RUN by default; add --go to actually act.
set -uo pipefail

RAG_HOME="${RAG_HOME:-/home/tom/rag-pilot}"
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"
DOC_TIMEOUT="${DOC_TIMEOUT:-180}"      # OS-level wall-clock kill per PDF
MIN_FREE_MIB="${MIN_FREE_MIB:-3072}"   # refuse to start a heavy stage below this MemAvailable
SUBSET_MAX="${SUBSET_MAX:-200}"

HERE="$(cd "$(dirname "$0")" && pwd)"
VENV="$RAG_HOME/venv"; PY="$VENV/bin/python"; PIP="$VENV/bin/pip"
MODELS="$RAG_HOME/models"; PARSED="$RAG_HOME/parsed"; LOGS="$RAG_HOME/logs"
DB="$RAG_HOME/milvus.db"; LIST="$RAG_HOME/input-list.txt"; QUAR="$RAG_HOME/quarantine.log"

c_b=$'\033[1m'; c_r=$'\033[1;31m'; c_g=$'\033[1;32m'; c_0=$'\033[0m'
say(){ printf '%s\n' "$*"; }
ok(){ printf '%sOK%s %s\n' "$c_g" "$c_0" "$*"; }
err(){ printf '%sERROR%s %s\n' "$c_r" "$c_0" "$*" >&2; }
die(){ err "$*"; exit 1; }

assert_safe_home(){
  case "$RAG_HOME" in
    "$ARCHIVE_ROOT"|"$ARCHIVE_ROOT"/*) die "RAG_HOME ($RAG_HOME) must NOT be under the archive ($ARCHIVE_ROOT).";;
  esac
}
guard_mem(){
  local avail; avail="$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
  say "MemAvailable: ${avail:-?} MiB  (floor ${MIN_FREE_MIB} MiB)"
  [ "${avail:-0}" -ge "$MIN_FREE_MIB" ] || die "Too little free RAM to start safely — not risking the family services."
}

# ---- parse args: pull out --go, keep the rest ------------------------------------------------
GO=0; ARGS=()
for a in "$@"; do
  if [ "$a" = "--go" ]; then GO=1; else ARGS+=("$a"); fi
done
cmd="${ARGS[0]:-help}"
REST=("${ARGS[@]:1}")

case "$cmd" in
  setup)
    assert_safe_home
    say "${c_b}=== setup: venv + CPU-only deps under $RAG_HOME ===${c_0}"
    say "venv   : $VENV"
    say "models : $MODELS   (HF cache contained here; removed on teardown)"
    say "torch  : CPU wheel (download.pytorch.org/whl/cpu)"
    say "deps   : $(sed 's/[[:space:]]*#.*//' "$HERE/requirements.txt" | grep -vE '^[[:space:]]*$' | tr '\n' ' ')"
    [ "$GO" = 1 ] || { say; say "DRY-RUN. Re-run with --go to create the venv and install (large download)."; exit 0; }
    guard_mem
    command -v python3 >/dev/null || die "python3 not found"
    mkdir -p "$RAG_HOME" "$MODELS" "$LOGS"
    python3 -m venv "$VENV" || die "venv create failed"
    "$PIP" install --upgrade pip || die "pip upgrade failed"
    HF_HOME="$MODELS" "$PIP" install torch --index-url https://download.pytorch.org/whl/cpu || die "torch(cpu) install failed"
    HF_HOME="$MODELS" "$PIP" install -r "$HERE/requirements.txt" || die "deps install failed"
    "$PIP" freeze > "$RAG_HOME/requirements.lock.txt" 2>/dev/null || true
    ok "setup complete. Pinned set saved to $RAG_HOME/requirements.lock.txt"
    say "Next: $0 select <folder-under-archive> $SUBSET_MAX --go"
    ;;

  select)
    assert_safe_home
    root="${REST[0]:-}"; maxN="${REST[1]:-$SUBSET_MAX}"
    [ -n "$root" ] || die "usage: $0 select <folder> [maxN] --go   (e.g. select \"$ARCHIVE_ROOT/recovered/mary-ext-hitachi-1tb\" 200 --go)"
    [ -d "$root" ] || die "not a directory: $root"
    command -v pdftotext >/dev/null || die "pdftotext (poppler-utils) needed to detect scanned PDFs"
    say "${c_b}=== select up to $maxN SCANNED (image-only) PDFs under: $root ===${c_0}"
    mkdir -p "$RAG_HOME"
    tmp="$RAG_HOME/.select.tmp"; : > "$tmp"
    checked=0; picked=0
    while IFS= read -r -d '' f; do
      checked=$((checked+1))
      # scanned = no extractable text in the first 2 pages -> needs OCR (what Docling is for)
      if [ -z "$(pdftotext -l 2 "$f" - 2>/dev/null | tr -d '[:space:]')" ]; then
        printf '%s\n' "$f" >> "$tmp"; picked=$((picked+1))
        [ "$picked" -ge "$maxN" ] && break
      fi
    done < <(find "$root" -type f -iname '*.pdf' -print0 2>/dev/null)
    say "checked $checked PDFs; selected $picked scanned"
    [ "$GO" = 1 ] || { say; say "DRY-RUN. Re-run with --go to save the list to $LIST"; rm -f "$tmp"; exit 0; }
    mv "$tmp" "$LIST"; ok "wrote $picked paths to $LIST"
    ;;

  parse)
    [ -s "$LIST" ] || die "no input list; run: $0 select <folder> --go"
    [ -x "$PY" ] || die "venv missing; run: $0 setup --go"
    total="$(wc -l < "$LIST")"
    say "${c_b}=== parse $total PDFs (Docling/pypdfium, OCR on), ${DOC_TIMEOUT}s OS-timeout each ===${c_0}"
    [ "$GO" = 1 ] || { say "DRY-RUN. Would write text JSON to $PARSED/ and quarantine failures to $QUAR. Re-run with --go."; exit 0; }
    guard_mem
    mkdir -p "$PARSED" "$LOGS"; : > "$QUAR"; : > "$LOGS/parse.log"
    i=0
    while IFS= read -r f; do
      i=$((i+1)); key="$(printf '%s' "$f" | md5sum | cut -c1-16)"
      printf '[%d/%d] %s\n' "$i" "$total" "$f"
      if timeout -k 5 "$DOC_TIMEOUT" "$PY" "$HERE/parse_one.py" "$f" "$PARSED/$key.json" >>"$LOGS/parse.log" 2>&1; then :; else
        rc=$?; printf '%s\tEXIT=%s\n' "$f" "$rc" >> "$QUAR"
        printf '  -> quarantined (exit %s)\n' "$rc"
      fi
    done < "$LIST"
    ok "parse done. parsed=$(find "$PARSED" -name '*.json' 2>/dev/null | wc -l), quarantined=$(wc -l < "$QUAR")"
    ;;

  embed)
    [ -d "$PARSED" ] && [ -n "$(find "$PARSED" -name '*.json' 2>/dev/null | head -1)" ] || die "nothing parsed; run: $0 parse --go"
    [ -x "$PY" ] || die "venv missing; run: $0 setup --go"
    say "${c_b}=== embed parsed text with BGE-M3 -> Milvus Lite ($DB) ===${c_0}"
    [ "$GO" = 1 ] || { say "DRY-RUN. Would embed $(find "$PARSED" -name '*.json' | wc -l) docs into $DB. Re-run with --go."; exit 0; }
    guard_mem
    mkdir -p "$LOGS"
    if [ -x /usr/bin/time ]; then
      HF_HOME="$MODELS" /usr/bin/time -v "$PY" "$HERE/embed_store.py" "$PARSED" "$DB" 2>"$LOGS/embed.time" | tee "$LOGS/embed.log"
    else
      say "(note: /usr/bin/time not installed -> no peak-RSS capture; 'sudo apt install time' to get it)"
      HF_HOME="$MODELS" "$PY" "$HERE/embed_store.py" "$PARSED" "$DB" 2>&1 | tee "$LOGS/embed.log"
    fi
    ok "embed done. db size: $(du -h "$DB" 2>/dev/null | cut -f1)"
    ;;

  query)
    q="${REST[*]:-}"; [ -n "$q" ] || die "usage: $0 query \"keywords or question\""
    [ -f "$DB" ] || die "no vector db; run: $0 embed --go"
    [ -x "$PY" ] || die "venv missing; run: $0 setup --go"
    HF_HOME="$MODELS" "$PY" "$HERE/query.py" "$DB" "$q"
    ;;

  measure)
    say "${c_b}=== pilot measurements ===${c_0}"
    say "parsed docs : $(find "$PARSED" -name '*.json' 2>/dev/null | wc -l)"
    say "quarantined : $([ -f "$QUAR" ] && wc -l < "$QUAR" || echo 0)"
    say "vector db   : $(du -h "$DB" 2>/dev/null | cut -f1 || echo -)"
    say "models      : $(du -sh "$MODELS" 2>/dev/null | cut -f1 || echo -)"
    say "venv        : $(du -sh "$VENV" 2>/dev/null | cut -f1 || echo -)"
    say "total pilot : $(du -sh "$RAG_HOME" 2>/dev/null | cut -f1 || echo -)"
    if [ -f "$LOGS/embed.time" ]; then say; say "embed peak RSS / wall clock:"; grep -E 'Maximum resident|Elapsed \(wall' "$LOGS/embed.time" | sed 's/^/  /'; fi
    if [ -f "$LOGS/parse.log" ]; then
      say; say "Docling convert timings (excludes per-file model load):"
      grep -hoE 'convert_secs=[0-9.]+ pages=[0-9]+' "$LOGS/parse.log" | head -8 | sed 's/^/  /'
    fi
    ;;

  teardown)
    say "${c_b}=== teardown ===${c_0}"
    say "removes EVERYTHING under: $RAG_HOME (venv, models, vector db, logs)"
    say "does NOT touch $ARCHIVE_ROOT or the recoll index."
    [ "$GO" = 1 ] || { say; say "DRY-RUN. Re-run with --go to delete."; exit 0; }
    assert_safe_home
    [ -d "$RAG_HOME" ] && rm -rf "$RAG_HOME" && ok "removed $RAG_HOME" || say "(nothing to remove)"
    ;;

  *)
    cat <<H
rag-pilot — Phase-1 feasibility pilot (Docling -> BGE-M3 -> Milvus Lite). Additive & reversible.
Everything lives under RAG_HOME=$RAG_HOME (NVMe). Sources read-only. recoll index untouched.

  $0 setup --go                    create venv + install CPU-only deps (large first-time download)
  $0 select <folder> [N] --go      pick up to N (def $SUBSET_MAX) SCANNED PDFs under <folder>
  $0 parse --go                    Docling-parse them (${DOC_TIMEOUT}s OS-timeout each; failures quarantined)
  $0 embed --go                    BGE-M3 embed (dense+sparse) -> Milvus Lite
  $0 query "keywords"              hybrid (dense+sparse) search demo
  $0 measure                       footprint + timings
  $0 teardown --go                 delete the whole pilot in one shot

Mutating steps DRY-RUN without --go. Env: RAG_HOME, DOC_TIMEOUT, MIN_FREE_MIB, SUBSET_MAX.
H
    ;;
esac
