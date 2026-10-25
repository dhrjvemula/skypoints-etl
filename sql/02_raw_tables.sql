-- =======================================================================
-- Raw landing tables — one per source, matching each source's native shape.
-- Everything typed as VARCHAR so bad data lands rather than aborting the file.
-- Lineage columns (SOURCE_FILE_NAME, SOURCE_FILE_ROW_NUMBER, LOAD_BATCH_ID,
-- LOAD_TS) are captured so every mart row is traceable back to its source.
-- =======================================================================

USE DATABASE SKYPOINTS;
USE SCHEMA   RAW;

-- -----------------------------------------------------------------------
-- USA source
--   Columns: ID, Name, TierCode, EnrollmentDate, FlightDate
--   Date format: MMDDYYYY with leading zeros stripped
--     e.g. '6152022' = Jun 15 2022, '8202022' = Aug 20 2022
-- -----------------------------------------------------------------------
CREATE OR REPLACE TABLE RAW_USA_MEMBERS (
    ID                     VARCHAR,
    NAME                   VARCHAR,
    TIER_CODE              VARCHAR,
    ENROLLMENT_DATE        VARCHAR,
    FLIGHT_DATE            VARCHAR,
    SOURCE_FILE_NAME       VARCHAR,
    SOURCE_FILE_ROW_NUMBER NUMBER,
    LOAD_BATCH_ID          VARCHAR,
    LOAD_TS                TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- -----------------------------------------------------------------------
-- AUS source
--   Columns: Unique ID, Member Name, Tier Type,
--            Date of Birth, Date of Enrollment, Date of Flight
--   Date format: ISO YYYY-MM-DD
--   Note: the sample contains '2021-13-13' (invalid month) which must be
--   caught by DQ, not silently coerced.
-- -----------------------------------------------------------------------
CREATE OR REPLACE TABLE RAW_AUS_MEMBERS (
    UNIQUE_ID              VARCHAR,
    MEMBER_NAME            VARCHAR,
    TIER_TYPE              VARCHAR,
    DATE_OF_BIRTH          VARCHAR,
    DATE_OF_ENROLLMENT     VARCHAR,
    DATE_OF_FLIGHT         VARCHAR,
    SOURCE_FILE_NAME       VARCHAR,
    SOURCE_FILE_ROW_NUMBER NUMBER,
    LOAD_BATCH_ID          VARCHAR,
    LOAD_TS                TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- -----------------------------------------------------------------------
-- IND source
--   Columns: ID, Name, DOB, TierCode, EnrollmentDate,
--            Individual or Corporate, Flight Date
--   Date format: US-style M/D/YYYY
--   Extra attribute SEGMENT (I/C) is preserved into canonical staging.
-- -----------------------------------------------------------------------
CREATE OR REPLACE TABLE RAW_IND_MEMBERS (
    ID                       VARCHAR,
    NAME                     VARCHAR,
    DOB                      VARCHAR,
    TIER_CODE                VARCHAR,
    ENROLLMENT_DATE          VARCHAR,
    INDIVIDUAL_OR_CORPORATE  VARCHAR,
    FLIGHT_DATE              VARCHAR,
    SOURCE_FILE_NAME         VARCHAR,
    SOURCE_FILE_ROW_NUMBER   NUMBER,
    LOAD_BATCH_ID            VARCHAR,
    LOAD_TS                  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- -----------------------------------------------------------------------
-- JSON redemption feed (per the original brief).
-- Stored as VARIANT so partners can evolve their payload without a schema
-- migration here. Flattening happens in sql/07_redemption_flatten.sql.
-- -----------------------------------------------------------------------
CREATE OR REPLACE TABLE RAW_REDEMPTION_FEED (
    RAW_JSON               VARIANT,
    SOURCE_FILE_NAME       VARCHAR,
    SOURCE_FILE_ROW_NUMBER NUMBER,
    LOAD_BATCH_ID          VARCHAR,
    LOAD_TS                TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
