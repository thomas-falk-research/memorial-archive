# Handoff — continue from here

**Written:** 2026-08-01, end of the Open Archiver session. Everything below is measured on archive-pc
unless marked otherwise. Branch: `claude/memorial-archive-handoff-7hsrut`.

---

## The one open thread that matters

Still hunting **John M. Hartigan Sr.'s WILL, TRUST (dated 5 Dec 2005) and DEATH CERTIFICATE**. Proven
to exist as faxed scans — a Mar 3 2009 cover letter from Mary K. Hartigan Esq. to Northern Trust
("Ms. Ratliff") references them. They hide as scanned email attachments with meaningless names
(`FaxImage.tif`, `image001.gif`, `SKM_*.pdf`, bare numbers).

**This session built the instrument for finding them, and proved it works.** It has not yet been
pointed at the mailboxes that would contain them.

---

## What is running now

**Open Archiver v0.5.2** at `/srv/apps/openarchiver`, 5 containers, loopback-bound on `127.0.0.1:3010`.
Admin account created. Reached from the Mac by SSH tunnel:

```bash
ssh -N -L 8931:127.0.0.1:3010 tom@archive-pc      # then http://127.0.0.1:8931
```

`ORIGIN`/`APP_URL` are currently `http://127.0.0.1:8931` to match that tunnel. **A Caddy route
(`mail.<domain>`) is wired in `archive-proxy-setup.sh` but not yet set up** — doing so needs
`OPENARCHIVER_URL=http://mail.home bash archive-openarchiver-setup.sh --yes` to match, or logins break.

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
Drilled in both directions by `ci/openarchiver-env-guard.sh` (22 cases).

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

```bash
cd ~/memorial-archive
git checkout main && git pull --ff-only origin main      # PR #50 is merged; main is the source of truth

# 0. PROVE the secrets are off the box before importing anything real. This is a hard gate:
#    ENCRYPTION_KEY and STORAGE_ENCRYPTION_KEY cannot be regenerated, and every message
#    imported before they are safe is a message lost if this box dies.
bash openarchiver/backup-env.sh                          # prints the digest + the exact fetch command
bash openarchiver/backup-env.sh verify ~/openarchiver-env-backup.txt --expect DIGEST

# 1. Import the already-staged law mailbox — the highest-probability target AND the
#    OCR-heavy timing measurement. In the UI: PST Import / Local Path / /import/Law.biz.pst
#    Preserve Original File = CHECKED   ·   Merge into existing = UNCHECKED
#    Watch:  watch -n5 free -h   and   sudo docker compose logs -f open-archiver

# 2. Run the hunt
#    Ratliff · "Northern Trust" · Hartigan Kenilworth · "December 5" · "small estate affidavit"
#    with Search in INCLUDING attachment content, and a 2009 date range

# 3. Prove the app left the staged copies alone
bash openarchiver/verify-openarchiver.sh staged

# 4. Then work down the tiers from
bash openarchiver/inventory-mailboxes.sh
```

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
