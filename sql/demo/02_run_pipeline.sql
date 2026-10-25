-- =======================================================================
-- End-to-end pipeline run for batch DEMO-001.
-- In production, Snowflake Tasks fire these in dependency order whenever
-- a stream has new data (see sql/09_streams_tasks.sql). For the demo we
-- call the procedures directly for determinism.
-- =======================================================================

USE DATABASE SKYPOINTS;

-- 1. Normalize each source into canonical staging.
CALL STG.SP_NORMALIZE_USA('DEMO-001');
CALL STG.SP_NORMALIZE_AUS('DEMO-001');
CALL STG.SP_NORMALIZE_IND('DEMO-001');
CALL STG.SP_NORMALIZE_REDEMPTIONS('DEMO-001');

-- 2. Move QUARANTINED rows out of STG before dispatch sees them.
CALL DQ.SP_QUARANTINE_MEMBER('DEMO-001');

-- 3. Split VALID rows into per-country mart tables with latest-wins.
CALL MART.SP_DISPATCH_MEMBERS('DEMO-001');

-- 4. Flatten redemptions into MART.REDEMPTION.
CALL MART.SP_MERGE_REDEMPTIONS('DEMO-001');

-- 5. Run the full DQ sweep and record metrics.
CALL DQ.SP_RUN_DQ('DEMO-001');
