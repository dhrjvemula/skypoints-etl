-- =======================================================================
-- Canonical staging tables.
-- One shared shape, fed by the per-source normalization procedures in
-- sql/05_normalize_procedures.sql.
--
-- STG_MEMBER carries the derived columns required by deliverable #2:
--   • AGE          — birthday-aware years from DOB (NULL when DOB missing)
--   • STALE_MEMBER — TRUE when days since LAST_FLIGHT_DATE > 90 or NULL
-- =======================================================================

USE DATABASE SKYPOINTS;
USE SCHEMA   STG;

CREATE OR REPLACE TABLE STG_MEMBER (
    -- Canonical identity
    MEMBER_SK              VARCHAR(50),    -- '<SOURCE_COUNTRY>-<SOURCE_ID>' e.g. 'USA-3'
    SOURCE_COUNTRY         VARCHAR(3),     -- 'USA' | 'AUS' | 'IND' | ...
    SOURCE_ID              VARCHAR(20),    -- raw id as sent by the source

    -- Business attributes (common across sources)
    MEMBER_NAME            VARCHAR(255),
    TIER_CODE              VARCHAR(5),
    DOB                    DATE,
    ENROLLMENT_DATE        DATE,
    LAST_FLIGHT_DATE       DATE,
    SEGMENT                CHAR(1),        -- 'I'/'C' (IND source only; NULL otherwise)
    IS_ACTIVE              CHAR(1),        -- defaulted 'A' when source does not carry it
    STATE                  VARCHAR(5),
    POST_CODE              VARCHAR(10),
    COUNTRY_ISO3           VARCHAR(3),     -- resolved via STG.COUNTRY_REF

    -- Derived (deliverable #2)
    AGE                    NUMBER(3),
    STALE_MEMBER           BOOLEAN,

    -- Lineage
    SOURCE_FILE_NAME       VARCHAR,
    SOURCE_FILE_ROW_NUMBER NUMBER,
    LOAD_BATCH_ID          VARCHAR,
    LOAD_TS                TIMESTAMP_NTZ,

    -- Data quality
    DQ_STATUS              VARCHAR(16),    -- 'VALID' | 'QUARANTINED'
    DQ_ERRORS              ARRAY           -- list of error / warning codes
)
CLUSTER BY (COUNTRY_ISO3, LOAD_TS);

CREATE OR REPLACE TABLE STG_REDEMPTION (
    TXN_ID                 VARCHAR,
    MEMBER_ID              VARCHAR(20),    -- maps to STG_MEMBER.SOURCE_ID
    FEED_DATE              DATE,
    TXN_DATE               DATE,
    PARTNER                VARCHAR(100),
    MILES_REDEEMED         NUMBER(12,0),
    STATUS                 VARCHAR(20),
    SOURCE_FILE_NAME       VARCHAR,
    LOAD_BATCH_ID          VARCHAR,
    LOAD_TS                TIMESTAMP_NTZ,
    DQ_STATUS              VARCHAR(16),
    DQ_ERRORS              ARRAY
)
CLUSTER BY (MEMBER_ID, TXN_DATE);
