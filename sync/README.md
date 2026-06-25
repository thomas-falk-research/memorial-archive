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

## Step 0 — discovery (do this first)
`discover-state.sh` is a **read-only** census (writes nothing; redacts secrets) of how the three
front-ends and the archive permissions are currently wired. Its output drives the design choices
(permission model, whether recoll can OCR images itself, how Immich is deployed).
```
./discover-state.sh        # paste the whole output back
```
Nothing else in this directory runs until the design is agreed.
