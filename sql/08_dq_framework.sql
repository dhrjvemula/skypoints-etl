-- =======================================================================
-- Declarative data-quality framework.
--
-- Design:
--   • Rules live as rows in DQ.DQ_RULES — adding a check is one INSERT.
--   • SP_RUN_DQ iterates every rule, executes its CHECK_SQL, and writes
--     the result count to DQ.DQ_METRICS. One row per (batch, rule).
--   • Severity FAIL = row-level quarantine; WARN = pass-through + observe.
--   • Row-level quarantining happens inside the normalize procedures;
--     SP_QUARANTINE_MEMBER sweeps QUARANTINED rows out of STG and into
--     DQ.QUARANTINE_MEMBER for ops inspection.
-- =======================================================================

USE DATABASE SKYPOINTS;
USE SCHEMA   DQ;

CREATE OR REPLACE TABLE QUARANTINE_MEMBER     LIKE STG.STG_MEMBER;
CREATE OR REPLACE TABLE QUARANTINE_REDEMPTION LIKE STG.STG_REDEMPTION;

CREATE OR REPLACE TABLE DQ_METRICS (
    RUN_TS         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    LOAD_BATCH_ID  VARCHAR,
    FEED           VARCHAR,          -- MEMBER | REDEMPTION | CROSS
    CHECK_ID       VARCHAR,
    SEVERITY       VARCHAR,          -- FAIL | WARN
    FAIL_COUNT     NUMBER,
    DESCRIPTION    VARCHAR
);

CREATE OR REPLACE TABLE DQ_RULES (
    RULE_ID        VARCHAR PRIMARY KEY,
    FEED           VARCHAR,
    CATEGORY       VARCHAR,          -- MANDATORY | UNIQUENESS | FORMAT | REFERENTIAL | BUSINESS | VOLUME | DRIFT
    SEVERITY       VARCHAR,
    DESCRIPTION    VARCHAR,
    CHECK_SQL      VARCHAR           -- must return a single integer (0 = passing)
);

INSERT INTO DQ_RULES VALUES
-- Mandatory
('M01','MEMBER',    'MANDATORY',  'FAIL','MEMBER_NAME must not be null',
  'SELECT COUNT(*) FROM SKYPOINTS.STG.STG_MEMBER WHERE MEMBER_NAME IS NULL'),
('M02','MEMBER',    'MANDATORY',  'FAIL','SOURCE_ID must not be null',
  'SELECT COUNT(*) FROM SKYPOINTS.STG.STG_MEMBER WHERE SOURCE_ID IS NULL'),
('M03','MEMBER',    'MANDATORY',  'FAIL','ENROLLMENT_DATE must be present and parse',
  'SELECT COUNT(*) FROM SKYPOINTS.STG.STG_MEMBER WHERE ENROLLMENT_DATE IS NULL'),
-- Uniqueness
('U01','MEMBER',    'UNIQUENESS', 'FAIL','MEMBER_SK unique across all country marts',
  'SELECT COUNT(*) FROM (SELECT MEMBER_SK, COUNT(*) c FROM SKYPOINTS.MART.V_MEMBER_ALL GROUP BY MEMBER_SK HAVING c > 1)'),
('U02','REDEMPTION','UNIQUENESS', 'FAIL','TXN_ID is globally unique',
  'SELECT COUNT(*) FROM (SELECT TXN_ID, COUNT(*) c FROM SKYPOINTS.MART.REDEMPTION GROUP BY TXN_ID HAVING c > 1)'),
-- Business rules
('B01','MEMBER',    'BUSINESS',   'FAIL','AGE in [0, 120] when present',
  'SELECT COUNT(*) FROM SKYPOINTS.STG.STG_MEMBER WHERE AGE IS NOT NULL AND (AGE < 0 OR AGE > 120)'),
('B02','MEMBER',    'BUSINESS',   'FAIL','LAST_FLIGHT_DATE must be >= ENROLLMENT_DATE when both present',
  'SELECT COUNT(*) FROM SKYPOINTS.STG.STG_MEMBER WHERE LAST_FLIGHT_DATE IS NOT NULL AND LAST_FLIGHT_DATE < ENROLLMENT_DATE'),
('B03','MEMBER',    'BUSINESS',   'FAIL','ENROLLMENT_DATE must not be in the future',
  'SELECT COUNT(*) FROM SKYPOINTS.STG.STG_MEMBER WHERE ENROLLMENT_DATE > CURRENT_DATE'),
('B04','MEMBER',    'BUSINESS',   'WARN','DOB must not be in the future',
  'SELECT COUNT(*) FROM SKYPOINTS.STG.STG_MEMBER WHERE DOB IS NOT NULL AND DOB > CURRENT_DATE'),
('B05','REDEMPTION','BUSINESS',   'FAIL','MILES_REDEEMED must be positive',
  'SELECT COUNT(*) FROM SKYPOINTS.STG.STG_REDEMPTION WHERE MILES_REDEEMED IS NOT NULL AND MILES_REDEEMED <= 0'),
-- Format / reference
('F01','MEMBER',    'FORMAT',     'WARN','TIER_CODE in known set',
  'SELECT COUNT(*) FROM SKYPOINTS.STG.STG_MEMBER WHERE TIER_CODE IS NOT NULL AND TIER_CODE NOT IN (''GLD'',''SLV'',''PLT'',''BRZ'',''DIA'')'),
('F02','MEMBER',    'FORMAT',     'WARN','SEGMENT in {I, C} when present',
  'SELECT COUNT(*) FROM SKYPOINTS.STG.STG_MEMBER WHERE SEGMENT IS NOT NULL AND SEGMENT NOT IN (''I'',''C'')'),
-- Cross-source / stewardship
('X01','CROSS',     'REFERENTIAL','WARN','Potential cross-source duplicates (same NAME+DOB in multiple countries)',
  'SELECT COUNT(*) FROM SKYPOINTS.MART.V_POTENTIAL_DUPLICATES'),
('X02','CROSS',     'REFERENTIAL','WARN','Redemptions with no matching member (orphans)',
  'SELECT COUNT(*) FROM SKYPOINTS.MART.REDEMPTION r LEFT JOIN SKYPOINTS.MART.V_MEMBER_ALL m ON r.MEMBER_ID = m.SOURCE_ID WHERE m.MEMBER_SK IS NULL'),
-- Volume (catches silent partial loads)
('V01','MEMBER',    'VOLUME',     'WARN','Daily row count within +/- 30% of 7-day average',
  'SELECT CASE WHEN avg7.c IS NULL OR avg7.c = 0 THEN 0
               WHEN ABS(today.c - avg7.c)/avg7.c > 0.30 THEN 1 ELSE 0 END
   FROM (SELECT COUNT(*) c FROM SKYPOINTS.STG.STG_MEMBER WHERE LOAD_TS::DATE = CURRENT_DATE) today,
        (SELECT COUNT(*)/7.0 c FROM SKYPOINTS.STG.STG_MEMBER
          WHERE LOAD_TS::DATE BETWEEN DATEADD(DAY,-8,CURRENT_DATE) AND DATEADD(DAY,-1,CURRENT_DATE)) avg7'),
-- -----------------------------------------------------------------------
-- Rules derived from the PDF sample flat file.
-- The brief shows Member_Id values like '22345' and '2256' that are shorter
-- than their peers (leading zeros stripped by an upstream parser), DOB
-- stored as '3051985' instead of '03051985' (same problem), and the staging
-- table column 'Country' silently renamed to 'County'. These four rules
-- catch that family of problems.
-- -----------------------------------------------------------------------
('F03','MEMBER',    'FORMAT',     'WARN','SOURCE_ID length shorter than the max for its source (likely leading-zero stripping)',
  'SELECT COUNT(*) FROM (SELECT LENGTH(SOURCE_ID) AS l,
                                MAX(LENGTH(SOURCE_ID)) OVER (PARTITION BY SOURCE_COUNTRY) AS max_l
                         FROM SKYPOINTS.STG.STG_MEMBER
                         WHERE SOURCE_ID IS NOT NULL) WHERE l < max_l'),
('F04','MEMBER',    'FORMAT',     'WARN','DOB raw was provided but failed to parse (leading-zero stripping or format drift)',
  'SELECT COUNT(*) FROM SKYPOINTS.STG.STG_MEMBER
    WHERE ARRAY_CONTAINS(''WARN_DOB_UNPARSEABLE''::VARIANT, DQ_ERRORS)'),
('D01','MEMBER',    'DRIFT',      'FAIL','Schema drift: TIER_CODE >95% NULL for a source in the last 24h (column likely renamed upstream)',
  'SELECT COUNT(*) FROM (SELECT SOURCE_COUNTRY,
                                COUNT(*) AS total_rows,
                                SUM(IFF(TIER_CODE IS NULL, 1, 0)) AS null_rows
                         FROM SKYPOINTS.STG.STG_MEMBER
                         WHERE LOAD_TS >= DATEADD(DAY, -1, CURRENT_DATE)
                         GROUP BY SOURCE_COUNTRY
                         HAVING total_rows > 10 AND null_rows > 0.95 * total_rows)'),
('U03','MEMBER',    'UNIQUENESS', 'FAIL','Duplicate (SOURCE_COUNTRY, SOURCE_ID) within the same batch',
  'SELECT COUNT(*) FROM (SELECT SOURCE_COUNTRY, SOURCE_ID, LOAD_BATCH_ID, COUNT(*) c
                         FROM SKYPOINTS.STG.STG_MEMBER
                         WHERE SOURCE_ID IS NOT NULL
                         GROUP BY SOURCE_COUNTRY, SOURCE_ID, LOAD_BATCH_ID HAVING c > 1)');

-- -----------------------------------------------------------------------
-- SP_RUN_DQ: executes every rule in DQ_RULES, writes a row per rule to
-- DQ_METRICS. Call once per batch, after dispatch has finished.
-- -----------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_RUN_DQ(P_BATCH_ID STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    FOR r IN (SELECT * FROM DQ_RULES) DO
        LET sql_insert VARCHAR :=
            'INSERT INTO SKYPOINTS.DQ.DQ_METRICS ' ||
            '(LOAD_BATCH_ID, FEED, CHECK_ID, SEVERITY, FAIL_COUNT, DESCRIPTION) ' ||
            'SELECT ''' || :P_BATCH_ID || ''', ''' || r.FEED || ''', ''' || r.RULE_ID ||
            ''', ''' || r.SEVERITY || ''', (' || r.CHECK_SQL || '), ''' ||
            REPLACE(r.DESCRIPTION, '''', '''''') || '''';
        EXECUTE IMMEDIATE :sql_insert;
    END FOR;
    RETURN 'SP_RUN_DQ batch=' || :P_BATCH_ID;
END;
$$;

-- -----------------------------------------------------------------------
-- SP_QUARANTINE_MEMBER: moves QUARANTINED rows out of STG_MEMBER into
-- QUARANTINE_MEMBER so dispatch only sees clean rows.
-- -----------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_QUARANTINE_MEMBER(P_BATCH_ID STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE v_count NUMBER;
BEGIN
    INSERT INTO SKYPOINTS.DQ.QUARANTINE_MEMBER
    SELECT * FROM SKYPOINTS.STG.STG_MEMBER
    WHERE LOAD_BATCH_ID = :P_BATCH_ID AND DQ_STATUS = 'QUARANTINED';

    DELETE FROM SKYPOINTS.STG.STG_MEMBER
    WHERE LOAD_BATCH_ID = :P_BATCH_ID AND DQ_STATUS = 'QUARANTINED';

    v_count := SQLROWCOUNT;
    RETURN 'SP_QUARANTINE_MEMBER batch=' || :P_BATCH_ID || ' quarantined=' || v_count::STRING;
END;
$$;
