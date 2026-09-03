# Handoff — continue from here

**Written:** 2026-08-01, end of the Open Archiver session. Everything below is measured on archive-pc
unless marked otherwise. Branch: `claude/memorial-archive-handoff-7hsrut`.

---

## Gate 2 is PASSED on v0.6.0 — all five formats (2026-09-03)

`OCRWILLMARKER` (PDF) · `OCRTIFFMARKER` (**TIFF — the format the hunt depends on**) ·
`OCRFAXPAGETHREE` (page 3 of a 3-page Group 4 fax) · `OCRGIFMARKER` (GIF) ·
`OCRLASTPAGEMARKER` (page 25 of 25). Each matched inside its own attachment.

Faxed scans are reachable by content, multi-page faxes index in full, and long documents are not
truncated. **Caveat that matters when a real search comes back empty:** the fixtures are pristine
synthetic renders and prove the pipeline, not OCR accuracy on a degraded 2009 fax. A dry result on
a real document is weak evidence of absence — search several terms. Full reasoning: `§7i`.

## The one open thread that matters

Still hunting **John M. Hartigan Sr.'s WILL, TRUST (dated 5 Dec 2005) and DEATH CERTIFICATE**. Proven
to exist as faxed scans — a Mar 3 2009 cover letter from Mary K. Hartigan Esq. to Northern Trust
("Ms. Ratliff") references them. They hide as scanned email attachments with meaningless names
(`FaxImage.tif`, `image001.gif`, `SKM_*.pdf`, bare numbers).

**This session built the instrument for finding them, and proved it works.** It has not yet been
pointed at the mailboxes that would contain them.

---

## What is running now

**Open Archiver** at `/srv/apps/openarchiver`, 5 containers. Recorded pin: **v0.6.0**
(released 2026-08-24). A box still running v0.5.2 keeps it until deliberately upgraded — see §7h.
Admin account created. Reached from the Mac by SSH tunnel:

```bash
ssh -N -L 8931:127.0.0.1:3010 tom@archive-pc      # then http://127.0.0.1:8931
```

`ORIGIN`/`APP_URL` must always match how the app is reached, or SvelteKit rejects every form post —
the UI loads and every submission fails. Three sanctioned ways to reach it:

| | |
|---|---|
| SSH tunnel (default) | loopback bind; `ssh -N -L 8931:127.0.0.1:3010 tom@archive-pc` |
| **Tailnet, direct** | `bash archive-openarchiver-setup.sh --tailscale` → browse `http://100.x.y.z:3010` |
| `mail.home` via Caddy | `OPENARCHIVER_URL=http://mail.home bash archive-openarchiver-setup.sh` + `archive-proxy-setup.sh` |

Each is a **cutover**: the previous URL stops being a valid origin. `--tailscale` moves the bind and
`ORIGIN` together; the installer refuses to run if they disagree, and preflight blocks on a mismatch.
`0.0.0.0` and LAN binds are refused outright.

Currently imported: 1,222 messages (2 synthetic + two 63 MB test auto-archives).

### ⚠ Do this before importing anything real
Get `/srv/apps/openarchiver/.env` **off the box**. `ENCRYPTION_KEY` and `STORAGE_ENCRYPTION_KEY`
cannot be regenerated; without them the stored mail is unreadable.

**This is no longer a trust-me step.** `openarchiver/backup-env.sh` fingerprints the live `.env`
(digests only — it never prints a secret, so its output is safe to paste off the box), hands you the
exact fetch command, and then *verifies the copy that actually arrived*:

```bash
bash openarchiver/backup-env.sh                 # on the box: digest + copy-paste fetch command
bash openarchiver/backup-env.sh verify ~/openarchiver-env-backup.txt --expect DIGEST
```

It exists because the usual failure is silent: `ssh HOST 'sudo cat ...' > file` leaves a **zero-byte
file** when sudo cannot prompt, and "the file is there" passes on that. With no reference to compare
against it reports **UNVERIFIED and exits non-zero** rather than implying the backup is good.
Drilled in both directions by `ci/openarchiver-env-guard.sh` (24 cases).

---

## Measured on this box — no longer guesses

| | |
|---|---|
| Import throughput | **1.75 MB/s**, ~17 messages/sec (63 MB / 610 msgs in **36 s**, 0 failures) |
| Storage multiplier | **~1.1×** the PST size — *not* the 2–3× estimated |
| Full corpus | 61.4 GiB distinct → **~68 GiB, ~10 hours** — but see the OCR caveat below |
| Mailbox files | **102 PSTs, 74.4 GiB → 75 distinct, 61.4 GiB** |
| Extractor (kreuzberg 4.10.2) | **276 MiB peak RSS**, 0.33 s/file mixed, ~1–3 s per OCR'd scan |
| Free RAM at rest | ~10.6 GiB with Immich running |
| NVMe free | ~508 GiB |

**The OCR caveat:** the timed mailbox was a text-heavy auto-archive. OCR is the expensive operation
(1–3 s/page). A scan-heavy mailbox could be 10× slower. **Re-measure on `Law.biz.pst`** — already
staged at `/srv/apps/openarchiver/import/Law.biz.pst`, not yet imported.

---

## Decisions already settled (do not re-litigate)

1. **Import all 75 distinct mailboxes, accepting duplication.** Open Archiver does **not** deduplicate
   across sources (measured: two overlapping mailboxes → 330 messages stored twice). But "newest
   generation only" is **unsafe**: of 610 messages in the 2013 archive, **280 exist nowhere else** —
   the 2018 generation dropped them. For 2009 mail, the oldest archives are the likeliest survivors.
   Duplication is cosmetic; loss is not. Full reasoning: `docs/OPENARCHIVER-ASSESSMENT.md` §7c.
2. **kreuzberg 4.10.2 over Docling** for the RAG extraction tier — pinned, MIT, egress-PROVEN.
   `docs/RAG-EXTRACTION-XBERG-ASSESSMENT.md`.
3. **Paperless-ngx is parked**, not cancelled. `docs/PAPERLESS-DOCUMENT-VIEW.md` stands if the family
   ever wants a curated document shelf.
4. **Papermerge rejected** (needs a Solr JVM). Settled.

---

## Next actions, in order

**The order changed when v0.6.0 landed.** `textExtractor.ts` was rewritten in that release, so an
OCR answer from v0.5.2 says nothing about the version we will actually run — and the same goes for
merge/dedup behaviour. Both now run **after** the upgrade. There are two wipes on purpose: the
second is seconds long because the store only holds test data, and it buys a genuinely clean start
for the real ingestion.

```bash
# 1. SYNC — the box must be running the reviewed code
cd ~/memorial-archive && git fetch origin && git checkout main && git pull --ff-only origin main

# 2. GROUND TRUTH — read-only, changes nothing
bash openarchiver/preflight.sh

# 3. CLOSE THE LOCKOUT GATE — hard blocker. ENCRYPTION_KEY / STORAGE_ENCRYPTION_KEY cannot be
#    regenerated. `ssh HOST 'sudo cat .../.env'` fails ("a terminal is required"), and `ssh -t`
#    silently rewrites LF to CRLF — stage an owned copy on the box instead.
bash openarchiver/backup-env.sh                      # digest + the exact commands
sudo install -m 600 -o "$USER" /srv/apps/openarchiver/.env ~/openarchiver-env-backup.txt
#    from the Mac: scp archive-pc:~/openarchiver-env-backup.txt ~/openarchiver-env-backup.txt
#                  then the self-checking one-liner backup-env printed
rm ~/openarchiver-env-backup.txt                     # once it MATCHES
bash openarchiver/preflight.sh --env-backup-verified DIGEST

# 4. CLEAN SLATE #1 (destructive). Removes the volumes, NOT .env — the keys survive, so the
#    upgrade's additive migrations run on an empty schema and rollback stays cheap.
cd /srv/apps/openarchiver && sudo docker compose down -v

# 5. DEPLOY v0.6.0 + the network cutover together — one restart, verified once afterwards
cd ~/memorial-archive
bash archive-openarchiver-setup.sh --tailscale       # v0.6.0 is now the recorded pin
#    (or, for the Caddy front door instead of the tailnet:)
#      OPENARCHIVER_URL=http://mail.home bash archive-openarchiver-setup.sh && bash archive-proxy-setup.sh
#    Recreate the admin account — the wipe took the database with it.

# 6. RE-VERIFY EVERYTHING on v0.6.0. The OCR gate especially: its extraction path was rewritten.
bash openarchiver/verify-openarchiver.sh harden
bash openarchiver/verify-openarchiver.sh egress
bash ci/make-fixtures.sh
bash openarchiver/verify-openarchiver.sh ocr         # import once, then search ALL FIVE tokens
bash openarchiver/preflight.sh --env-backup-verified DIGEST

# 7. THE MERGE QUESTION, on v0.6.0 — decides how the 75 sources get created
bash openarchiver/dedup-experiment.sh step1          # stages + imports archive A
bash openarchiver/dedup-experiment.sh step2          # then B as a SEPARATE source
bash openarchiver/dedup-experiment.sh step3          # verdict
#    then re-import an already-imported mailbox with "Merge into existing" CHECKED:
bash openarchiver/dedup-experiment.sh check          # count barely moves = merge dedupes

# 8. CLEAN SLATE #2 — seconds; the store holds only test data, and the real run starts clean
cd /srv/apps/openarchiver && sudo docker compose down -v
cd ~/memorial-archive && bash archive-openarchiver-setup.sh --tailscale

# 9. THE REAL IMPORT — Law.biz.pst. Highest-probability target AND the OCR-heavy timing
#    measurement. PST Import / Local Path / /import/Law.biz.pst
#    Preserve Original File = CHECKED   ·   Merge into existing = per step 7's answer
#    Watch:  watch -n5 free -h   ·   sudo docker compose logs -f open-archiver

# 10. THE HUNT — attachment content ON, 2009 date range
#     Ratliff · "Northern Trust" · Hartigan Kenilworth · "December 5" · "small estate affidavit"

# 11. PROVE THE APP LEFT THE STAGED COPIES ALONE
bash openarchiver/verify-openarchiver.sh staged

# 12. Then work down the tiers
bash openarchiver/inventory-mailboxes.sh
```

**Steps 4 and 8 are the destructive ones.** `down -v` removes the Docker volumes (Postgres,
Meilisearch, the message store) but **not** `/srv/apps/openarchiver/.env` — the encryption keys
survive and the redeploy reuses them. Everything stored at that point is synthetic or test data, and
the store is derived anyway. Doing it this way avoids temporarily re-enabling `ENABLE_DELETION` and
leaves no half-deleted sources behind. It also costs the admin account each time; recreate it
promptly, before the address is shared.

**Step 5 is a cutover, not an addition.** Once `ORIGIN`/`APP_URL` move, the previous URL stops being
a valid origin and logins through it fail. `--tailscale` moves the bind and `ORIGIN` together and
refuses to run if they disagree.

**If the hunt comes up dry in the law mailbox**, the tier order is: `historical.pst` (2.1 GB, 7
locations) → `archive*.pst` → `personal.pst` → `Outlook MKH.pst`/`Outlook1.pst` → carved Hitachi
fragments last (unnamed, possibly truncated, expect failures).

---

## Still unanswered

1. **Does "Merge into existing ingestion" deduplicate?** Untested. It is a **create-time-only** option —
   it cannot be changed on an existing source, so the test needs a NEW source pointing at an
   already-imported mailbox with the box checked, then `dedup-experiment.sh check`. If it dedupes we
   get completeness *and* cleanliness. If not, proceed with duplication as decided above.
2. **OCR-heavy throughput** — see the caveat above.
3. **Whether `archive-backup` covers this app.** It has bespoke exporters for Paperless and Docmost;
   Open Archiver has none. Its store is derived (rebuildable from the masters), so this is not urgent —
   but the `.env` secrets are not. They still have to be copied off by hand; what is no longer manual
   is *checking that the copy is real* — `openarchiver/backup-env.sh verify`.
4. **A batch import driver.** 75 mailboxes via the UI is 75 manual dialogs. The DB has an `api_keys`
   table and the source has ingestion routes, so it is very likely scriptable: stage → import →
   verify → free the copy → next, resumable, with a memory floor. Not built; confirm the endpoints
   from the source first.
5. **`169.254.19.137`** appeared as the LAN IP — a link-local (APIPA) address, meaning no DHCP lease on
   that interface. Check `hostname -I` and `ip -4 addr`; `mail.home` DNS rewrites will not work if that
   is the only address.

---

## Gotchas discovered the hard way

- **Creating an ingestion source starts the import immediately.** No separate "run" step. Set the
  checkboxes before submitting.
- **`ENABLE_DELETION=false` blocks deleting ingestion sources**, not just mail. Deliberate, but it
  makes experiment housekeeping awkward — `openarchiver/README.md` has the sanctioned way round it.
- **`internal: true` on a Docker network also stops port publishing.** A host-side curl failing after
  the cut is expected, not evidence the app died — check from a sibling container instead.
- **Never paste multi-line blocks with `<placeholder>` text into a shell** — `<` redirects, and one
  such paste ran an SSH command on the wrong host.
- The setup scripts print the *first* address from `hostname -I`, which may be the link-local one.

---

## Standing rules (unchanged)

Never write to masters. Guard against data loss and lockout above all. Every script: dry-run default,
sandbox-tested with stubs, fails loudly, idempotent, writes only to derived areas, proven
non-destructive. Maintain provenance. Confirm before destructive or outward-facing actions. Nothing
leaves the box. Third parties' private documents (the cousins' material) stay unopened.

**A verification that cannot fail is not evidence.** Several checks in this session reported success
for properties they had not observed — each one is documented in the assessments alongside its fix.
Test every gate in both directions.
