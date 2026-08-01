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

- **Still 0.x.** Latest release is **v0.5.2** (27 July 2026, the day of this assessment). A pre-1.0
  version number is the project's own statement that breaking changes are expected — which is exactly
  why the pin is recorded and never floats, and why this is a time-boxed evaluation.
- **2.2k stars, but only 204 commits and 171 open issues** (plus 29 open PRs). That issue-to-commit ratio
  is high; it reads as a young project with more demand than throughput.
- There is also a commercial **`-enterprise`** image line in the registry alongside the open tags — worth
  knowing, though nothing we use depends on it.
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
2. ~~**What does it do to the source file**~~ — **ANSWERED, twice over.** Gate 4 measured it: after
   a real import the staged file was byte-identical and still present. And the UI shows *why* the
   question mattered — the ingestion dialog has a **"Preserve Original File"** checkbox. Unchecked,
   the app deletes or moves its source after importing.
   **Two consequences.** Every import must have that box checked. And the read-only `import/` mount
   earns its place: with the box unchecked the deletion would **fail loudly against a read-only
   filesystem** rather than quietly destroying a staged copy. A defence that was speculative when it
   was designed turns out to guard a switch that sits one click away — defaulted in the operator's
   favour, but trivially turned off.
   The same dialog offers **"Merge into existing ingestion"**, plausibly the cross-source
   deduplication mechanism — see §7b.
3. **Real RAM at rest vs during ingest** — the "4 GB" figure is upstream's floor, not a measurement.
   Meilisearch in particular is memory-mapped and grows with the index. **[unmeasured]**
4. **Does the stack function with egress blocked** (§4.2)?
5. **Is Tika actually required** for our path, or only for attachment extraction we could skip? Dropping
   a JVM would materially change the footprint. **[unmeasured]**
6. ~~**Does search expose the facets that matter**~~ — **ANSWERED, see §6a.** Yes, all of them, plus one
   we did not ask for.

---

## 6a. Q6 ANSWERED from the source — the facets exist, and one is better than hoped

Answered from `docs/user-guides/searching.md` and the code tree rather than by clicking the public demo.
The documentation specifies the search **API**, which is decisive where a demo UI is only suggestive —
and it costs nobody ten minutes of clicking.

| Facet we needed | Present |
|---|---|
| From (sender) | ✅ plus **exclude sender** |
| To / Cc / Bcc | ✅ plus **exclude recipient**, and per-mailbox filtering |
| Date range | ✅ inclusive bounds, interpreted UTC |
| Has attachment | ✅ with **or without** |
| Ingestion source | ✅ limit or exclude |
| Sort | ✅ newest / oldest / relevance |

**The facet we did not ask for, and the most valuable of the lot:** `searchIn` scopes matching to
**Subject · Body · Attachment name · Attachment CONTENT · Sender · Recipients**. Attachment *content* is
indexed and separately searchable — the text inside a faxed scan attached to an email is a first-class
search target. That is the exact object of the hunt.

It is a REST endpoint, so the hunt can be **scripted and reproducible** rather than clicked:

```
GET /v1/search?keywords=Ratliff&dateFrom=2009-01-01&dateTo=2009-12-31
    &searchIn=attachment_name,attachment_content,subject,body
```

Filters combine with AND. The tree also carries a dedicated **`PSTConnector.ts`** alongside the
EML/Mbox/IMAP/Google/Microsoft connectors — PST is a first-class path, not an afterthought.

### The new dependency this exposes

`attachment_content` is only as good as the attachment text extraction behind it — and **our estate
attachments are scanned faxes, which are images**. Their text exists only if **Tika performs OCR**. That
is presumably why the compose pins `tika:3.2.2.0-full` (the full image bundles OCR) rather than the
minimal one.

**So this becomes a deploy-time gate, not an assumption** — the same lesson as the extractor, where the
egress verdict came back clean while OCR stayed unproven until it was tested on a real scan:

> Import a synthetic mailbox containing **an image-only attachment with known text**, then search for a
> word that appears *only inside that image*. If it does not come back, `attachment_content` is blind to
> precisely the documents we are looking for, and the value case in §1 collapses to metadata filtering.

---

## 7. Recommended plan

| Step | What | Gate |
|---|---|---|
| ~~**0**~~ | ~~Answer Q6~~ — **DONE (§6a): every facet present, plus attachment-content search** | ✅ passed |
| ~~**1**~~ | ~~Write `archive-openarchiver-setup.sh`~~ — **DONE (§7a), sandbox-tested, CI-gated** | ✅ |
| **2** | Stand it up and import a **synthetic** mailbox; run the egress test (§4.2); confirm the source file is untouched (checksum before == after); **and prove Tika OCRs an image-only attachment** (§6a) | — |
| **3** | Import a **COPY** of `Outlook MKH.pst`; measure RAM and ingest time | §2 passes clean |
| **4** | Run the actual hunt: Ratliff · "Northern Trust" · March 2009 · has-attachment · Hartigan Kenilworth · "December 5" | — |
| **5** | Decide: does it stay resident, or was it a one-off instrument? | honest answer |

Steps 0–2 involve no family data at all. Step 3 is the first that does, and only from a copy.

---

## 7a. What was built (2026-07-27) — and the six things upstream's compose gets wrong for us

`archive-openarchiver-setup.sh` deploys **pinned v0.5.2**, and deliberately diverges from upstream's
`docker-compose.yml` in six places. Each is a real defect *for this box*, not a style preference:

| # | Upstream ships | We ship | Why |
|---|---|---|---|
| 1 | no `MEILI_NO_ANALYTICS` | `MEILI_NO_ANALYTICS: "true"` on the Meilisearch service | telemetry is on by default (§4.1) |
| 2 | `ports: '3000:3000'` — every interface | `127.0.0.1:3010:3000` | Caddy fronts it; 3000 is already Docmost's |
| 3 | `container_name: postgres` / `valkey` / `meilisearch` / `tika` | `openarchiver-*` | those are **global** Docker names; bare `postgres` would collide with any other stack |
| 4 | `POSTGRES_PASSWORD:-password`, `MEILI_MASTER_KEY:-aSampleMasterKey` | generated, reused on re-run | upstream's defaults are examples, not secrets |
| 5 | no import path | `$APP_DIR/import` mounted **`:ro`**, archive never mounted | the app cannot alter or delete even our copies; masters are unreachable from any container |
| 6 | deletion available | `ENABLE_DELETION=false` | nothing in this archive gets deleted by an app |

**Enforced by CI, not by good intentions.** `ci/validate-compose.py` now checks this stack with
`archive=None, loopback=True`, so a future edit that mounts `/srv/archive` into a container, or
publishes a port on all interfaces, **fails the build**.

### Sandbox-tested before it goes near the box

Against stub `docker`/`sudo`/`git`, on scratch directories:

- all six hardening properties present in the written compose; `.env` is `0600`
- **a re-run reuses all six secrets** — this is the one that matters most: rotating `ENCRYPTION_KEY`
  or `STORAGE_ENCRYPTION_KEY` would make already-stored mail permanently unreadable
- **no version drift on re-run** (stays on the deployed tag); `--upgrade` advances it and still keeps
  the encryption keys

### `openarchiver/verify-openarchiver.sh` — four gates, before any family mail

| Gate | Proves |
|---|---|
| `harden` | reads the **running** config, not the file we wrote: telemetry off, loopback-only, archive not mounted, import read-only, deletion off, no cloud credentials, no upstream default secrets |
| `ocr` | **the deciding gate** — builds a synthetic mailbox whose only content of interest is the repo's committed image-only PDF, then looks for a token that exists *nowhere in plaintext* |
| `egress` | applies `internal: true` to the project network, **proves from inside that the outside is unreachable**, then confirms the app still serves |
| `source` | sha256 before == after, and the file still exists — upstream's behaviour toward its source is undocumented |

Also tested in **both** directions: against a deliberately unsafe config (telemetry missing, port on
`0.0.0.0`, archive mounted writable, import writable, cloud credentials, upstream default secrets) the
harden gate catches **all six** and exits non-zero; and a tampered source file is caught by `source`.

### A flaw found in my own egress gate, before it could certify anything

The first version detached the containers from the shared `memorial` bridge while keeping the project's
own bridge so the services could still talk to each other. **Every Docker bridge network provides
outbound NAT**, so egress was never actually cut — the gate would have reported a clean offline result
for a stack that still had full internet access. Caught on review of the deploy output, before it ran.

The gate now applies `internal: true` to the project network (which removes its gateway), disconnects
from `memorial` as well, and — the part that matters — **proves the cut from inside the network** with a
throwaway probe container testing both a raw IP and DNS. If egress is still open, the gate **fails**
rather than warning: a cut we cannot demonstrate is not evidence. It also refuses to proceed if the
baseline shows egress was *already* closed, since then nothing has been demonstrated either way. The
temporary override is removed by a trap, so an interrupted run cannot leave the stack detached.

Tested three ways: a real cut with a surviving app (PASS), a cut that silently fails to take — the
original bug — (FAIL, refuses to certify), and an app that dies without egress (FAIL). The override is
cleaned up in every case.

### ✅ GATE 2 PASSED on archive-pc — the value case is confirmed

Searching `OCRWILLMARKER` returned **1 result in 0.001s**, matched **inside the attachment**
(`scanned.pdf`), with the OCR'd text shown as context:

> *"…grants power of attorney. It is to be filed for probate. Document reference:* **OCRWILLMARKER**
> *LAST WILL AND TESTAMENT OF JANE ARCHIVE DOE…"*

That token appears nowhere in the mbox's plaintext — not in a header, subject or body. The only path
from the file to the index was **Tika OCR'ing an image-only PDF attachment**. So:

- attachment-content search genuinely sees inside scans, which is the entire reason for deploying this;
- the result view names the attachment the hit came from and shows surrounding text, so a hit is
  immediately identifiable rather than a bare filename;
- the message's 2009 date parsed correctly, so date-range filtering will work on real correspondence.

**Every faxed scan in MKH's mailbox is therefore reachable by content**, which is exactly the class of
document — `FaxImage.tif`, `SKM_*.pdf`, bare-numbered attachments — that has defeated filename and
plain full-text search for months.

**Status: gates 1, 2 and 3 pass.** Gate 4 (source integrity) is meaningful only around a real import.

### Closing the last gap before real mail: `verify-openarchiver.sh staged`

Gate 4 knows the *synthetic* fixture by name, which is no use for the real mailbox. The new `staged`
gate reads `import/PROVENANCE.tsv` and re-verifies **every** file `stage-mailbox.sh` has staged: still
present, still byte-identical to what was copied. On a mismatch it prints the master's path so the copy
can be re-made from a source that was never touched. Tested three ways — all intact (PASS), one file
modified (FAIL with both checksums), one file consumed (FAIL naming it as moved-or-consumed).

### The install reported success while the backend was dead

The stack came up, the hardening verified, gates 1 and 3 passed — and the UI still showed only a
sign-in page with no way to create an account. The cause was in the `.env` **I** wrote:

```
Error: Invalid STORAGE_TYPE: undefined
```

`STORAGE_TYPE` is required. The backend validates its config at startup and exits on the first bad
value, which killed the API and all three workers (ingestion, indexing, sync-scheduler). The frontend
kept serving, so the app *looked* healthy: it just couldn't ask its own API "is there an admin yet?",
and fell back to the login page. The database was fine throughout — all 22 tables, migrations clean.

Root cause on my side: I built the `.env` from a **summary** of upstream's `.env.example` rather than
the file itself, and dropped seven variables. `STORAGE_TYPE` was fatal; `BODY_SIZE_LIMIT` (upstream
sets 100M, SvelteKit defaults to 512K) would have surfaced later as mysterious upload failures.

**The deeper fault was that the setup script announced "Done — Open Archiver is starting" in that
state.** It now waits for the backend to listen on :4000, and if it never does, prints the filtered
backend errors from the log and **exits non-zero** instead of declaring success. Same principle the
verification gates already follow: do not report a property you have not observed.

Tested both ways against a stub: a healthy backend reaches "Done", and one that never listens fails
loudly with the diagnosis and exit 1.

### Second correction to the same gate, from the first real run

On the box, gate 3 proved the cut (raw IP and DNS both unreachable from inside) and then reported the
app dead — a **false failure caused by the test method**. `internal: true` does not only remove the
network's gateway; it also stops Docker publishing the container's port to the host. So a host-side
`curl` returning `000` after the cut is the *expected consequence of cutting*, not evidence that the
app broke. The gate was conflating "the app died" with "the host can no longer reach a port that is
deliberately no longer published".

Fixed by asking the right observer: the app is now probed **from a sibling container on the same
network**, where it is still addressable while egress is genuinely gone. Both questions stay separate,
and the check keeps its teeth — verified against a stub where the app is genuinely dead in-network
(still FAILS) and one where it is healthy while the host port is unreachable (now PASSES).

### Third correction: the gate was testing the wrong container

The first passing run on the box printed no "detached from the shared 'memorial' bridge" line. That
mattered: the egress probe ran in a **sibling** container on the project network, so it proved *that
network* had no route out — while the app container also joins the shared `memorial` bridge and could
have retained egress through it. The gate would have certified "offline" on the strength of a probe
that was not the thing being certified.

Now it (a) detaches `openarchiver-app` from `memorial` and **verifies the detachment**, failing if the
container is still attached to any network outside the cut, and (b) asks **the app container itself**
whether it can open an outbound TCP connection, using the Node runtime that is guaranteed present in
that image. The network-level probe is retained as a secondary check rather than the primary evidence.

Tested three ways: a clean cut (PASS), the app still attached to `memorial` after the cut (FAIL), and a
cut network where the app can nevertheless still reach the internet (FAIL).

**Result on archive-pc: gates 1 and 3 PASS.** Hardening is live on the running stack, and the app keeps
serving with egress genuinely cut.

The synthetic mailbox was validated by parsing it back with Python's `mailbox` module: two messages, the
attachment byte-identical to the fixture, and — critically — **the token `OCRWILLMARKER` appears nowhere
in the file's plaintext**. A search hit for it can therefore only have come from OCR. That is what makes
gate 2 a real test rather than a formality.

---

## 7a. MEASURED: the first real import — 2026-08-01

`archive.pst` (63 MB, the July 2013 auto-archive) imported with **0 failures**:

| Metric | Measured | Replaces |
|---|---|---|
| Wall clock | **36 s** (`process-mailbox` 12:25:46 → 12:26:22) | "unknown until measured" |
| Messages | **610** → ~17 messages/sec | — |
| Throughput | **~1.75 MB/s** of PST | — |
| Storage used | **69.52 MB total** for 63 MB of PST + the 2 synthetic messages → **~1.1×** | my 2–3× estimate |

**Both of my estimates in §7b were wrong, in the same direction — too pessimistic.**

- **Storage: ~1.1×, not 2–3×.** So all 61.4 GiB of distinct mailboxes lands at roughly **68 GiB**, not
  120–185 GiB. Against 508 GiB free, that is comfortable rather than tight.
- **Time: ~10 hours for everything**, extrapolating 1.75 MB/s across 61.4 GiB — an overnight job, not
  the days-to-weeks I warned about.

**The caveat that could still make this wrong.** `archive.pst` is an *auto-archive of old mail* and
appears text-heavy. OCR is the expensive operation: the RAG bench measured **1–3 s per scanned page**,
against ~17 messages/sec here. A mailbox thick with faxed scans could run an order of magnitude slower.
So treat ~10 hours as the **floor**, and re-measure on the first attachment-heavy mailbox (`Law.biz.pst`
or `historical.pst`) before assuming the whole corpus fits an overnight window.

Even at 10× that floor it is a long weekend, not a month — so **importing all 75 is affordable**, and the
remaining question is purely whether duplicates make it *useful* (§7b).

## 7c. MEASURED: no cross-source dedup — and why "newest only" is unsafe

The experiment ran on two 63 MB auto-archives, July 2013 (A) and February 2018 (B):

| | |
|---|---|
| After A | 612 messages (610 + 2 synthetic) |
| After B | 1,222 — **B added all 610** |
| Messages now stored twice | **330**, worst case 2 copies |

**Open Archiver does not deduplicate across separate ingestion sources.** Two overlapping mailboxes
produce two copies of every shared message.

**But the more consequential number is 330.** A held 610, B held 610, and only 330 are shared — so
**280 messages exist ONLY in the 2013 file.** The 2018 auto-archive dropped them, presumably pruned or
re-archived elsewhere. Across a single pair, "just take the newest generation" would silently lose
**46% of the older mailbox's content.**

That kills the fallback this document previously recommended. For mail from **2009** — older than every
backup generation we hold — the oldest archives are the likeliest survivors, so the pruning that makes
newer files cleaner is exactly what removes the evidence we want.

### Which reframes the duplicate problem

The objection to duplicates was **family usability** — and that objection stands, for a browsing tool.
But it does not apply to the job in front of us:

- **This instance's purpose right now is a hunt**, not daily browsing. When searching for one faxed
  will, seeing the hit twice costs nothing; missing it entirely costs everything.
- **The family's browsing tools are copyparty and Immich**, not this. Nobody is being handed a
  duplicate-ridden mail UI as their day-to-day interface.
- **Completeness is the standing rule** of this archive; duplication is cosmetic, loss is not.
- **It is affordable** (§7a): ~68 GiB and an overnight-to-weekend run.

**Revised recommendation: import all 75 distinct mailboxes, accepting duplication**, unless the merge
test below removes it for free. Deduplicating the *view* later is a solvable problem; recovering a
message that was never imported is not.

### The merge test, which needs no clean slate

`dedup-experiment.sh check` reads the current counts, then: re-import an already-imported mailbox with
**"Merge into existing ingestion" CHECKED**, and run `check` again. If the count barely moves, merge
deduplicates and we get completeness *and* cleanliness. If it jumps by the mailbox's full message
count, duplication is simply the price, and §7c says pay it.

## 7b. Deciding whether to import all 75 mailboxes

The archive holds **102 PST files, 74.4 GiB → 75 distinct, 61.4 GiB** (`inventory-mailboxes.sh`).
Wanting all of them is reasonable: the standing rule is keep-and-index-everything, and missing the
will out of frugality is the worse failure. The costs:

| | |
|---|---|
| Disk | store is ~2–3× ingested bytes → **120–185 GiB [unmeasured]** against **508 GiB free** on NVMe |
| Staging | one file at a time, copy removed after a verified import → **~2.1 GiB peak**, not 61 |
| Time | **unknown** until the first real import is measured |
| **Usability** | **the deciding factor — below** |

Those 75 files are backup **generations** of overlapping mailboxes, not 75 distinct mailboxes. So it
hinges on whether the app deduplicates messages across sources: dedupe and you get completeness;
don't, and the family gets ten copies of every email — reproducing, inside the tool meant to fix it,
exactly the duplicate clutter that motivated the project.

`dedup-experiment.sh` settles it with two 63 MB archive mailboxes from different backup dates
(different SHA-256, overlapping content). It measures from the database and asks the question
directly — *is any single message now present more than once?* — rather than inferring from row
deltas, which cannot distinguish "deduplicated" from "B had little new content". The
message-identity column is discovered from `information_schema`, not guessed.

If the answer is no, the fallback is not to abandon completeness immediately: re-test with **"Merge
into existing ingestion"** checked, since that option plausibly exists for exactly this case.

---

## 8. Sources

- LogicLabs-OU/OpenArchiver `docs/user-guides/searching.md` — from/exclude-sender, to/Cc/Bcc, mailboxes,
  inclusive UTC date range, with/without attachments, source include-exclude, sort, and **`searchIn`
  scoping to subject · body · attachment_name · attachment_content · sender · recipients**; REST API
- LogicLabs-OU/OpenArchiver source tree — `services/ingestion-connectors/PSTConnector.ts` (also EML,
  Mbox, Imap, GoogleWorkspace, Microsoft); `services/SearchService.ts`, `IndexingService.ts`,
  `helpers/meiliFilter.ts`
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
