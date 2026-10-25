-- =======================================================================
-- Per-country mart tables + REDEMPTION fact + union view + audit tables.
--
-- Per-country tables honour the brief ("All members related to India will
-- go to Table_India, …"). The dispatch procedure in sql/06 auto-creates
-- new country tables LIKE MEMBER_USA when a new ISO3 code appears, so
-- onboarding a new market is zero-code.
-- =======================================================================

USE DATABASE SKYPOINTS;
USE SCHEMA   MART;

-- -----------------------------------------------------------------------
-- Template country table (MEMBER_USA). All country tables share this
-- shape via CREATE TABLE ... LIKE MEMBER_USA.
-- -----------------------------------------------------------------------
CREATE OR REPLACE TABLE MEMBER_USA (
    MEMBER_SK          VARCHAR(50)   NOT NULL PRIMARY KEY,
    SOURCE_ID          VARCHAR(20)   NOT NULL,
    MEMBER_NAME        VARCHAR(255)  NOT NULL,
    TIER_CODE          VARCHAR(5),
    DOB                DATE,
    ENROLLMENT_DATE    DATE          NOT NULL,
    LAST_FLIGHT_DATE   DATE,
    SEGMENT            CHAR(1),
    IS_ACTIVE          CHAR(1),
    STATE              VARCHAR(5),
    POST_CODE          VARCHAR(10),
    COUNTRY_ISO3       VARCHAR(3)    NOT NULL,
    AGE                NUMBER(3),
    STALE_MEMBER       BOOLEAN,
    LAST_UPDATED_TS    TIMESTAMP_NTZ NOT NULL,
    SOURCE_BATCH_ID    VARCHAR
);

CREATE OR REPLACE TABLE MEMBER_IND LIKE MEMBER_USA;
CREATE OR REPLACE TABLE MEMBER_AUS LIKE MEMBER_USA;

-- -----------------------------------------------------------------------
-- Union view across every country table.
-- Used by: redemption join, duplicate detection, cross-country reporting.
-- -----------------------------------------------------------------------
CREATE OR REPLACE VIEW V_MEMBER_ALL AS
SELECT *, 'USA' AS COUNTRY_TABLE FROM MEMBER_USA
UNION ALL SELECT *, 'IND' FROM MEMBER_IND
UNION ALL SELECT *, 'AUS' FROM MEMBER_AUS;

-- -----------------------------------------------------------------------
-- Cross-source duplicate detector.
-- Same NAME + DOB in multiple country marts = likely same person.
-- NOT auto-merged; see docs/DECISIONS.md (D4).
-- -----------------------------------------------------------------------
CREATE OR REPLACE VIEW V_POTENTIAL_DUPLICATES AS
SELECT UPPER(TRIM(MEMBER_NAME))                                               AS NAME_NORM,
       DOB,
       COUNT(DISTINCT COUNTRY_TABLE)                                          AS COUNTRY_COUNT,
       ARRAY_AGG(DISTINCT COUNTRY_TABLE) WITHIN GROUP (ORDER BY COUNTRY_TABLE) AS COUNTRIES,
       ARRAY_AGG(MEMBER_SK)              WITHIN GROUP (ORDER BY MEMBER_SK)     AS MEMBER_SKS
FROM   V_MEMBER_ALL
WHERE  DOB IS NOT NULL
GROUP BY UPPER(TRIM(MEMBER_NAME)), DOB
HAVING COUNT(DISTINCT COUNTRY_TABLE) > 1;

-- Name-only variant for sources that don't carry DOB (USA in this build).
-- Lower precision; use as a stewardship hint, not a merge signal.
CREATE OR REPLACE VIEW V_POTENTIAL_DUPLICATES_NAME_ONLY AS
SELECT UPPER(TRIM(MEMBER_NAME))                                               AS NAME_NORM,
       COUNT(DISTINCT COUNTRY_TABLE)                                          AS COUNTRY_COUNT,
       ARRAY_AGG(DISTINCT COUNTRY_TABLE) WITHIN GROUP (ORDER BY COUNTRY_TABLE) AS COUNTRIES,
       ARRAY_AGG(MEMBER_SK)              WITHIN GROUP (ORDER BY MEMBER_SK)     AS MEMBER_SKS
FROM   V_MEMBER_ALL
GROUP BY UPPER(TRIM(MEMBER_NAME))
HAVING COUNT(DISTINCT COUNTRY_TABLE) > 1;

-- -----------------------------------------------------------------------
-- Redemption fact table.
-- Clustered on (MEMBER_ID, TXN_DATE) because the dominant query shape is
-- "give me a member's recent redemptions" via a join to V_MEMBER_ALL.
-- -----------------------------------------------------------------------
CREATE OR REPLACE TABLE REDEMPTION (
    TXN_ID            VARCHAR       NOT NULL PRIMARY KEY,
    MEMBER_ID         VARCHAR(20)   NOT NULL,
    FEED_DATE         DATE          NOT NULL,
    TXN_DATE          DATE          NOT NULL,
    PARTNER           VARCHAR(100),
    MILES_REDEEMED    NUMBER(12,0),
    STATUS            VARCHAR(20),
    LOAD_TS           TIMESTAMP_NTZ,
    SOURCE_BATCH_ID   VARCHAR
)
CLUSTER BY (MEMBER_ID, TXN_DATE);

-- -----------------------------------------------------------------------
-- Audit tables (META schema).
-- MEMBER_MOVE_AUDIT: logged whenever dispatch sees a member change country.
-- LOAD_AUDIT: one row per batch run with counts and status.
-- -----------------------------------------------------------------------
USE SCHEMA META;

CREATE OR REPLACE TABLE META.MEMBER_MOVE_AUDIT (
    MOVE_TS         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    MEMBER_SK       VARCHAR(50),
    FROM_COUNTRY    VARCHAR(3),
    TO_COUNTRY      VARCHAR(3),
    LOAD_BATCH_ID   VARCHAR
);

CREATE OR REPLACE TABLE META.LOAD_AUDIT (
    LOAD_BATCH_ID     VARCHAR,
    FEED              VARCHAR,
    FILE_NAME         VARCHAR,
    ROW_COUNT_RAW     NUMBER,
    ROW_COUNT_VALID   NUMBER,
    ROW_COUNT_BAD     NUMBER,
    STARTED_AT        TIMESTAMP_NTZ,
    FINISHED_AT       TIMESTAMP_NTZ,
    STATUS            VARCHAR    -- SUCCESS | PARTIAL | FAILED
);
