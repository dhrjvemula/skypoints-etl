-- =======================================================================
-- SP_DISPATCH_MEMBERS
--
-- Splits VALID staging rows into per-country mart tables with "latest wins".
--
-- Rules:
--   1. Collapse the batch to one row per MEMBER_SK, keeping the latest
--      (ordered by LOAD_TS DESC, SOURCE_FILE_ROW_NUMBER DESC as tiebreak).
--   2. If a member's COUNTRY_ISO3 differs from the one currently held in
--      the mart, delete the member from the old country table, audit the
--      move in META.MEMBER_MOVE_AUDIT, then let step 3 insert the new row.
--   3. For each target country, auto-create MEMBER_<ISO3> LIKE MEMBER_USA
--      if it doesn't exist yet, then MERGE with latest-wins semantics.
--
-- Does NOT handle cross-source identity (same person in two source
-- systems with different source IDs). That's a stewardship decision,
-- surfaced via MART.V_POTENTIAL_DUPLICATES — see docs/DECISIONS.md (D4).
-- =======================================================================

USE DATABASE SKYPOINTS;
USE SCHEMA   MART;

CREATE OR REPLACE PROCEDURE SP_DISPATCH_MEMBERS(P_BATCH_ID STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    v_country_count NUMBER := 0;
    v_moves_count   NUMBER := 0;
BEGIN
    -- Step 1 — collapse to one row per MEMBER_SK, latest wins.
    CREATE OR REPLACE TEMPORARY TABLE _LATEST AS
    SELECT * EXCLUDE RN FROM (
        SELECT s.*,
               ROW_NUMBER() OVER (
                   PARTITION BY MEMBER_SK
                   ORDER BY LOAD_TS DESC, SOURCE_FILE_ROW_NUMBER DESC
               ) AS RN
        FROM SKYPOINTS.STG.STG_MEMBER s
        WHERE LOAD_BATCH_ID = :P_BATCH_ID
          AND DQ_STATUS      = 'VALID'
    ) WHERE RN = 1;

    -- Step 2 — detect country moves (same MEMBER_SK, different COUNTRY_ISO3
    -- vs. what's currently in the mart). Audit and delete-from-old before
    -- the MERGE in step 3 does the insert-into-new.
    CREATE OR REPLACE TEMPORARY TABLE _MOVES AS
    SELECT l.MEMBER_SK,
           v.COUNTRY_TABLE AS FROM_COUNTRY,
           l.COUNTRY_ISO3  AS TO_COUNTRY
    FROM   _LATEST l
    JOIN   SKYPOINTS.MART.V_MEMBER_ALL v USING (MEMBER_SK)
    WHERE  v.COUNTRY_TABLE <> l.COUNTRY_ISO3;

    SELECT COUNT(*) INTO :v_moves_count FROM _MOVES;

    INSERT INTO SKYPOINTS.META.MEMBER_MOVE_AUDIT (MEMBER_SK, FROM_COUNTRY, TO_COUNTRY, LOAD_BATCH_ID)
    SELECT MEMBER_SK, FROM_COUNTRY, TO_COUNTRY, :P_BATCH_ID FROM _MOVES;

    FOR r IN (SELECT DISTINCT FROM_COUNTRY AS CTY FROM _MOVES) DO
        LET sql_del VARCHAR :=
            'DELETE FROM SKYPOINTS.MART.MEMBER_' || r.CTY ||
            ' WHERE MEMBER_SK IN (SELECT MEMBER_SK FROM _MOVES WHERE FROM_COUNTRY = ''' ||
            r.CTY || ''')';
        EXECUTE IMMEDIATE :sql_del;
    END FOR;

    -- Step 3 — per-country MERGE with latest-wins.
    FOR r IN (SELECT DISTINCT COUNTRY_ISO3 AS CTY
              FROM _LATEST WHERE COUNTRY_ISO3 IS NOT NULL) DO

        v_country_count := v_country_count + 1;

        -- Auto-create target table on first appearance of a new country.
        LET sql_create VARCHAR :=
            'CREATE TABLE IF NOT EXISTS SKYPOINTS.MART.MEMBER_' || r.CTY ||
            ' LIKE SKYPOINTS.MART.MEMBER_USA';
        EXECUTE IMMEDIATE :sql_create;

        -- Latest-wins MERGE.
        LET sql_merge VARCHAR :=
            'MERGE INTO SKYPOINTS.MART.MEMBER_' || r.CTY || ' t ' ||
            'USING (SELECT * FROM _LATEST WHERE COUNTRY_ISO3 = ''' || r.CTY || ''') s ' ||
            'ON t.MEMBER_SK = s.MEMBER_SK ' ||
            'WHEN MATCHED AND s.LOAD_TS >= t.LAST_UPDATED_TS THEN UPDATE SET ' ||
            '  SOURCE_ID = s.SOURCE_ID, MEMBER_NAME = s.MEMBER_NAME, ' ||
            '  TIER_CODE = s.TIER_CODE, DOB = s.DOB, ' ||
            '  ENROLLMENT_DATE = s.ENROLLMENT_DATE, LAST_FLIGHT_DATE = s.LAST_FLIGHT_DATE, ' ||
            '  SEGMENT = s.SEGMENT, IS_ACTIVE = s.IS_ACTIVE, ' ||
            '  STATE = s.STATE, POST_CODE = s.POST_CODE, ' ||
            '  COUNTRY_ISO3 = s.COUNTRY_ISO3, AGE = s.AGE, STALE_MEMBER = s.STALE_MEMBER, ' ||
            '  LAST_UPDATED_TS = s.LOAD_TS, SOURCE_BATCH_ID = s.LOAD_BATCH_ID ' ||
            'WHEN NOT MATCHED THEN INSERT ( ' ||
            '  MEMBER_SK, SOURCE_ID, MEMBER_NAME, TIER_CODE, DOB, ENROLLMENT_DATE, LAST_FLIGHT_DATE, ' ||
            '  SEGMENT, IS_ACTIVE, STATE, POST_CODE, COUNTRY_ISO3, AGE, STALE_MEMBER, LAST_UPDATED_TS, SOURCE_BATCH_ID ' ||
            ') VALUES ( ' ||
            '  s.MEMBER_SK, s.SOURCE_ID, s.MEMBER_NAME, s.TIER_CODE, s.DOB, s.ENROLLMENT_DATE, s.LAST_FLIGHT_DATE, ' ||
            '  s.SEGMENT, s.IS_ACTIVE, s.STATE, s.POST_CODE, s.COUNTRY_ISO3, s.AGE, s.STALE_MEMBER, s.LOAD_TS, s.LOAD_BATCH_ID ' ||
            ')';
        EXECUTE IMMEDIATE :sql_merge;
    END FOR;

    RETURN 'SP_DISPATCH_MEMBERS batch=' || :P_BATCH_ID ||
           ' countries=' || v_country_count::STRING ||
           ' moves='     || v_moves_count::STRING;
END;
$$;
