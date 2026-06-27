#!/usr/bin/env bash
#
# archive-search-setup.sh — Phase 2 of the digital-archive server: make everything searchable.
#
# Installs a local, GUI-free equivalent of Windows "Everything" plus full-text search of EVERY file:
#   * recoll   — full-text content index for all common formats: PDF (incl. SCANNED, via OCR), Word/
#                Excel/PowerPoint (modern + legacy) and OpenDocument, RTF/HTML/text, email
#                (PST/OST/mbox/EML/MSG), and inside archives (zip/7z/tar/rar). Anything it can't read
#                as text is still found by NAME.
#   * plocate  — instant filename index ("search by what it's called") for every file.
#   * readpst  — convert Outlook PST/OST mailboxes so their messages become searchable.
#   * tesseract OCR + format helpers (poppler, antiword, catdoc, unrtf, p7zip, unar, ...) for recoll.
#
# and three commands:
#   archive-index    (re)build both indexes over the archive; extracts PST/OST first. Re-run
#                    after each ingest. Index data lives ON the archive volume, not the OS disk.
#                    Add --attachments (or EXTRACT_ATTACHMENTS=true) to also save PST/OST
#                    attachments as loose, browsable/printable files (not just searchable).
#   archive-search   full-text search of file CONTENTS, with snippets.
#   archive-find     instant filename search (substring or glob).
#
# Reads ARCHIVE_ROOT from /etc/archive-ingest.conf (written by archive-ingest-setup.sh).
# Run as a REGULAR user with sudo (NOT via `sudo ./archive-search-setup.sh`).
#
set -euo pipefail
umask 022
trap 'printf "\n\033[1;31mERROR\033[0m: command failed at line %s\n" "$LINENO" >&2' ERR

# ---- Packages --------------------------------------------------------------------------------
# recollcmd = recoll's CLI indexer/query without the Qt GUI (right choice for a server).
CORE_PKGS=( recollcmd plocate pst-utils poppler-utils antiword catdoc unrtf p7zip-full tesseract-ocr tesseract-ocr-eng )
# DjVu, RAR/extra archives, WordPerfect, Outlook .msg — each skipped individually if unavailable.
BEST_EFFORT_PKGS=( djvulibre-bin unar libwpd-tools libemail-outlook-message-perl )
SKIPPED=()

ASSUME_YES=false
usage() {
  cat <<USAGE
Usage: ${0##*/} [--yes|-y] [--help|-h]
  --yes, -y   skip the confirmation prompt (for unattended runs)
  --help, -h  show this help and exit
Installs recoll + plocate + readpst (+ filter helpers) and the archive-index /
archive-search / archive-find commands. ARCHIVE_ROOT is read from /etc/archive-ingest.conf.
USAGE
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)  ASSUME_YES=true ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '    \033[0;36m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m: %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -ne 0 ]] || die "Run as a regular user (not root / not via sudo). The script sudo's when needed."
command -v sudo >/dev/null 2>&1 || die "sudo is required."
# shellcheck source=/dev/null
. /etc/os-release 2>/dev/null || true
[[ "${ID:-}" == "ubuntu" ]] || warn "Targeting Ubuntu; detected ID='${ID:-unknown}'."
export DEBIAN_FRONTEND=noninteractive

# Discover ARCHIVE_ROOT so the summary is accurate (default matches the ingest installer).
ARCHIVE_ROOT="/srv/archive"
if [[ -r /etc/archive-ingest.conf ]]; then
  # shellcheck source=/dev/null
  . /etc/archive-ingest.conf || true
fi
if [[ ! -d "$ARCHIVE_ROOT" ]]; then
  warn "Archive root '$ARCHIVE_ROOT' does not exist yet."
  warn "Run archive-ingest-setup.sh first (and ingest something) — then run 'archive-index'."
fi

log "This will install (using sudo):"
printf '    - apt packages: %s\n' "${CORE_PKGS[*]}"
printf '    - best-effort:  %s\n' "${BEST_EFFORT_PKGS[*]}"
printf '    - commands to /usr/local/bin: archive-index, archive-search, archive-find\n'
printf '    - search index stored under: %s/.recoll and %s/.plocate.db (on the archive volume)\n' "$ARCHIVE_ROOT" "$ARCHIVE_ROOT"
if [[ "${ASSUME_YES}" != "true" ]]; then
  read -rp $'\nProceed? [y/N] ' _ans
  [[ "${_ans}" =~ ^[Yy] ]] || { echo "Aborted; nothing was changed."; exit 0; }
fi

sudo -v

log "Installing core packages"
sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${CORE_PKGS[@]}"

log "Installing best-effort extras (skipped individually if missing)"
for pkg in "${BEST_EFFORT_PKGS[@]}"; do
  if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1; then info "installed: $pkg"
  else warn "unavailable on this release: $pkg (skipped)"; SKIPPED+=("$pkg"); fi
done

log "Installing commands to /usr/local/bin"

info "writing archive-index"
sudo tee /usr/local/bin/archive-index >/dev/null <<'SCRIPT'
#!/usr/bin/env bash
# archive-index — (re)build the searchable indexes over the archive: full-text content
# (recoll) and filenames (plocate). recoll indexes INSIDE every common format (PDF incl. scanned
# via OCR, Office/OpenDocument, RTF/HTML/text, email PST/OST/mbox/EML/MSG, and archives); anything
# it can't read as text is still found by name. Outlook PST/OST are extracted first. Incremental and
# safe to re-run after every ingest.
set -uo pipefail
for _cfg in /etc/archive-ingest.conf "${XDG_CONFIG_HOME:-$HOME/.config}/archive-ingest.conf"; do
  # shellcheck source=/dev/null
  [[ -r "$_cfg" ]] && { . "$_cfg" || true; }
done
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"
RECOLL_CONFDIR="${RECOLL_CONFDIR:-${ARCHIVE_ROOT}/.recoll}"
PLOCATE_DB="${PLOCATE_DB:-${ARCHIVE_ROOT}/.plocate.db}"
# Optional attachment extraction: EXTRACT_ATTACHMENTS=true (or `archive-index --attachments`) makes
# readpst write every message AND attachment as a SEPARATE file, so attachments are browsable / printable
# loose files — not just searchable. Default keeps the compact mbox extraction (attachment CONTENT is
# indexed either way). Set EXTRACT_ATTACHMENTS=true in /etc/archive-ingest.conf to make it the default.
EXTRACT_ATTACHMENTS="${EXTRACT_ATTACHMENTS:-false}"
case "${1:-}" in --attachments|-a) EXTRACT_ATTACHMENTS=true ;; esac
# Use a UTF-8 locale so non-ASCII names/keywords work even from a misconfigured shell.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]*) : ;; *) export LC_ALL=C.UTF-8 ;; esac

c_grn=$'\033[1;32m'; c_yel=$'\033[1;33m'; c_cyn=$'\033[0;36m'; c_red=$'\033[1;31m'; c_rst=$'\033[0m'
ok()   { printf '%s%s%s\n' "$c_grn" "$*" "$c_rst"; }
note() { printf '%s%s%s\n' "$c_cyn" "$*" "$c_rst"; }
warn() { printf '%sWARN:%s %s\n'  "$c_yel" "$c_rst" "$*" >&2; }
err()  { printf '%sERROR:%s %s\n' "$c_red" "$c_rst" "$*" >&2; }

command -v recollindex >/dev/null 2>&1 || { err "recollindex not found — run archive-search-setup.sh first."; exit 1; }
[[ -d "$ARCHIVE_ROOT" ]] || { err "Archive root not found: $ARCHIVE_ROOT"; exit 1; }

# 1) Extract Outlook PST/OST mailboxes so their messages get indexed. Extractions are DERIVED data:
# they go in a sidecar tree OUTSIDE the master copies (under DERIVED_ROOT, mirroring the source path),
# so they never modify the verified masters, never show up in the read-only SMB browse view, and
# aren't counted against the cap or backed up as if they were originals. recoll still indexes them
# (DERIVED_ROOT is under ARCHIVE_ROOT, which is the recoll topdir).
DERIVED_ROOT="${DERIVED_ROOT:-${ARCHIVE_ROOT}/.derived}"
if command -v readpst >/dev/null 2>&1; then
  # -S writes every message AND attachment as a separate file (browsable / printable); -r writes a
  # compact mbox per folder. A distinct output suffix per mode means switching modes rebuilds cleanly
  # instead of reusing a stale extraction (the up-to-date check below is per-output-directory).
  if [[ "$EXTRACT_ATTACHMENTS" == "true" ]]; then rp_mode="-S"; rp_suffix=".attachments"
    rp_desc="separate files — attachments saved as loose files"
  else rp_mode="-r"; rp_suffix=".extracted"
    rp_desc="mbox — compact; attachment content indexed but not saved as files"; fi
  note "Scanning for Outlook PST/OST mailboxes to extract (${rp_desc})..."
  while IFS= read -r -d '' pst; do
    rel="${pst#"${ARCHIVE_ROOT}"/}"                       # path of the .pst relative to the archive root
    out="${DERIVED_ROOT}/${rel}${rp_suffix}"
    [[ -d "$out" && "$out" -nt "$pst" ]] && continue       # already extracted and up to date
    mkdir -p "$out"
    if readpst "$rp_mode" -o "$out" "$pst" >/dev/null 2>&1; then note "  extracted: $pst -> ${out}"
    else warn "  could not extract (skipped): $pst"; fi
  done < <(find "$ARCHIVE_ROOT/incoming" -type f \( -iname '*.pst' -o -iname '*.ost' \) -print0 2>/dev/null)
fi

# 2) Full-text index (recoll). Config + index live on the archive volume, not the OS disk. recoll has
# built-in handlers for every common format (Office/OpenDocument, PDF, RTF/HTML/text, email, archives),
# so NO per-format pre-extraction is needed beyond the PST/OST step above — it reads inside them at
# index time. Anything with no extractable text is still indexed by NAME (indexallfilenames).
mkdir -p "$RECOLL_CONFDIR"
# OCR (tesseract) makes SCANNED PDFs searchable by content. 'pdfocr = 1' is what triggers it (recoll
# OCRs a PDF only when it has no extractable text layer); 'ocrprogs'/'tesseractlang' pick the engine
# and language. On when tesseract is installed; disable with OCR_ENABLE=false, or set OCR_LANG=eng+deu
# etc. in /etc/archive-ingest.conf. The first index is slower (each scan is OCR'd; results are cached).
# (Standalone photos aren't OCR'd — OCRing every snapshot is slow and useless — they're found by name.)
ocr_conf=""
img_mimeconf=""
if [[ "${OCR_ENABLE:-true}" == "true" ]] && command -v tesseract >/dev/null 2>&1; then
  ocr_conf="ocrprogs = tesseract
tesseractlang = ${OCR_LANG:-eng}
pdfocr = 1"
  note "OCR on (tesseract, lang=${OCR_LANG:-eng}): scanned PDFs become searchable by content (slower first index)."
  # Standalone-IMAGE OCR (recoll >= 1.43.3; handler rclimg.py). recoll OCRs scanned PDFs but NOT
  # standalone images unless told to, so scanned IMAGES — including image attachments inside mailboxes
  # (the fax TIFFs) — are otherwise invisible to content search. Enabling needs BOTH 'imgocr = 1' here
  # AND a mimeconf overlay mapping the image MIME types to rclimg.py (written just below). Scoped to
  # SCAN-LIKE types only (NOT jpeg) so the photo collection isn't needlessly OCR'd; widen with
  # OCR_IMAGE_TYPES="tiff png gif bmp jpeg", or turn off with OCR_IMAGES=false. OCR output is
  # content-hash cached under ${RECOLL_CONFDIR}/ocrcache, so the cost is paid once, even across -Z/-z.
  if [[ "${OCR_IMAGES:-true}" == "true" ]] && [[ -f /usr/share/recoll/filters/rclimg.py ]]; then
    ocr_conf="${ocr_conf}
imgocr = 1"
    img_mimeconf="[index]"
    for _t in ${OCR_IMAGE_TYPES:-tiff png gif bmp}; do
      case "${_t,,}" in
        tif|tiff) img_mimeconf="${img_mimeconf}
image/tiff = execm rclimg.py" ;;
        png)      img_mimeconf="${img_mimeconf}
image/png = execm rclimg.py" ;;
        gif)      img_mimeconf="${img_mimeconf}
image/gif = execm rclimg.py" ;;
        bmp)      img_mimeconf="${img_mimeconf}
image/bmp = execm rclimg.py
image/x-ms-bmp = execm rclimg.py" ;;
        jpg|jpeg) img_mimeconf="${img_mimeconf}
image/jpeg = execm rclimg.py" ;;
        *) warn "  ignoring unknown OCR_IMAGE_TYPES entry: ${_t}" ;;
      esac
    done
    note "Image OCR on (rclimg.py): scanned IMAGES searchable too [types: ${OCR_IMAGE_TYPES:-tiff png gif bmp}]. A 'recollindex -Z' OCRs already-indexed ones (once; cached)."
  else
    note "Image OCR off (OCR_IMAGES=false or rclimg.py missing): scanned IMAGES found by NAME only."
  fi
else
  note "OCR off (tesseract missing or OCR_ENABLE=false): scanned-only PDFs are found by NAME, not content."
fi
# Always (re)write the managed config, so a changed ARCHIVE_ROOT or skip list actually takes effect
# on re-run (previously it was only written when absent, so stale paths could silently persist).
cat > "$RECOLL_CONFDIR/recoll.conf" <<EOF
# Generated by archive-index — regenerated on every run; do not edit by hand. The index lives here,
# on the archive volume, so it never fills the OS disk. Derived PST extractions under .derived ARE
# indexed; the raw forensic disk images under images/ are skipped (huge, not useful as full text).
topdirs = ${ARCHIVE_ROOT}
skippedPaths = ${RECOLL_CONFDIR} ${PLOCATE_DB} ${ARCHIVE_ROOT}/images
followLinks = 0
indexallfilenames = 1
# Record extraction FAILURES so they're never silently dropped (our "document every failure" rule).
# loglevel 2 = errors + warnings only (the failures) — NOT the per-document "update" stream — so the
# log stays small even over hundreds of thousands of files. It lives under .recoll, which is already
# in skippedPaths above, so recoll never indexes (or filename-lists) its own log.
logfilename = ${RECOLL_CONFDIR}/recoll-index.log
loglevel = 2
${ocr_conf}
EOF
# User mimeconf overlay: route scan-like image MIME types to the OCR-capable handler (rclimg.py).
# recoll LAYERS this over the system mimeconf — only these keys change; every other format indexes
# exactly as before. Written only when image OCR is on; our own managed overlay is removed when off
# (we never touch a hand-made mimeconf — only one carrying our marker line).
_mimeconf="$RECOLL_CONFDIR/mimeconf"
if [[ -n "$img_mimeconf" ]]; then
  printf '# Managed by archive-index — image-OCR overlay; do not edit by hand.\n%s\n' "$img_mimeconf" > "$_mimeconf"
elif [[ -f "$_mimeconf" ]] && head -1 "$_mimeconf" 2>/dev/null | grep -q 'image-OCR overlay'; then
  rm -f "$_mimeconf"
fi
note "Building/updating the full-text index (incremental; can take a while on first run)..."
recollindex -c "$RECOLL_CONFDIR" >/dev/null 2>&1 || { err "recollindex failed."; exit 1; }

# 3) Filename index (plocate), scoped to the archive.
note "Building/updating the filename index..."
# Prune the same things recoll skips: the forensic disk images, the index dirs, and the derived
# extractions — the filename index should list ORIGINALS, not multi-GB images or derived email files.
updatedb.plocate --database-root "$ARCHIVE_ROOT" --output "$PLOCATE_DB" --require-visibility 0 \
  --prunepaths "${ARCHIVE_ROOT}/images ${RECOLL_CONFDIR} ${DERIVED_ROOT}" 2>/dev/null \
  || warn "plocate index update failed (filename search may be stale)."
# The db holds only file NAMES (no contents). Make it readable regardless of which account built it,
# so 'archive-find' and the search service can always read it (--require-visibility 0 = no per-file checks).
if [[ -f "$PLOCATE_DB" ]]; then chmod 0644 "$PLOCATE_DB" 2>/dev/null || true; fi

ok "Indexes updated."
printf '    full-text index : %s  (%s)\n' "$RECOLL_CONFDIR" "$(du -sh "$RECOLL_CONFDIR" 2>/dev/null | cut -f1)"
printf '    filename index  : %s\n' "$PLOCATE_DB"
printf '    coverage        : text inside PDF/Office/email/archives%s; every file findable by name\n' "$([[ -n "$ocr_conf" ]] && echo " + OCR of scanned PDFs")"
[[ "$EXTRACT_ATTACHMENTS" == "true" ]] && printf '    attachments     : PST/OST attachments saved as loose files under %s/*.attachments\n' "$DERIVED_ROOT"
printf '    search contents : archive-search "keywords"\n'
printf '    search names    : archive-find "name"\n'
SCRIPT
sudo chmod +x /usr/local/bin/archive-index

info "writing archive-search"
sudo tee /usr/local/bin/archive-search >/dev/null <<'SCRIPT'
#!/usr/bin/env bash
# archive-search "keywords" — full-text search across the archive's CONTENTS (text, PDF, Office,
# RTF, extracted email, etc.). Prints each matching file path with a short snippet.
# Examples:  archive-search insurance policy        (files containing BOTH words)
#            archive-search '"life insurance"'       (the exact phrase)
set -uo pipefail
for _cfg in /etc/archive-ingest.conf "${XDG_CONFIG_HOME:-$HOME/.config}/archive-ingest.conf"; do
  # shellcheck source=/dev/null
  [[ -r "$_cfg" ]] && { . "$_cfg" || true; }
done
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"
RECOLL_CONFDIR="${RECOLL_CONFDIR:-${ARCHIVE_ROOT}/.recoll}"
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]*) : ;; *) export LC_ALL=C.UTF-8 ;; esac

c_red=$'\033[1;31m'; c_rst=$'\033[0m'
err() { printf '%sERROR:%s %s\n' "$c_red" "$c_rst" "$*" >&2; }
command -v recollq >/dev/null 2>&1 || { err "recollq not found — run archive-search-setup.sh first."; exit 1; }
[[ $# -ge 1 ]] || { echo 'usage: archive-search "keywords"   (e.g. archive-search insurance policy)'; exit 2; }
[[ -d "$RECOLL_CONFDIR" ]] || { err "No search index yet. Build it first:  archive-index"; exit 1; }

# -A prints an abstract (snippet). recollq logs go to stderr; drop them. Reformat into a clean
# "path then indented snippet" listing with file:// stripped to a plain path.
recollq -c "$RECOLL_CONFDIR" -A "$@" 2>/dev/null | awk '
  /^Recoll query:/ { next }
  /^[0-9]+ results?/ { print "(" $0 ")"; print ""; next }
  /\[file:\/\// { p=$0; sub(/.*\[file:\/\//,"",p); sub(/\].*/,"",p); print p; next }
  /^ABSTRACT$/   { next }
  /^\/ABSTRACT$/ { print ""; next }
  { print "    " $0 }
'
SCRIPT
sudo chmod +x /usr/local/bin/archive-search

info "writing archive-find"
sudo tee /usr/local/bin/archive-find >/dev/null <<'SCRIPT'
#!/usr/bin/env bash
# archive-find "name" — instant filename search across the archive (case-insensitive substring;
# glob patterns like '*.pst' also work). This is the "search by what it's called" companion to
# archive-search (which searches inside files).
set -uo pipefail
for _cfg in /etc/archive-ingest.conf "${XDG_CONFIG_HOME:-$HOME/.config}/archive-ingest.conf"; do
  # shellcheck source=/dev/null
  [[ -r "$_cfg" ]] && { . "$_cfg" || true; }
done
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/srv/archive}"
PLOCATE_DB="${PLOCATE_DB:-${ARCHIVE_ROOT}/.plocate.db}"
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]*) : ;; *) export LC_ALL=C.UTF-8 ;; esac

c_red=$'\033[1;31m'; c_rst=$'\033[0m'
err() { printf '%sERROR:%s %s\n' "$c_red" "$c_rst" "$*" >&2; }
command -v plocate >/dev/null 2>&1 || { err "plocate not found — run archive-search-setup.sh first."; exit 1; }
[[ $# -ge 1 ]] || { echo "usage: archive-find \"name\"   (e.g. archive-find vacation,  archive-find '*.pst')"; exit 2; }
[[ -f "$PLOCATE_DB" ]] || { err "No filename index yet. Build it first:  archive-index"; exit 1; }
exec plocate --database "$PLOCATE_DB" --ignore-case "$@"
SCRIPT
sudo chmod +x /usr/local/bin/archive-find

# ---- Summary ---------------------------------------------------------------------------------
log "Search tools installed."
cat <<EOF
    After each ingest, refresh the indexes:
      archive-index                 # full-text + filename indexes (PST/OST content included)
      archive-index --attachments   # ...and also save PST/OST attachments as loose files

    Then search:
      archive-search "keywords"     # inside files (content) — e.g. archive-search will testament
      archive-find  "name"          # by filename — e.g. archive-find '*.pst'

    The indexes live on the archive volume (${ARCHIVE_ROOT}/.recoll, ${ARCHIVE_ROOT}/.plocate.db),
    so they grow with the archive — not the OS disk.

    To let the family search from a phone browser, run archive-webui-setup.sh — it serves a
    password-protected recoll web UI on the local network (Caddy in front of a loopback service).
EOF
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  warn "Optional components skipped (not fatal): ${SKIPPED[*]}"
fi
