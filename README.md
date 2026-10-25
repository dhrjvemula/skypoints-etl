# SkyPoints Loyalty — Member & Redemption ETL

A production-shaped Snowflake pipeline that ingests member profile data from
three heterogeneous country source systems (USA, AUS, IND) plus a JSON
redemption feed, and lands them in per-country mart tables with full data
quality tracking.

**Stack:** 100% Snowflake SQL + Snowflake Scripting. No Python, no external
orchestrator required (Snowflake Streams + Tasks drive continuous ingestion).

---

## Deliverables ↔ Files

| Brief deliverable | Where it lives |
|---|---|
| 1. DDL — raw, staging, per-country target | [`sql/01_setup.sql`](sql/01_setup.sql), [`sql/02_raw_tables.sql`](sql/02_raw_tables.sql), [`sql/03_staging_tables.sql`](sql/03_staging_tables.sql), [`sql/04_mart_tables.sql`](sql/04_mart_tables.sql) |
| 2. Staging load with derived `AGE` and `STALE_MEMBER` | [`sql/05_normalize_procedures.sql`](sql/05_normalize_procedures.sql) |
| 3. Transform logic + "latest record wins" per country | [`sql/06_dispatch_procedure.sql`](sql/06_dispatch_procedure.sql) |
| 4. JSON redemption parse + join to profile | [`sql/07_redemption_flatten.sql`](sql/07_redemption_flatten.sql) |
| 5. Data validations (mandatory, uniqueness, business, cross-source) | [`sql/08_dq_framework.sql`](sql/08_dq_framework.sql) |
| 6. Live demo | [`sql/demo/`](sql/demo/) |

Architecture, scale notes, and the full decision log live in [`docs/`](docs/).

---

## Architecture at a glance

```
   USA CSV           AUS CSV           IND CSV         Redemptions JSON
      │                 │                 │                   │
      ▼                 ▼                 ▼                   ▼
RAW_USA_MEMBERS   RAW_AUS_MEMBERS   RAW_IND_MEMBERS   RAW_REDEMPTION_FEED
      │                 │                 │                   │
      │ SP_NORMALIZE_   │ SP_NORMALIZE_   │ SP_NORMALIZE_     │ SP_NORMALIZE_
      │   USA           │   AUS           │   IND             │   REDEMPTIONS
      ▼                 ▼                 ▼                   ▼
                   STG_MEMBER (canonical, with AGE + STALE_MEMBER)
                        │                                     STG_REDEMPTION
                        │ SP_DISPATCH_MEMBERS                      │
                        │   (latest wins + country-move audit)     │ SP_MERGE_
                        ▼                                          │   REDEMPTIONS
      MART.MEMBER_USA / MEMBER_IND / MEMBER_AUS / ...              ▼
                        │                                      MART.REDEMPTION
                        └──────────── join via SOURCE_ID ──────────┘

           DQ.DQ_RULES → SP_RUN_DQ → DQ.DQ_METRICS
                                   → DQ.QUARANTINE_*
```

---

## How to run

### Option A — Snowflake trial account (Snowsight)

1. Open [Snowsight](https://app.snowflake.com) → **Projects → Worksheets**.
2. Run each file under `sql/` **in numeric order**:
   `01_setup.sql` → `02_raw_tables.sql` → ... → `09_streams_tasks.sql`.
3. Load the demo data and run the pipeline:
   `sql/demo/01_load_sample_data.sql` → `02_run_pipeline.sql` → `03_verify_results.sql`.
4. For the latest-wins story: `sql/demo/04_latest_wins_demo.sql`.

### Option B — SnowSQL CLI

```bash
snowsql -a <account> -u <user> -f sql/01_setup.sql
snowsql -a <account> -u <user> -f sql/02_raw_tables.sql
# ... (through sql/09_streams_tasks.sql)
snowsql -a <account> -u <user> -f sql/demo/01_load_sample_data.sql
snowsql -a <account> -u <user> -f sql/demo/02_run_pipeline.sql
snowsql -a <account> -u <user> -f sql/demo/03_verify_results.sql
```

Everything is idempotent — re-running a file is safe.

---

## What the demo proves

Running `demo/02_run_pipeline.sql` against the sample data produces:

- **`MEMBER_USA` has 3 rows, `MEMBER_IND` has 3 rows, `MEMBER_AUS` has 2 rows.**
  Jonnathan (AUS-2) is quarantined because `2021-13-13` is not a valid date.
- **`QUARANTINE_MEMBER`** shows the one quarantined row with
  `['ERR_ENROLLMENT_INVALID_DATE']`.
- **`MART.REDEMPTION`** has 3 transactions flattened from 2 JSON documents.
- **`V_POTENTIAL_DUPLICATES_NAME_ONLY`** flags that "Mike" exists in both USA
  and AUS country tables — the cross-source identity resolution gap discussed
  in [`docs/DECISIONS.md`](docs/DECISIONS.md).
- **`DQ_METRICS`** has one row per rule with `FAIL_COUNT`.

`demo/04_latest_wins_demo.sql` then re-sends Mike (USA-3) with a new tier and
flight date in a second batch and verifies `MEMBER_USA` reflects the update.

---

## Suggested commit history (if you push to GitHub)

If you want the evolution story visible in git history, here's a sensible
staging order:

```bash
# 1. scaffold
git add README.md .gitignore docs/
git commit -m "chore: scaffold project (README, docs, .gitignore)"

# 2. setup
git add sql/01_setup.sql
git commit -m "feat: Snowflake setup — db, schemas, warehouses, file formats, country ref"

# 3. raw layer
git add sql/02_raw_tables.sql
git commit -m "feat: raw landing tables (USA, AUS, IND) + JSON redemption feed"

# 4. staging schema
git add sql/03_staging_tables.sql
git commit -m "feat: canonical staging tables (STG_MEMBER with AGE + STALE_MEMBER)"

# 5. mart schema
git add sql/04_mart_tables.sql
git commit -m "feat: per-country mart tables, union view, duplicate detector"

# 6. per-source normalization
git add sql/05_normalize_procedures.sql
git commit -m "feat: per-source normalize procedures with source-specific date parsing"

# 7. dispatch
git add sql/06_dispatch_procedure.sql
git commit -m "feat: SP_DISPATCH_MEMBERS — latest-wins MERGE + country-move audit"

# 8. redemption
git add sql/07_redemption_flatten.sql
git commit -m "feat: JSON redemption flatten + member join + fact-table merge"

# 9. DQ
git add sql/08_dq_framework.sql
git commit -m "feat: declarative DQ framework (rules, runner, quarantine)"

# 10. production wiring
git add sql/09_streams_tasks.sql
git commit -m "feat: Streams + Tasks for continuous ingestion (production shape)"

# 11. demo + sample data
git add sql/demo/ sample_data/
git commit -m "test: end-to-end demo scripts with sample data from all three sources"
```
