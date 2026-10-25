# Design Decisions

Each entry below records a decision, the alternatives considered, and the
specific reason this build chose one over the others. These are the
conversations I would expect to have with a reviewer.

---

## D1 — Member identity: composite surrogate key, not raw source ID

**Decision:** The canonical key is `MEMBER_SK = <SOURCE_COUNTRY>-<SOURCE_ID>`
(e.g. `'USA-3'`, `'AUS-1'`, `'IND-9'`).

**Why.** The three sample source files all contain `ID` values `1, 2, 3` —
clear evidence that the integer IDs are source-local, not globally unique.
Treating them as global would merge different people into a single mart row.

**Alternatives considered:**
- **Treat `SOURCE_ID` as globally unique.** Rejected until the sources agree
  to a shared ID space; a contract change, not an engineering fix.
- **Fuzzy match on `(name, DOB)`.** Done, but as a *detection* via
  `MART.V_POTENTIAL_DUPLICATES`, not as auto-merge. See D4.

**Consequence.** Same person who legitimately moved from USA to India
appears as two rows (`USA-3` and `IND-9`). Covered by D4.

---

## D2 — One raw table per source, one canonical staging table

**Decision:** Three raw tables (`RAW_USA_MEMBERS`, `RAW_AUS_MEMBERS`,
`RAW_IND_MEMBERS`) that mirror each source's schema exactly, plus a single
`STG_MEMBER` canonical schema that all three normalize into.

**Why.**
- Each source can change its own schema (add a column, rename one) without
  breaking the other two or the mart.
- Debugging a bad row is one `SELECT` against the raw table that owns it.
- The normalization step is where source-specific logic lives (date formats,
  tier mappings, column renames) — one procedure per source, so logic is
  colocated with the source it serves.

**Alternatives:**
- **Single raw table with VARIANT.** Simpler to add new sources, but hides
  contract drift — a renamed column just shows up as a different JSON key
  and silently nulls the normalized attribute.

---

## D3 — Dates: `TRY_TO_DATE` per source format, with `LPAD` recovery for USA

**Decision:**
- USA: `TRY_TO_DATE(LPAD(TRIM(x), 8, '0'), 'MMDDYYYY')`.
- AUS: `TRY_TO_DATE(TRIM(x), 'YYYY-MM-DD')`.
- IND: `TRY_TO_DATE(TRIM(x), 'MM/DD/YYYY')`.

**Why.** USA sends `6152022` (June 15, 2022) — the leading `0` was stripped
upstream. `LPAD` recovers it; `TRY_TO_DATE` returns `NULL` on any value that
still won't parse, which is caught by the per-source DQ rule
(`ERR_ENROLLMENT_UNPARSEABLE`). AUS sends ISO format, so `2021-13-13` fails
parsing cleanly (month 13 is invalid) and the row is quarantined. IND sends
US-style with single-digit days/months — Snowflake's `MM/DD/YYYY` tolerates
both single and double digits.

**Alternative:** A single generic parser driven by a config table. Worth it
at 30+ sources; overkill for 3.

---

## D4 — Cross-source identity: detect, do not auto-merge

**Decision:** Members with matching `(NAME, DOB)` across two country marts
are surfaced via `MART.V_POTENTIAL_DUPLICATES` and the name-only variant for
sources that don't carry DOB. They are **not** auto-merged by the pipeline.

**Why.** Auto-merging is dangerous without a master data management (MDM)
layer:
- Common names collide (two different "Mike"s).
- Sources that don't send DOB (USA in this build) can't be matched reliably.
- An incorrect merge is irreversible without full history, which this build
  doesn't maintain (see D7).

**Instead:** DQ rule `X01` counts potential duplicates per batch; ops reviews
and either confirms a merge via a stewardship workflow or marks the pair as
distinct. The decision is deliberately kept out of the automated path.

---

## D5 — Per-country mart tables, as the brief requires

**Decision:** `MART.MEMBER_USA`, `MART.MEMBER_IND`, `MART.MEMBER_AUS`,
auto-extended by `SP_DISPATCH_MEMBERS` for any new country code that appears.

**Why.** The brief explicitly asks for this ("All members related to India
will go to Table_India…").

**What I would push back with in a real review:** a single `MEMBER` table
clustered on `(COUNTRY_ISO3, …)` plus one secure view per country gives the
same per-country access pattern with half the operational surface area:
- One DDL to evolve, not N.
- No `_LATEST`-join-then-dispatch dance for country migrations — just an
  `UPDATE … SET COUNTRY_ISO3 = …`.
- Snowflake's micro-partitions on the clustering key already give per-country
  pruning, so query performance is comparable.

That said, the brief is unambiguous, so the delivered build honours it.

---

## D6 — "Latest record wins" via `MERGE` on `MEMBER_SK`, tie-broken by `LOAD_TS`

**Decision:** `SP_DISPATCH_MEMBERS` first collapses the staging batch to one
row per `MEMBER_SK` using `ROW_NUMBER()` ordered by `LOAD_TS DESC,
SOURCE_FILE_ROW_NUMBER DESC`, then does a per-country `MERGE` with
`WHEN MATCHED AND s.LOAD_TS >= t.LAST_UPDATED_TS THEN UPDATE SET …`.

**Why.** This is a classic Type-1 SCD upsert and handles the two cases the
brief cares about:
- **Same source re-sends a member with updated attributes** → MERGE updates
  the row in place.
- **Member physically moves countries** (same `MEMBER_SK`, different
  `COUNTRY_ISO3`) → detected before the MERGE, deleted from the old country,
  audited in `META.MEMBER_MOVE_AUDIT`, re-inserted into the new.

**Alternative:** Type-2 SCD with a `_HIST` table. Easy to add later; not
required by the brief, and adds a lot of surface area for a problem the
business hasn't asked us to solve.

---

## D7 — Declarative DQ rules, not hardcoded CHECK constraints

**Decision:** All DQ checks live as rows in `DQ.DQ_RULES`
(`id, category, severity, description, check_sql`). `SP_RUN_DQ` iterates them
and writes `DQ.DQ_METRICS`.

**Why.**
- Adding or tuning a rule is one `INSERT` — no deploy, no code review.
- Rules are discoverable (`SELECT * FROM DQ_RULES`) and the full history of
  rule executions is queryable (`SELECT * FROM DQ_METRICS`).
- CHECK constraints would reject rows at write time; we want to *land* the
  bad row (so ops can see it) and *tag* it as quarantined, which is more
  observable.

**Severity model.**
- `FAIL`: row-level issues that quarantine the row (missing mandatory field,
  invalid date, business-rule violation).
- `WARN`: observable issues that pass the row through (unknown tier, missing
  DOB from a source that doesn't carry it, volume drift).

---

## D8 — Redemption join: fan-out acknowledged, source country required for 1:1

**Decision:** `MART.REDEMPTION` joins to `MART.V_MEMBER_ALL` on `SOURCE_ID`.
Because `SOURCE_ID` is not globally unique, a redemption with
`member_id='1'` matches `USA-1`, `AUS-1`, and `IND-1` — fan-out = 3.

**Why we didn't fix this now.** The sample JSON feed doesn't carry a source
country field. Fixing it needs either:
- The partner airline adds `source_country` to the JSON payload (contract
  change), or
- The feed file naming carries the country (e.g. `redemptions_USA_20240115.json`)
  and we parse it from `METADATA$FILENAME`.

Both are preferable to guessing. The code is written so this becomes a
one-column add to `MART.REDEMPTION` and a one-condition add to the join.

**Interim mitigation.** DQ rule `X02` counts orphan redemptions (no matching
member), and the join query in `sql/demo/03_verify_results.sql` makes the
fan-out explicit so a reviewer sees it immediately.

---

## D9 — No Python; everything is Snowflake-native

**Decision:** Zero Python. All transforms are Snowflake Scripting procedures
(`LANGUAGE SQL`), not Snowpark Python UDFs.

**Why.**
- Operational simplicity: no interpreter version pin, no venv, no CI job to
  deploy a UDF.
- Performance: SQL procedures run inside the warehouse; Python UDFs incur
  a per-row serialization cost that matters at billion-row scale.
- Portability: the same SQL ports to Databricks, BigQuery, or even DuckDB
  (for local testing) with minimal change — Python UDFs don't.

**When I'd break this rule:** Fuzzy name matching for cross-source identity
(see D4) is a reasonable Snowpark Python UDF because `jellyfish` /
`rapidfuzz` are hard to express in pure SQL. Deferred until the business
commits to auto-merging.
