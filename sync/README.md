# sync — keep the archive in sync across copyparty, recoll, and Immich

Goal: **everything viewable in copyparty, searchable in recoll, and scanned into Immich — complete and
up to date** — without ever touching masters (`images/`, `incoming/`) or destabilising the running
family services.

## The shape (to be finalised after discovery)
1. **One derived layer** — a non-hidden, copyparty-served, recoll-indexed, *writable* folder
   (candidate: `recovered/derived/`) for OCR output and rendered scans. Masters stay read-only.
2. **Close recoll's OCR blind spot** — recoll OCRs PDFs but **not** standalone images. Either let a
   newer recoll OCR images natively, or generate **searchable PDFs** (tesseract) into the derived
   layer so recoll indexes them and copyparty shows them. This is what finally surfaces buried scans
   (e.g. John Sr.'s will/trust) by search.
3. **Immich external library** — point Immich at the recovered photos *in place* (read-only); it scans
   without copying or moving anything.
4. **One idempotent `archive-sync`** (dry-run by default) — OCR new files → incremental recoll index →
   Immich scan. Re-runnable; that's the "stays up to date" part.

## Closing recoll's image-OCR blind spot (the will/trust fix)
recoll OCRs scanned PDFs but not standalone images, so scanned image attachments (incl. the fax TIFFs
inside the mailboxes) are invisible to content search. Fix = `imgocr = 1` in recoll.conf + a `mimeconf`
overlay mapping scan-like image types to the `rclimg.py` handler. This is now baked into the generator
(`archive-search-setup.sh`), gated on `OCR_IMAGES` (default on) and scoped by `OCR_IMAGE_TYPES`
(default `tiff png gif bmp` — jpeg excluded so the photo collection isn't needlessly OCR'd). OCR output
is content-hash cached under `.recoll/ocrcache`, so the cost is paid once, even across `-Z`/`-z`.

**Prove it before deploying:** `test-imgocr.sh` builds a throwaway scratch index over a few generated
files and asserts (1) scan-like images get OCR'd, (2) jpeg does not, (3) other formats still index.
```
./test-imgocr.sh        # writes only to /home/tom/recoll-ocrtest; real index untouched
```
**Deploy (after the scratch test passes):** re-run `archive-search-setup.sh` to regenerate
`archive-index`, then a one-time `recollindex -c /srv/archive/.recoll -Z` to retroactively OCR the
~41k already-indexed scans (in-place reset; non-destructive). New scans are OCR'd incrementally
thereafter. Run the `-Z` overnight, `nice`/`ionice`'d, so the family services keep their cores.

## Step 0 — discovery (do this first)
`discover-state.sh` is a **read-only** census (writes nothing; redacts secrets) of how the three
front-ends and the archive permissions are currently wired. Its output drives the design choices
(permission model, whether recoll can OCR images itself, how Immich is deployed).
```
./discover-state.sh        # paste the whole output back
```
Nothing else in this directory runs until the design is agreed.
