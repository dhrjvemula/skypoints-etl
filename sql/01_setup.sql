-- =======================================================================
-- SkyPoints Loyalty ETL — Setup
-- Creates database, schemas, warehouses, file formats, internal stages,
-- and the country-code reference table. Idempotent — safe to re-run.
-- =======================================================================

CREATE DATABASE IF NOT EXISTS SKYPOINTS;
CREATE SCHEMA   IF NOT EXISTS SKYPOINTS.RAW;
CREATE SCHEMA   IF NOT EXISTS SKYPOINTS.STG;
CREATE SCHEMA   IF NOT EXISTS SKYPOINTS.MART;
CREATE SCHEMA   IF NOT EXISTS SKYPOINTS.DQ;
CREATE SCHEMA   IF NOT EXISTS SKYPOINTS.META;

-- Separate workloads so loader spikes don't starve transforms.
CREATE WAREHOUSE IF NOT EXISTS WH_LOAD
    WITH WAREHOUSE_SIZE = 'LARGE'
    AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Dedicated to COPY INTO / Snowpipe ingestion';

CREATE WAREHOUSE IF NOT EXISTS WH_TRANSFORM
    WITH WAREHOUSE_SIZE = 'XLARGE'
    AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Dedicated to normalization, dispatch, and DQ procedures';

USE DATABASE SKYPOINTS;

-- -----------------------------------------------------------------------
-- File formats
-- -----------------------------------------------------------------------
CREATE OR REPLACE FILE FORMAT RAW.FF_CSV_HEADER
    TYPE = CSV
    FIELD_DELIMITER = ','
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    TRIM_SPACE = TRUE
    EMPTY_FIELD_AS_NULL = TRUE
    REPLACE_INVALID_CHARACTERS = TRUE
    NULL_IF = ('', 'NULL', 'null');

CREATE OR REPLACE FILE FORMAT RAW.FF_PIPE
    TYPE = CSV
    FIELD_DELIMITER = '|'
    SKIP_HEADER = 0
    TRIM_SPACE = TRUE
    EMPTY_FIELD_AS_NULL = TRUE
    NULL_IF = ('', 'NULL', 'null');

CREATE OR REPLACE FILE FORMAT RAW.FF_JSON
    TYPE = JSON
    STRIP_OUTER_ARRAY = FALSE;

-- -----------------------------------------------------------------------
-- Internal stages (replace with external S3/Azure stages in production).
-- One stage per source so file-level lineage is unambiguous.
-- -----------------------------------------------------------------------
CREATE OR REPLACE STAGE RAW.STG_USA         FILE_FORMAT = RAW.FF_CSV_HEADER;
CREATE OR REPLACE STAGE RAW.STG_AUS         FILE_FORMAT = RAW.FF_CSV_HEADER;
CREATE OR REPLACE STAGE RAW.STG_IND         FILE_FORMAT = RAW.FF_CSV_HEADER;
CREATE OR REPLACE STAGE RAW.STG_REDEMPTIONS FILE_FORMAT = RAW.FF_JSON;

-- -----------------------------------------------------------------------
-- Country reference — resolves source-sent codes to ISO 3166-1 alpha-3.
-- Expand this table rather than hardcoding mappings into normalization SQL.
-- -----------------------------------------------------------------------
CREATE OR REPLACE TABLE STG.COUNTRY_REF (
    SOURCE_CODE   VARCHAR(10) PRIMARY KEY,
    COUNTRY_ISO3  VARCHAR(3)  NOT NULL,
    COUNTRY_NAME  VARCHAR(100) NOT NULL
);

INSERT INTO STG.COUNTRY_REF (SOURCE_CODE, COUNTRY_ISO3, COUNTRY_NAME) VALUES
    ('USA' ,'USA','United States'),
    ('US'  ,'USA','United States'),
    ('IND' ,'IND','India'),
    ('IN'  ,'IND','India'),
    ('AUS' ,'AUS','Australia'),
    ('AU'  ,'AUS','Australia'),
    ('CAN' ,'CAN','Canada'),
    ('PHIL','PHL','Philippines'),
    ('PH'  ,'PHL','Philippines');
