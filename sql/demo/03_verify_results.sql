-- =======================================================================
-- Verification queries. Run after demo/02_run_pipeline.sql.
-- Expected results are stated inline so a reviewer can tell what passing
-- looks like without running the pipeline themselves.
-- =======================================================================

USE DATABASE SKYPOINTS;

-- -----------------------------------------------------------------------
-- 1. Per-country mart row counts.
-- -----------------------------------------------------------------------
SELECT 'MEMBER_USA' AS tbl, COUNT(*) AS n FROM MART.MEMBER_USA
UNION ALL
SELECT 'MEMBER_IND',          COUNT(*)      FROM MART.MEMBER_IND
UNION ALL
SELECT 'MEMBER_AUS',          COUNT(*)      FROM MART.MEMBER_AUS
ORDER BY tbl;
-- Expected: USA=3, IND=3, AUS=2 (Jonnathan quarantined for invalid date).

-- -----------------------------------------------------------------------
-- 2. Full canonical view across all country marts.
-- -----------------------------------------------------------------------
SELECT MEMBER_SK, MEMBER_NAME, TIER_CODE, DOB, AGE,
       ENROLLMENT_DATE, LAST_FLIGHT_DATE, STALE_MEMBER,
       SEGMENT, COUNTRY_TABLE
FROM   MART.V_MEMBER_ALL
ORDER BY COUNTRY_TABLE, MEMBER_SK;
-- Expected: 8 rows total. USA members have DOB=NULL and AGE=NULL (source
-- doesn't carry it). AUS-1 (Mike) also DOB=NULL. All others have AGE
-- computed birthday-aware.

-- -----------------------------------------------------------------------
-- 3. Who got quarantined and why.
-- -----------------------------------------------------------------------
SELECT MEMBER_SK, MEMBER_NAME, SOURCE_COUNTRY, DQ_ERRORS
FROM   DQ.QUARANTINE_MEMBER
ORDER BY MEMBER_SK;
-- Expected: AUS-2 (Jonnathan) with ERR_ENROLLMENT_INVALID_DATE because
-- '2021-13-13' is not a valid date.

-- -----------------------------------------------------------------------
-- 4. Redemption → member join (deliverable #4).
--    NOTE: fan-out expected — SOURCE_ID collides across countries.
-- -----------------------------------------------------------------------
SELECT r.TXN_ID, r.TXN_DATE, r.PARTNER, r.MILES_REDEEMED, r.STATUS,
       m.MEMBER_SK, m.MEMBER_NAME, m.COUNTRY_TABLE, m.TIER_CODE
FROM   MART.REDEMPTION r
LEFT JOIN MART.V_MEMBER_ALL m ON r.MEMBER_ID = m.SOURCE_ID
ORDER BY r.TXN_ID, m.MEMBER_SK;
-- Expected: 3 redemptions × up to 3 candidate members per MEMBER_ID.
-- See docs/DECISIONS.md (D8) for why the fan-out exists and how to fix.

-- -----------------------------------------------------------------------
-- 5. Cross-source duplicates (stewardship signal).
-- -----------------------------------------------------------------------
SELECT * FROM MART.V_POTENTIAL_DUPLICATES_NAME_ONLY;
-- Expected: 'MIKE' present in both USA (USA-3) and AUS (AUS-1).

-- -----------------------------------------------------------------------
-- 6. DQ metrics dashboard (what the pipeline just said about this batch).
-- -----------------------------------------------------------------------
SELECT CHECK_ID, SEVERITY, FAIL_COUNT, DESCRIPTION
FROM   DQ.DQ_METRICS
WHERE  LOAD_BATCH_ID = 'DEMO-001'
ORDER BY (CASE SEVERITY WHEN 'FAIL' THEN 1 WHEN 'WARN' THEN 2 END),
         FAIL_COUNT DESC;
-- Expected: all FAIL checks have FAIL_COUNT = 0 (because quarantined rows
-- were moved out of STG before DQ ran). X01 reports 0 (no NAME+DOB match
-- because USA has no DOB). X02 (orphan redemptions) will be 0 for member
-- ids 1 and 3 which match members in the mart.

-- -----------------------------------------------------------------------
-- 7. Age + stale check (deliverable #2).
-- -----------------------------------------------------------------------
SELECT MEMBER_SK, MEMBER_NAME, DOB, AGE,
       LAST_FLIGHT_DATE,
       DATEDIFF(DAY, LAST_FLIGHT_DATE, CURRENT_DATE) AS days_since_flight,
       STALE_MEMBER
FROM   MART.V_MEMBER_ALL
ORDER BY STALE_MEMBER DESC, MEMBER_SK;
-- Expected: STALE_MEMBER = TRUE for every member whose last flight is
-- older than 90 days, plus Mike (AUS-1) whose DOB is NULL.
