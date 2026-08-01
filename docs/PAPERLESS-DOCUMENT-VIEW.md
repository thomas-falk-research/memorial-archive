# Feasibility & Design — Paperless-ngx as the family's curated **Documents** view

**Status:** design assessment + one safety fix. **No install, no ingest, nothing fed to Paperless yet.**
Nothing here touches masters, the recoll index, Immich, or the running family services.

**Date:** 2026-07-27 · Companion to `docs/RAG-HYBRID-SEARCH-FEASIBILITY.md` (same house style: measure
before believing; every unmeasured number is marked **[unmeasured]**).

---

## 1. Bottom line

The family's problem is **not** "we can't search the archive" — recoll already does that across ~1M
files. It is that **browsing 1M loose, duplicated, meaninglessly-named files has no shape**. Paperless-ngx
fixes shape, not search: tags, correspondents, document types, saved views, per-document titles.

That works **only if we feed it a curated few thousand documents, not the whole archive.** Feeding it
everything recreates the haystack inside a slower UI and buries the box in weeks of OCR. So:

- **Keep Paperless-ngx.** It is already in this repo (`archive-paperless-setup.sh`), already routed
  (`docs.<domain>` → `127.0.0.1:8000`), already backed up (`archive-backup` runs its `document_exporter`),
  already health-checked (`archive-doctor.sh`) and version-audited (`ci/version-audit.sh`). It is the
  right tool and the integration work is done.
- **The work left is curation and ingest**, not deployment: *which* documents, copied *how*, tagged *how*,
  at a rate that doesn't starve Immich.
- **One thing must be fixed before anything else** — see §2. It is a live lockout risk that exists today,
  independent of this project.

### Papermerge, briefly (since it prompted this)

You corrected yourself, and the correction was right — but for the record, so it's settled and we never
re-open it:

| | Paperless-ngx | Papermerge 3.x |
|---|---|---|
| Full-text search | built in (Whoosh index, in-process) | **requires Solr 9.x** — a separate JVM service |
| Extra always-on RAM here | none beyond the app | **+~1–1.5 GB [unmeasured]** for Solr alone |
| Containers | app + Postgres + Redis | app + Postgres + Redis + Solr + a worker per function (OCR, i3/index, path-tmpl, S3) |
| Fit with this box | Immich already owns the RAM headroom | Solr's JVM competes directly with Immich ML |
| Fit with this repo | fully integrated already | greenfield: new setup script, proxy route, backup path, doctor checks |

Papermerge would cost a JVM's worth of RAM on a 14 GiB box that is already tight, to get less automation
(Paperless's matching rules auto-tag on consume) and no existing integration. **Stay with Paperless-ngx.**

---

## 2. ⚠ Blocking hazard — the "Update" menu will jump Paperless from v2 to v3 today

This is the most important finding in this document, and it has nothing to do with the family's document
problem — it is armed right now.

**Mechanism.** `archive-paperless-setup.sh` resolves the *latest* upstream tag at run time when
`PAPERLESS_VERSION` is unset:

```
PAPERLESS_VERSION="$(git ls-remote --tags ... | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
```

`manage.sh` → **3) Update** calls `refresh_installed --update`, which runs
`archive-paperless-setup.sh --yes` with **no version pinned** (only `--repair` pins the installed tag).
Paperless-ngx **v3.0.0 shipped in 2026**; latest is **v3.0.3**. So one menu click on a v2.x box performs an
unattended **major upgrade**, and the script then `curl`s the v3 compose **directly over the live
`docker-compose.yml`** before anything is validated.

**Why that is a lockout, not an inconvenience:**

1. **v3 can only be upgraded into from v2.20.15**, after that version's migrations have run. From any
   earlier 2.x the migration is unsupported.
2. **v3.0.1 shipped a broken migration** (fixed in 3.0.2) — the version resolver has no concept of
   "known-bad release".
3. **The compose's Postgres service and its data-dir mount have moved** across recent tags (`postgres:16`
   with `pgdata:/var/lib/postgresql/data` → `postgres:18` with `pgdata:/var/lib/postgresql`). If the box's
   volume was created under the old layout, the new one points Postgres at an *empty* PGDATA inside the
   same volume and **initialises a fresh, empty cluster**. Paperless then starts up **blank** — every tag,
   correspondent, title and date gone — while the document files sit untouched in the `media` volume.
   That failure is silent and looks like "the app lost everything".
4. v3 also **drops all task history**, **removes document encryption** (requires `decrypt_documents`
   *before* upgrading), and **stops rejecting duplicates by default**.

**The fix (implemented in this branch, not yet run):** `archive-paperless-setup.sh` no longer floats.

- Fresh install → a **recorded pin** (`v3.0.3`), never "whatever is latest today". *Why v3 on a fresh
  box:* with no database there is no migration to get wrong, and starting on v2 only means facing the
  one-way v3 door later, with the family's tags already in it. If you'd rather start conservative,
  `PAPERLESS_VERSION=2.20.15 bash archive-paperless-setup.sh` pins v2 — your call, and it is worth
  making deliberately, because it is the one decision that is cheap now and expensive later.
- Re-run on an existing install → **defaults to the tag already deployed** (zero drift).
- `--upgrade` allows patch/minor moves; **crossing a major version requires `--upgrade-major`** *and* an
  existing `document_exporter` export, and prints the v2.20.15 stepping-stone requirement.
- The new compose is fetched to a **temp file** and diffed against the live one first: if the **db image**
  or the **pgdata mount path** would change, it **refuses and exits without touching anything**.
- The previous compose is kept as `docker-compose.yml.bak-<tag>` for rollback.
- `manage.sh --update` now passes `--upgrade`, so the Update menu still advances patch/minor versions —
  it just can no longer walk into the major migration unattended.

Covered by a new CI drill (`ci/paperless-upgrade-guard.sh`) that runs the real script against stub
`docker`/`curl`/`git` and asserts the refusals actually refuse — including that `docker compose up -d` is
never reached and the on-disk compose is byte-identical after a blocked upgrade.

**Whether this hazard is live depends on what's actually deployed** — `paperless/probe-paperless-state.sh`
(§9) reports the installed tag, the db image, and the real PGDATA layout inside the volume.

---

## 3. Where Paperless fits among the tools already running

| Tool | Owns | Scope |
|---|---|---|
| **recoll** (`search.<domain>`) | *find any string anywhere* | all ~1M files, incl. OCR'd scans — the safety net |
| **copyparty** (`files.<domain>`) | *browse the raw tree as-is* | read-only view of masters |
| **Immich** (`photos.<domain>`) | *photographs* | in-place external library — **not** documents |
| **Paperless-ngx** (`docs.<domain>`) | *the documents that matter, organised* | **a curated copy**, few thousand docs |

Paperless is deliberately **not** a mirror of the archive. It is the shelf you put the important papers on
after you find them. recoll stays the exhaustive index; nothing is deleted from anywhere.

---

## 4. Resource budget (the constraint that shapes everything)

Same binding constraint as the RAG assessment: **RAM, with Immich already resident.** ~14 GiB total,
realistically **~8–11 GiB free at rest**.

| Component | Expected resident | Notes |
|---|---|---|
| Paperless webserver (gunicorn, 1 worker) | ~300–500 MB **[unmeasured]** | `PAPERLESS_WEBSERVER_WORKERS=1` |
| Paperless task worker (celery) idle | ~200–400 MB **[unmeasured]** | `PAPERLESS_TASK_WORKERS=1` |
| **OCR burst** (OCRmyPDF + ghostscript + tesseract) | **~1–2 GB peak per worker [unmeasured]** | the real risk; large TIFFs are worst |
| Postgres 18 | ~150–250 MB | its own instance, separate from Immich's |
| Redis/Valkey | ~20–50 MB | |
| *(optional)* Tika + Gotenberg | **+~0.5–1 GB** | only if we consume Office formats — see §5 |

**Guardrails to apply at install time, not after the first OOM:**

- `PAPERLESS_TASK_WORKERS=1`, `PAPERLESS_THREADS_PER_WORKER=2` — leaves cores for Immich ML and recoll.
- `PAPERLESS_WEBSERVER_WORKERS=1`, `PAPERLESS_ENABLE_NLTK=false` — upstream's own low-power advice.
- `PAPERLESS_CONVERT_MEMORY_LIMIT` and `PAPERLESS_MAX_IMAGE_PIXELS` set — a single 600-dpi multi-page TIFF
  is a decompression bomb that can OOM the box and take **Immich's Postgres** with it.
- **Hard Docker `mem_limit` + `cpus` on the Paperless services**, so a runaway OCR job is killed by Docker
  instead of by the kernel picking a victim. This is the single most valuable protection for the *other*
  services and is not in the current compose.
- Feed in **bounded batches with a queue watermark** (§6), never a 40k-file dump.

**Disk.** Paperless stores the original **plus** an OCR'd archive PDF → budget **~2× the fed bytes**, in
Docker volumes on the **OS NVMe** (existing convention: app data stays off the archive HDD budget). The
probe reports NVMe free space; a curated few-thousand-document corpus should be tens of GB, not hundreds.

---

## 5. Which documents to feed (corpus selection)

**Feed:**

- **PDFs** and **scanned images** (`.tif/.tiff`, and `.png/.jpg` that are *scans*, not photographs) —
  natively consumable, and exactly what the estate material is: faxes, `FaxImage.tif`, `SKM_*.pdf`,
  bare-numbered scans.
- **Attachments extracted from MKH's mailbox** (`.derived/` PST extraction). These are first-class: the
  will/trust/death-certificate faxes are *email attachments*, and they are the highest-value documents in
  the archive.

**Do not feed:**

- **Photographs** — Immich's job. (Scan-vs-photo separation is the one genuinely fuzzy call; the OCR text
  we already produced is a good discriminator — a page with recognisable words is a document.)
- **The 1M-file long tail** — program files, carved fragments, system junk. recoll keeps them findable.
- **Third parties' private documents** — cousins Michael & Margaret Hartigan's material stays unopened and
  unfed, per standing rule.

**Office documents (`.doc/.docx/.xls/.xlsx`) — an explicit decision needed.** MKH was an attorney; her
laptop will hold many. The repo deploys `docker-compose.postgres.yml`, which has **no Tika/Gotenberg**, so
Paperless **cannot consume Office formats as installed**. Two options:

1. **Add Tika + Gotenberg** (+~0.5–1 GB resident, two more containers), or
2. **Pre-convert to PDF** into the staging area (Stirling-PDF or headless LibreOffice), keeping the
   original untouched and recording the conversion in the manifest.

**Recommendation: (2)** — no permanent RAM cost, and a PDF is the better preservation artifact anyway. But
it is your call, and it can wait until after Tier A (§8).

---

## 6. Non-destructive ingest — the design that keeps masters safe

> **The single most dangerous fact about Paperless:** *files placed in the consume folder are **deleted**
> from it once consumed.* Upstream: "Files found in the consumption directory that are consumed will be
> removed from the consumption directory." **Therefore a master must never, under any circumstance, be
> placed in, moved to, symlinked into, or bind-mounted as the consume folder.** We feed **copies only**.

Proposed layout, entirely inside the existing derived area (never masters, never the archive's
`incoming/`):

```
/srv/archive/.derived/paperless-feed/
  staging/<batch-id>/<source-label>/<category>/...   copies waiting to be fed
  manifest/<batch-id>.tsv                            sha256 · master path · size · mtime · tags · status
  quarantine/                                        oversize / unreadable / failed — kept, never deleted
  fed.sha256                                         every hash ever fed (idempotence ledger)
```

Pipeline, per the standing rules (dry-run default, sandbox-tested, fails loudly, idempotent, re-runnable):

1. **Select** candidates from the plocate/recoll universe by extension + path + (optionally) existing OCR
   text matching estate terms. Selection is a *list*, reviewable before anything is copied.
2. **Copy** master → `staging/` with `cp --preserve=timestamps`, then **verify `sha256(copy) == sha256(master)`**.
   Masters are opened **read-only**; the drill checksums the master tree before and after to prove
   byte-identity.
3. **Deduplicate before feeding**: skip any hash already in `fed.sha256`. This is what stops us OCR'ing the
   same fax fifteen times because it survived on five drives — it saves days of CPU, not just clutter.
4. **Feed in batches** (~200 files), moving from `staging/` into `consume/`. Wait for the queue to drain
   below a watermark before the next batch. Paperless deletes the *copy* it consumed; the master is
   untouched and the manifest retains the link.
5. **Record**: manifest row per file — hash, master path, batch, assigned tags, and outcome
   (consumed / duplicate / failed). This manifest **is** the provenance chain from a document in the UI
   back to the drive it was recovered from, and it lives in a backed-up location.

**Provenance in the UI, for free:** enable `PAPERLESS_CONSUMER_RECURSIVE=true` and
`PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS=true` — Paperless turns each consume subdirectory into a **tag**. Using
a deliberately **shallow** staging path (`<source-label>/<category>/`, 2 levels, never the original deep
path) gives every document a source tag like `mkh-laptop` and a category tag automatically, with no tag
explosion.

**Duplicate policy:** set `PAPERLESS_CONSUMER_DELETE_DUPLICATES=true` so an identical-hash document is
rejected at the door (v3 otherwise ingests duplicates and merely flags them). To be explicit, because the
setting is alarmingly named: **it deletes the copy in the consume folder — never a master, never an
already-stored document.** Our own hash ledger (step 3) means it should rarely trigger.

**Near-duplicates** (same document rescanned or re-faxed — different bytes, same content) are *not*
solvable by checksum. Leave them in, and use czkawka (already deployed, `dupes.<domain>`) as a separate
human-reviewed pass. Do not let a dedup tool delete anything automatically.

---

## 7. Making it usable for a grieving, non-technical family member

Structure has to arrive *with* the documents; nobody is going to hand-tag 3,000 files.

- **Small, human tag vocabulary** — not a taxonomy project: `Estate`, `Will & Trust`, `Legal`, `Medical`,
  `Financial`, `Tax`, `Insurance`, `Property`, `Correspondence`, plus one `source:*` tag per drive.
- **Correspondents**: Northern Trust, Hartigan Law, banks, hospitals, insurers.
- **Document types**: Will, Trust, Death Certificate, Fax, Statement, Letter, Invoice, Tax Return.
- **Matching rules configured *before* the bulk feed**, so documents arrive pre-tagged: e.g. any document
  whose text contains `Ratliff`, `Northern Trust`, `December 5, 2005`, or `small estate affidavit` →
  auto-tag `Estate`. This is Paperless's real advantage over a plain file browser, and it directly serves
  the open search for John Sr.'s will, trust and death certificate.
- **Saved views on the dashboard**: "Estate & Will", "Recently added", "Untagged — needs a look".
- **One address, one login**: `docs.<domain>` via the existing Caddy front door; Paperless keeps its own
  login (like Immich and Docmost), loopback-bound, reachable on LAN/Tailscale. No change to the front door
  is needed — the route already exists.

---

## 8. Phased plan (each phase independently abortable, nothing destructive)

| Phase | What | Gate |
|---|---|---|
| **0** | Land the version guard (§2); run the probe (§9) and read the real numbers | ← **we are here** |
| **1** | Decide install-vs-existing from the probe; apply the resource guardrails (§4); set up tags, correspondents, types and matching rules on an **empty** library | your approval |
| **2** | **Tier A feed — the estate/legal set only** (hundreds to ~2k docs). Measure: sec/page, peak RAM, Immich stability, disk growth. Then *look at it as a family member would* | measured, reviewed |
| **3** | Tier B — household/financial/medical documents, same pipeline, larger batches | Tier A judged useful |
| **4** | Tier C — the remaining document-shaped long tail, only if the UI stays navigable | explicit decision |

Tier A is deliberately the estate subset: smallest useful corpus, highest emotional value, and it doubles
as a fresh pass over exactly the material where the will, trust and death certificate are hiding.

**Rollback at any point:** `cd /srv/apps/paperless && sudo docker compose down`, delete the directory and
its volumes. Masters, recoll, Immich and copyparty are untouched by construction. The feed area is a
deletable directory under `.derived/`.

---

## 9. What the probe must tell us before Phase 1

`paperless/probe-paperless-state.sh` — **read-only, writes nothing, redacts secrets**:

1. **Is Paperless installed, and at what version** — plus the db image and the **actual PGDATA layout
   inside the volume** (this decides whether the §2 hazard is armed).
2. **RAM headroom right now**, with Immich running, and per-container memory.
3. **NVMe free space** (Paperless's ~2× storage) and archive HDD free space.
4. **Candidate document census** — counts and bytes by type (PDF / TIFF / scan-like images / Office /
   mail attachments), split by `incoming/`, `recovered/`, `.derived/`. This is the number that decides
   whether Tier A is 400 documents or 40,000.
5. **Exact-duplicate pressure** — how much of the candidate set is redundant by size-collision (a cheap
   upper bound on hash duplicates), i.e. how much OCR work dedup will save.
6. **What we already OCR'd** — the sidecar cache, usable both for scan-vs-photo discrimination and for
   estate-term selection.

---

## 10. Open questions — to be answered by measurement, not assumption

1. **Real OCR throughput on this box** (i5-10500T, 1 worker × 2 threads): plausibly **~2–10 s/page**
   **[unmeasured]**, which is the difference between an overnight Tier A and a week-long one.
2. **Peak RSS of an OCR burst** on the worst real input we own (large multi-page TIFF faxes) — sets the
   Docker `mem_limit`.
3. **Whether Immich stays responsive** during sustained OCR (the only "did we break the family's stuff"
   question that matters).
4. **Office documents**: Tika/Gotenberg vs pre-conversion (§5) — pending your call and a count from the probe.
5. **Does `archive-backup`'s `document_exporter` step still work under v3** (exporter flags moved between
   majors), and how large the export gets after a bulk ingest.
6. **Scan-vs-photo discrimination accuracy** on the `.jpg/.png` set — how many photographs would leak into
   Paperless under the OCR-text heuristic.

---

## 11. Sources

- Paperless-ngx docs — `usage.md` (consume-folder deletion; duplicate detection by checksum),
  `configuration.md` (`PAPERLESS_CONSUMER_RECURSIVE`, `..._SUBDIRS_AS_TAGS`, `..._DELETE_DUPLICATES`,
  `TASK_WORKERS`, `THREADS_PER_WORKER`, `WEBSERVER_WORKERS`, `CONVERT_MEMORY_LIMIT`, `MAX_IMAGE_PIXELS`),
  `setup.md` (Office formats need the `-tika` compose; low-power tuning advice),
  `migration-v3.md` (v2.20.15 prerequisite, encryption removal, task-history drop, duplicate-policy change)
- Paperless-ngx releases — v3.0.0 breaking changes; v3.0.1 broken migration → v3.0.2; current v3.0.3
- `docker/compose/docker-compose.postgres.yml` at tags v2.20.15 and v3.0.3 — db image and `pgdata` mount path
- Paperless-ngx discussions #1920, #7479, #9492 — bulk-import practice; `document_importer` requires an
  **empty** installation (it is a restore tool, not an ingest tool)
- Papermerge 3.x docs — Docker Compose service list (webapp + Postgres + Redis + **Solr 9.x** + i3/OCR/S3 workers)
- This repo: `archive-paperless-setup.sh`, `archive-proxy-setup.sh`, `archive-storage-setup.sh`
  (`archive-backup`'s Paperless exporter), `manage.sh`, `ci/version-audit.sh`,
  `docs/RAG-HYBRID-SEARCH-FEASIBILITY.md`

*Facts above were taken from upstream documentation at the tags named; **re-verify the version pin and the
compose's db image/mount at deploy time** — that is exactly the drift §2 exists to catch.*
