-- =======================================================================
-- JSON redemption feed — flatten with LATERAL FLATTEN, upsert into fact.
--
-- SP_NORMALIZE_REDEMPTIONS: RAW_REDEMPTION_FEED (VARIANT) → STG_REDEMPTION
--   • one output row per transaction (fanning the redemptions[] array)
--   • TRY_TO_* casting so unparseable fields quarantine the row
--   • per-row DQ_STATUS + DQ_ERRORS
--
-- SP_MERGE_REDEMPTIONS: STG_REDEMPTION (VALID) → MART.REDEMPTION
--   • idempotent on TXN_ID
--   • updates STATUS only when it changes (PENDING → COMPLETED, etc.)
-- =======================================================================

USE DATABASE SKYPOINTS;
USE SCHEMA   STG;

CREATE OR REPLACE PROCEDURE SP_NORMALIZE_REDEMPTIONS(P_BATCH_ID STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    v_count NUMBER;
BEGIN
    INSERT INTO STG_REDEMPTION
    SELECT
        r.value:txn_id::VARCHAR                                             AS txn_id,
        j.RAW_JSON:member_id::VARCHAR                                       AS member_id,
        TRY_TO_DATE(j.RAW_JSON:feed_date::VARCHAR, 'YYYYMMDD')              AS feed_date,
        TRY_TO_DATE(r.value:txn_date::VARCHAR,     'YYYYMMDD')              AS txn_date,
        r.value:partner::VARCHAR                                            AS partner,
        TRY_TO_NUMBER(r.value:miles_redeemed::VARCHAR)                      AS miles_redeemed,
        UPPER(r.value:status::VARCHAR)                                      AS status,
        j.SOURCE_FILE_NAME, j.LOAD_BATCH_ID, j.LOAD_TS,
        IFF(r.value:txn_id          IS NULL
         OR j.RAW_JSON:member_id    IS NULL
         OR TRY_TO_DATE(r.value:txn_date::VARCHAR,'YYYYMMDD') IS NULL
         OR TRY_TO_NUMBER(r.value:miles_redeemed::VARCHAR)   IS NULL
         OR TRY_TO_NUMBER(r.value:miles_redeemed::VARCHAR)   <= 0,
             'QUARANTINED','VALID')                                         AS dq_status,
        ARRAY_COMPACT(ARRAY_CONSTRUCT(
            IFF(r.value:txn_id       IS NULL, 'ERR_TXN_ID_NULL',       NULL),
            IFF(j.RAW_JSON:member_id IS NULL, 'ERR_MEMBER_ID_NULL',    NULL),
            IFF(TRY_TO_DATE(r.value:txn_date::VARCHAR,'YYYYMMDD') IS NULL
                                              AND r.value:txn_date IS NOT NULL,
                                              'ERR_TXN_DATE_UNPARSEABLE', NULL),
            IFF(TRY_TO_NUMBER(r.value:miles_redeemed::VARCHAR) IS NULL
                OR TRY_TO_NUMBER(r.value:miles_redeemed::VARCHAR) <= 0,
                                              'ERR_MILES_NON_POSITIVE',   NULL),
            IFF(UPPER(r.value:status::VARCHAR) NOT IN ('COMPLETED','PENDING','FAILED','REVERSED'),
                                              'WARN_UNKNOWN_STATUS',      NULL)
        ))                                                                  AS dq_errors
    FROM        SKYPOINTS.RAW.RAW_REDEMPTION_FEED j,
    LATERAL FLATTEN(input => j.RAW_JSON:redemptions) r
    WHERE j.LOAD_BATCH_ID = :P_BATCH_ID;

    v_count := SQLROWCOUNT;
    RETURN 'SP_NORMALIZE_REDEMPTIONS batch=' || :P_BATCH_ID || ' rows=' || v_count::STRING;
END;
$$;

-- Upsert from staging into fact. Idempotent on TXN_ID.
CREATE OR REPLACE PROCEDURE MART.SP_MERGE_REDEMPTIONS(P_BATCH_ID STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    v_count NUMBER;
BEGIN
    MERGE INTO SKYPOINTS.MART.REDEMPTION t
    USING (SELECT * FROM SKYPOINTS.STG.STG_REDEMPTION
            WHERE LOAD_BATCH_ID = :P_BATCH_ID AND DQ_STATUS = 'VALID') s
    ON  t.TXN_ID = s.TXN_ID
    WHEN MATCHED AND s.STATUS <> t.STATUS THEN UPDATE SET
        STATUS          = s.STATUS,
        LOAD_TS         = s.LOAD_TS,
        SOURCE_BATCH_ID = s.LOAD_BATCH_ID
    WHEN NOT MATCHED THEN INSERT (TXN_ID, MEMBER_ID, FEED_DATE, TXN_DATE,
                                   PARTNER, MILES_REDEEMED, STATUS, LOAD_TS, SOURCE_BATCH_ID)
                           VALUES (s.TXN_ID, s.MEMBER_ID, s.FEED_DATE, s.TXN_DATE,
                                   s.PARTNER, s.MILES_REDEEMED, s.STATUS, s.LOAD_TS, s.LOAD_BATCH_ID);

    v_count := SQLROWCOUNT;
    RETURN 'SP_MERGE_REDEMPTIONS batch=' || :P_BATCH_ID || ' rows=' || v_count::STRING;
END;
$$;

-- =======================================================================
-- Join strategy — see docs/DECISIONS.md (D8).
--
-- MART.REDEMPTION.MEMBER_ID corresponds to STG_MEMBER.SOURCE_ID. Because
-- source IDs are not globally unique in the sample feeds, a plain join
-- fans out across all country marts that share the same SOURCE_ID.
--
-- Reference queries kept here as living documentation.
-- =======================================================================

-- Enrich every redemption with its (candidate) member profile(s).
-- NOTE: fans out when SOURCE_ID collides across countries.
--
-- SELECT r.TXN_ID, r.TXN_DATE, r.PARTNER, r.MILES_REDEEMED, r.STATUS,
--        m.MEMBER_SK, m.MEMBER_NAME, m.COUNTRY_TABLE, m.TIER_CODE
-- FROM   SKYPOINTS.MART.REDEMPTION r
-- LEFT JOIN SKYPOINTS.MART.V_MEMBER_ALL m
--        ON r.MEMBER_ID = m.SOURCE_ID;

-- Country-level KPIs for the last 30 days.
--
-- SELECT m.COUNTRY_ISO3,
--        COUNT(DISTINCT r.TXN_ID)                           AS txn_count,
--        SUM(r.MILES_REDEEMED)                              AS miles_total,
--        SUM(IFF(r.STATUS='COMPLETED', r.MILES_REDEEMED, 0)) AS miles_completed
-- FROM   SKYPOINTS.MART.REDEMPTION r
-- JOIN   SKYPOINTS.MART.V_MEMBER_ALL m ON r.MEMBER_ID = m.SOURCE_ID
-- WHERE  r.TXN_DATE >= DATEADD(DAY, -30, CURRENT_DATE)
-- GROUP BY m.COUNTRY_ISO3;

-- Orphan redemptions — no matching member profile.
-- Usually a feed-ordering issue; always worth watching so we don't lose miles.
--
-- SELECT r.TXN_ID, r.MEMBER_ID, r.FEED_DATE
-- FROM   SKYPOINTS.MART.REDEMPTION r
-- LEFT JOIN SKYPOINTS.MART.V_MEMBER_ALL m ON r.MEMBER_ID = m.SOURCE_ID
-- WHERE  m.MEMBER_SK IS NULL;
