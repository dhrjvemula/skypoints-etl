-- =======================================================================
-- Latest-wins demo (deliverable #3).
--
-- Scenario A: USA re-sends Mike (ID=3) in a second batch with a promoted
-- tier and a newer flight date. The MERGE in SP_DISPATCH_MEMBERS must
-- overwrite the previous MEMBER_USA row and advance LAST_UPDATED_TS.
--
-- Scenario B: a true country move — IND now has "Mike" as ID=9. Because
-- source IDs are not globally unique, the build does NOT auto-merge
-- USA-3 and IND-9; instead the duplicate shows up in
-- V_POTENTIAL_DUPLICATES_NAME_ONLY for stewardship. See docs/DECISIONS.md (D4).
-- =======================================================================

USE DATABASE SKYPOINTS;

-- -----------------------------------------------------------------------
-- Scenario A — same source, same MEMBER_SK, newer attributes.
-- -----------------------------------------------------------------------

-- State before
SELECT 'before' AS phase, MEMBER_SK, TIER_CODE, LAST_FLIGHT_DATE,
       STALE_MEMBER, LAST_UPDATED_TS
FROM   MART.MEMBER_USA WHERE MEMBER_SK = 'USA-3';

-- New batch for Mike
INSERT INTO RAW.RAW_USA_MEMBERS (ID, NAME, TIER_CODE, ENROLLMENT_DATE, FLIGHT_DATE,
                                  SOURCE_FILE_NAME, SOURCE_FILE_ROW_NUMBER, LOAD_BATCH_ID) VALUES
('3','Mike','PLT','12282021','9152024','usa_members_day2.csv', 1, 'DEMO-002');

CALL STG.SP_NORMALIZE_USA('DEMO-002');
CALL DQ.SP_QUARANTINE_MEMBER('DEMO-002');
CALL MART.SP_DISPATCH_MEMBERS('DEMO-002');

-- State after
SELECT 'after' AS phase, MEMBER_SK, TIER_CODE, LAST_FLIGHT_DATE,
       STALE_MEMBER, LAST_UPDATED_TS
FROM   MART.MEMBER_USA WHERE MEMBER_SK = 'USA-3';
-- Expected: TIER_CODE flipped GLD → PLT, LAST_FLIGHT_DATE = 2024-09-15,
-- LAST_UPDATED_TS advances to the new load timestamp.

-- -----------------------------------------------------------------------
-- Scenario B — the same person surfaces in a different source system.
-- -----------------------------------------------------------------------

INSERT INTO RAW.RAW_IND_MEMBERS (ID, NAME, DOB, TIER_CODE, ENROLLMENT_DATE,
                                  INDIVIDUAL_OR_CORPORATE, FLIGHT_DATE,
                                  SOURCE_FILE_NAME, SOURCE_FILE_ROW_NUMBER, LOAD_BATCH_ID) VALUES
('9','Mike','12/30/1990','PLT','10/1/2024','I','10/20/2024','ind_members_day2.csv', 1, 'DEMO-002');

CALL STG.SP_NORMALIZE_IND('DEMO-002');
CALL DQ.SP_QUARANTINE_MEMBER('DEMO-002');
CALL MART.SP_DISPATCH_MEMBERS('DEMO-002');

-- Mike now exists as USA-3 AND IND-9 — flagged by the duplicate detector.
SELECT * FROM MART.V_POTENTIAL_DUPLICATES_NAME_ONLY WHERE NAME_NORM = 'MIKE';
-- Expected: one row with COUNTRIES = ['AUS','IND','USA'] (because AUS
-- already had a Mike), MEMBER_SKS = ['AUS-1','IND-9','USA-3'].

-- No MEMBER_MOVE_AUDIT entry — the move audit only fires when the SAME
-- MEMBER_SK changes country, which doesn't happen in this scenario.
SELECT * FROM META.MEMBER_MOVE_AUDIT WHERE LOAD_BATCH_ID = 'DEMO-002';
-- Expected: zero rows.
