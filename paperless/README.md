# `paperless/` — the curated **Documents view** for the family

Paperless-ngx is already deployed by `archive-paperless-setup.sh` and already routed at
`docs.<domain>`. What lives here is the work that makes it *useful*: deciding **which** documents the
family sees, feeding it **copies** of them safely, and keeping the provenance trail back to the drive
each one was recovered from.

**Read first:** [`../docs/PAPERLESS-DOCUMENT-VIEW.md`](../docs/PAPERLESS-DOCUMENT-VIEW.md) — the
feasibility and design note (resource budget, corpus selection, ingest design, tag taxonomy, phasing).

---

## The one rule that governs everything in this directory

> **Paperless DELETES files from its consume folder once it has consumed them.**

So a master is **never** placed in, moved to, symlinked into, or bind-mounted as `consume/`. Every
ingest path here copies to a staging area under `/srv/archive/.derived/paperless-feed/` first, verifies
`sha256(copy) == sha256(master)`, and feeds only the copy. Masters are opened read-only, and each tool
is checksum-proven non-destructive (master tree identical before == after) before it goes near real data.

---

## What's here now

| Script | What it does | Writes? |
|---|---|---|
| `probe-paperless-state.sh` | **Read-only census.** Install state + whether the v2→v3 database hazard is armed; RAM headroom with Immich running; disk; a document-candidate census by type and area; a cheap duplicate upper bound; what we already OCR'd. | **Nothing.** Checksum-proven. |

```bash
bash paperless/probe-paperless-state.sh              # full census (the size pass takes a few minutes)
SKIP_SIZES=1 bash paperless/probe-paperless-state.sh # counts only, fast
```

Paste the output back — it decides Phase 1 (design note §8): whether Tier A is 400 documents or 40,000,
and how much RAM the OCR worker may be given.

## What is deliberately *not* here yet

The **selection → copy → verify → feed** pipeline. Its batch sizes, its scan-vs-photo filter and its
tag mapping all depend on numbers the probe hasn't returned yet, and building it before then would be
guessing. It lands after the probe output and your go-ahead — dry-run by default, sandbox-tested
against stub data, idempotent, writing only under `.derived/paperless-feed/`.

## Related safety work (already landed)

`archive-paperless-setup.sh` can no longer drift into the Paperless v3 migration unattended: a fresh
install takes a recorded pin, a re-run keeps the deployed tag, and crossing a major version — or
changing the database image / pgdata mount — is refused unless you pass `--upgrade-major` **and** an
export exists. `ci/paperless-upgrade-guard.sh` proves those refusals refuse (script exits non-zero,
`docker compose up -d` never runs, live compose byte-identical afterwards).
