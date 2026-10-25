# Architecture

## Data flow

```
┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐   ┌───────────────┐
│  USA source     │   │  AUS source     │   │  IND source     │   │ Partner JSON  │
│  (CSV, MMDDYYYY │   │  (CSV, ISO)     │   │  (CSV, M/D/YYYY)│   │ (redemptions) │
│   zeros stripped│   │                 │   │  + I/C segment  │   │               │
└────────┬────────┘   └────────┬────────┘   └────────┬────────┘   └───────┬───────┘
         │ COPY INTO / Snowpipe│                     │                    │
         ▼                     ▼                     ▼                    ▼
┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐   ┌───────────────┐
│ RAW_USA_MEMBERS │   │ RAW_AUS_MEMBERS │   │ RAW_IND_MEMBERS │   │ RAW_REDEMPTION│
│  (VARCHAR cols) │   │  (VARCHAR cols) │   │  (VARCHAR cols) │   │  _FEED (VARIANT)│
└────────┬────────┘   └────────┬────────┘   └────────┬────────┘   └───────┬───────┘
         │  Stream + Task      │                     │                    │
         ▼                     ▼                     ▼                    ▼
┌─────────────────────────────────────────────────────────────┐  ┌───────────────┐
│       SP_NORMALIZE_USA / _AUS / _IND  (STG schema)          │  │ SP_NORMALIZE_ │
│   • source-specific date parsing                             │  │  REDEMPTIONS  │
│   • surrogate key MEMBER_SK = <country>-<source_id>          │  │               │
│   • derived AGE and STALE_MEMBER                             │  │               │
│   • per-row DQ_STATUS + DQ_ERRORS                            │  │               │
└──────────────────────────┬──────────────────────────────────┘  └───────┬───────┘
                           ▼                                             ▼
                   ┌───────────────┐                           ┌───────────────┐
                   │  STG_MEMBER   │                           │ STG_REDEMPTION│
                   │ (canonical)   │                           │ (flat)        │
                   └───────┬───────┘                           └───────┬───────┘
                           │                                           │
                 SP_QUARANTINE_MEMBER                                   │
                           │                                           │
                           ▼                                           │
                 ┌─────────────────┐                                   │
                 │ DQ.QUARANTINE_* │                                   │
                 └─────────────────┘                                   │
                           │                                           │
                 SP_DISPATCH_MEMBERS                        SP_MERGE_REDEMPTIONS
                           │                                           │
                           ▼                                           ▼
      ┌────────────────────────────────────────┐           ┌───────────────────┐
      │  MART.MEMBER_USA / MEMBER_IND /         │           │  MART.REDEMPTION  │
      │  MEMBER_AUS / ...                       │           │   (fact table)    │
      │                                         │           │                   │
      │  View: V_MEMBER_ALL                     │           │                   │
      │  View: V_POTENTIAL_DUPLICATES           │           │                   │
      │  Audit: META.MEMBER_MOVE_AUDIT          │           │                   │
      └────────────────────────────────────────┘           └───────────────────┘
                                     │                               │
                                     └────── join via SOURCE_ID ─────┘

                 DQ.DQ_RULES → SP_RUN_DQ → DQ.DQ_METRICS
```

## Layer responsibilities

### RAW (`SKYPOINTS.RAW`)
Lands source data **verbatim** with every column typed as `VARCHAR` and the
JSON feed typed as `VARIANT`. The job of this layer is to tolerate bad data
without aborting the ingest. Lineage (`SOURCE_FILE_NAME`, `SOURCE_FILE_ROW_NUMBER`,
`LOAD_BATCH_ID`, `LOAD_TS`) is captured on every row so every mart row is
traceable back to the exact file and line it came from.

### STG (`SKYPOINTS.STG`)
Canonical, typed, deduplicated. One shared `STG_MEMBER` schema is fed by
three per-source normalization procedures that each know their own source's
date format quirks and column naming. Derived columns (`AGE`, `STALE_MEMBER`)
and DQ tagging happen here. Quarantined rows are moved out to
`DQ.QUARANTINE_MEMBER` before dispatch runs.

### MART (`SKYPOINTS.MART`)
Per-country tables as the brief requires. `SP_DISPATCH_MEMBERS` splits
valid staging rows into their country mart with a `MERGE` keyed on
`MEMBER_SK`, with `LOAD_TS` as the "latest wins" tiebreaker. New country
tables are auto-created `LIKE MEMBER_USA` on first appearance, so onboarding
a new market requires zero code change. `MART.REDEMPTION` is a single fact
table clustered on `(MEMBER_ID, TXN_DATE)`.

### DQ (`SKYPOINTS.DQ`)
Declarative rules in `DQ_RULES`, executed by `SP_RUN_DQ`, results written to
`DQ_METRICS`. Adding a rule = `INSERT INTO DQ_RULES`, not a deploy. Quarantined
rows land in `QUARANTINE_MEMBER` / `QUARANTINE_REDEMPTION` for ops inspection.

### META (`SKYPOINTS.META`)
Audit tables: `MEMBER_MOVE_AUDIT` (country migrations), `LOAD_AUDIT`
(per-batch run metadata).

## Scale posture (billions / day)

| Concern | Mitigation |
|---|---|
| Loader spike starves transform | Separate warehouses: `WH_LOAD` and `WH_TRANSFORM`, both auto-suspend after 60s |
| Nightly batch too slow | Snowpipe + Streams + Tasks (`sql/09_streams_tasks.sql`) — near-real-time with same semantics |
| Country-table scans | Clustering keys on `(COUNTRY_ISO3, LOAD_TS)` for staging, `(MEMBER_ID, TXN_DATE)` for redemptions |
| Replay / idempotency | `COPY INTO` dedups on `(stage, file_name)`; MERGEs are keyed on business keys; `LOAD_BATCH_ID` prevents double-processing |
| Bad row aborts whole file | `COPY INTO ... ON_ERROR = 'CONTINUE'` + per-row `DQ_STATUS` quarantine, never a `FAIL` |
| New country onboarding | `SP_DISPATCH_MEMBERS` auto-creates `MEMBER_<ISO3>` `LIKE MEMBER_USA` on first appearance |
| Observability | `DQ_METRICS` dashboard + `LOAD_AUDIT` + Snowflake task history |
| PII (`DOB`, `MEMBER_NAME`, `POST_CODE`) | Mart tables are the natural place to attach Snowflake dynamic data masking policies — omitted here to keep the deliverable focused |

## Error handling

- **Parse failures** (bad date, non-numeric miles) → `TRY_TO_*` returns NULL →
  tagged with `ERR_*_UNPARSEABLE` → row quarantined.
- **Missing mandatory fields** → tagged `ERR_*_NULL` → row quarantined.
- **Business-rule violations** (age > 120, flight before enrollment) → tagged
  `ERR_*` → row quarantined.
- **Soft issues** (unknown tier, missing DOB from source that doesn't carry it)
  → tagged `WARN_*` → row passes through, warning counted in `DQ_METRICS`.
- **Orphan redemptions** (no matching member) → kept in `MART.REDEMPTION`,
  surfaced by DQ rule `X02` for backfill/stewardship.
