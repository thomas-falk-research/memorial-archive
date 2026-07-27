# Assessment — Open Archiver (LogicLabs-OU/OpenArchiver) for MKH's mailbox

**Status:** paper evaluation. **No install.** Nothing here touches masters, the recoll index, or the
running family services.

**Date:** 2026-07-27 · Same house rules as the other assessments: vendor claims labelled as such,
unmeasured numbers marked **[unmeasured]**, reservations stated rather than buried.

---

## 1. Bottom line

**Worth deploying — scoped to the mailbox, after two specific hardenings (§4).** It fills a gap nothing
else in the stack covers, and it fills it precisely where the open thread is.

Every search tool on this box is **content-first**: recoll matches strings, the RAG pilot matches
meaning. Neither can answer the question we have actually been asking for months:

> *"Show me everything to or from Ratliff or Northern Trust, around March 2009, that has an attachment."*

That is a **structured mail query** — correspondent, date range, attachment presence — and it is the
natural shape of the hunt for John Sr.'s will, trust and death certificate. We know a cover letter from
Mary K. Hartigan to Northern Trust ("Ms. Ratliff", 3 March 2009) references them. A mail-native index
turns that from a needle-in-a-haystack full-text problem into a filter.

**It also closes the PST gap for free.** Kreuzberg v4.10.2 — the pinned, egress-PROVEN extractor — reads
EML/MSG but not PST. Open Archiver imports **PST, Mbox and zipped EML natively, offline, with no cloud
service**. That removes the only argument for taking the xberg v5 release candidate.

---

## 2. What it is, and what it costs

| | |
|---|---|
| Purpose | self-hosted email archiving: ingest, dedup, compress, encrypt, full-text search |
| Ingestion | IMAP · Google Workspace · Microsoft 365 · **PST files · Mbox · zipped .eml** |
| Stack | Node/Express + SvelteKit, **PostgreSQL 17**, **Meilisearch v1.38**, **Valkey 8** (BullMQ), **Apache Tika 3.2.2-full** |
| Storage | local filesystem or S3-compatible |
| Deployment | Docker Compose |
| Licence | **AGPL-3.0** — fine for self-hosting; it only bites if you offer it as a network service to others |
| Stated requirement | **≥ 4 GB RAM** (2 GB with external Postgres/Redis/Meilisearch) |

**The real resource cost is five services, one of which is a JVM.** Tika `-full` is the same class of
tenant I rejected Papermerge over (its Solr JVM). The difference is what we get for it: Papermerge's JVM
bought a search engine we already have three of; this one buys **native PST traversal and a mail-native
UI**, which we have none of.

**Headroom check.** Measured on the box today during the extractor bench: **MemAvailable 10,659 MiB**.
A 4 GB stack fits — but it is roughly **40% of free RAM committed permanently to one mailbox**. That is
the trade to weigh, and it argues for deploying it as a **time-boxed evaluation** rather than a
permanent fixture: ingest, use it for the hunt, then decide whether it earns its residency.

---

## 3. Where it fits — and where it overlaps

| Tool | Answers |
|---|---|
| **recoll** | "which files anywhere contain this string" |
| **copyparty** | "let me browse the raw tree" |
| **Immich** | "show me the photographs" |
| **RAG pilot** (kreuzberg → BGE-M3) | "what does the corpus *mean* — find this semantically" |
| **Paperless-ngx** *(parked)* | "the important documents, organised on a shelf" |
| **Open Archiver** | **"this correspondent, this date range, with attachments"** |

The overlap with the RAG pilot is real but complementary, and the two compose usefully: Open Archiver
does the **PST → messages + attachments** traversal that kreuzberg v4 can't, and its extracted output is
a clean source to feed the semantic pipeline. Structured filtering narrows; semantic search finds.

---

## 4. Hardening required BEFORE any family mail goes in

Two concrete findings from reading the stack, not hypotheticals:

### 4.1 ⛔ Meilisearch phones home by default

**Meilisearch collects analytics from every instance that does not explicitly opt out.** It is disabled
only by setting `MEILI_NO_ANALYTICS` (or `--no-analytics`), and **the project's compose does not appear
to set it**. So a default `docker compose up` stands up a service that periodically reports to
Meilisearch about an archive of a deceased attorney's correspondence.

To be precise rather than alarmist: the telemetry is *instance and usage metadata* — index counts,
settings, versions — **not message content**. It is still an unforced outbound connection from a machine
whose entire governing rule is that nothing leaves it. **`MEILI_NO_ANALYTICS=true` is mandatory, set
before the first start**, not after.

### 4.2 Ports, connectors, and the source file

- **Bind every published port to `127.0.0.1`** and front it with the existing Caddy, exactly as
  copyparty/Docmost/Immich are. The upstream compose publishes `3000` broadly.
- **Never configure the Google Workspace or Microsoft 365 connectors.** They are the only parts that
  require credentials or reach the internet. File import is entirely offline. Nothing in this archive
  should be reachable from a cloud tenant.
- **Feed it a COPY of the PST, never the master.** Standing rule, and doubly so here: an ingest pipeline
  that dedups, compresses and encrypts into its own store is exactly the kind of thing whose behaviour
  toward its source file we have not verified. **Whether it moves, modifies or deletes the source after
  import is an open question (§6)** — answer it with a throwaway copy before the real mailbox is near it.
- **Egress verification before real mail**, the same discipline that gated the extractor. The method
  differs for a Docker stack: bring it up, import a **synthetic** mailbox, then re-run with the compose
  network set `internal: true` (or egress blocked) and confirm import and search still work. A stack
  that only functions with outbound access has not earned the family's mail.

---

## 5. Maturity — the honest reservation

- **2.2k stars, but only 204 commits and 171 open issues** (plus 29 open PRs). That issue-to-commit ratio
  is high; it reads as a young project with more demand than throughput.
- **Legal holds are marked TBD** — irrelevant to us (we are not doing compliance retention), but a
  signal that advertised compliance features are not all implemented.
- **AGPL-3.0**, self-hosted, no cloud dependency for our use case. No licensing concern here.

**Why the immaturity is tolerable in this specific case**, using the same test applied to xberg: the
mailbox master is untouched and irreplaceable-safe, the app writes only to its own Docker volumes, and
removal is `docker compose down` plus deleting a directory. **The failure mode is wasted effort, not lost
data** — provided §4's copy-not-master rule holds. That is the line that makes it acceptable, and it is
the same line that made the Paperless *ingest* unacceptable to take on right now.

---

## 6. Open questions — verify at deploy, before real mail

1. **Does PST import handle a 1.67 GB mailbox** on this hardware, and what does it peak at? **[unmeasured]**
2. **What does it do to the source file** after import — read only, move, or delete? Test with a
   throwaway copy first. This is the one that could hurt.
3. **Real RAM at rest vs during ingest** — the "4 GB" figure is upstream's floor, not a measurement.
   Meilisearch in particular is memory-mapped and grows with the index. **[unmeasured]**
4. **Does the stack function with egress blocked** (§4.2)?
5. **Is Tika actually required** for our path, or only for attachment extraction we could skip? Dropping
   a JVM would materially change the footprint. **[unmeasured]**
6. **Does search expose the facets that matter** — from/to, date range, has-attachment — or only
   full-text? The entire value case in §1 depends on this. Check on the public demo before installing.

Question 6 is cheap and decisive: **it can be answered on `demo.openarchiver.com` in ten minutes, with no
install and no data.** That should happen first.

---

## 7. Recommended plan

| Step | What | Gate |
|---|---|---|
| **0** | Answer Q6 on the public demo — do the mail facets exist? | ← start here, costs nothing |
| **1** | Write `archive-openarchiver-setup.sh` to repo convention: pinned images, loopback-bound, Caddy route, `MEILI_NO_ANALYTICS=true`, no cloud connectors, own volumes on the OS disk | Q6 says yes |
| **2** | Stand it up and import a **synthetic** mailbox; run the egress test (§4.2); confirm the source file is untouched (checksum before == after) | — |
| **3** | Import a **COPY** of `Outlook MKH.pst`; measure RAM and ingest time | §2 passes clean |
| **4** | Run the actual hunt: Ratliff · "Northern Trust" · March 2009 · has-attachment · Hartigan Kenilworth · "December 5" | — |
| **5** | Decide: does it stay resident, or was it a one-off instrument? | honest answer |

Steps 0–2 involve no family data at all. Step 3 is the first that does, and only from a copy.

---

## 8. Sources

- LogicLabs-OU/OpenArchiver README — purpose, ingestion sources (IMAP, Google Workspace, M365, **PST,
  Mbox, zipped .eml**), stack (PostgreSQL, Meilisearch, BullMQ/Redis-Valkey, S3 or local), Docker Compose
  deployment, **≥4 GB RAM** stated requirement
- LogicLabs-OU/OpenArchiver `docker-compose.yml` — services: app (:3000), `postgres:17-alpine`,
  `valkey:8-alpine`, `meilisearch:v1.38`, **`tika:3.2.2.0-full`**; four volumes; `.env`-supplied secrets
- GitHub repo metadata — 2.2k stars, 204 commits, 171 open issues, 29 PRs, **AGPL-3.0**, legal holds TBD
- Meilisearch documentation & specification 0034 (telemetry policies) — **analytics collected by default
  from all instances that do not opt out**; disabled via `MEILI_NO_ANALYTICS` / `--no-analytics`
- This repo: `docs/RAG-EXTRACTION-XBERG-ASSESSMENT.md` §2a (measured 10,659 MiB MemAvailable; kreuzberg
  v4 reads EML/MSG but not PST), `docs/PAPERLESS-DOCUMENT-VIEW.md` (the copy-not-master ingest rule)
