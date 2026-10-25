-- =======================================================================
-- Per-source normalization procedures.
--
-- Each source has its own SP so source-specific quirks (date formats,
-- column names, missing attributes) live in exactly one place. Every SP:
--   • Reads only rows for the given batch id from RAW
--   • Casts to canonical types with TRY_TO_* so bad values become NULL
--     rather than aborting the load
--   • Builds MEMBER_SK = '<SOURCE_COUNTRY>-<SOURCE_ID>'
--   • Derives AGE (birthday-aware) and STALE_MEMBER (deliverable #2)
--   • Tags each row with DQ_STATUS + an array of error / warning codes
--   • Inserts into STG.STG_MEMBER
--
-- Quarantining (moving QUARANTINED rows out of STG) is a separate step
-- performed by SP_QUARANTINE_MEMBER in sql/08_dq_framework.sql.
-- =======================================================================

USE DATABASE SKYPOINTS;
USE SCHEMA   STG;

-- -----------------------------------------------------------------------
-- SP_NORMALIZE_USA
--   Date format: MMDDYYYY with leading zeros stripped ('6152022' = 2022-06-15).
--   No DOB in source → AGE is always NULL for USA members. Flagged as a
--   WARN so the gap is observable in DQ metrics.
-- -----------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_NORMALIZE_USA(P_BATCH_ID STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    v_count NUMBER;
BEGIN
    INSERT INTO STG_MEMBER
    WITH src AS (
        SELECT
            NULLIF(TRIM(ID),   '')                                        AS source_id,
            NULLIF(TRIM(NAME), '')                                        AS member_name,
            UPPER(NULLIF(TRIM(TIER_CODE), ''))                            AS tier_code,
            TRY_TO_DATE(LPAD(TRIM(ENROLLMENT_DATE), 8, '0'), 'MMDDYYYY')  AS enrollment_date,
            TRY_TO_DATE(LPAD(TRIM(FLIGHT_DATE),     8, '0'), 'MMDDYYYY')  AS last_flight_date,
            ENROLLMENT_DATE AS enrollment_raw,
            FLIGHT_DATE     AS flight_raw,
            SOURCE_FILE_NAME, SOURCE_FILE_ROW_NUMBER, LOAD_BATCH_ID, LOAD_TS
        FROM RAW.RAW_USA_MEMBERS
        WHERE LOAD_BATCH_ID = :P_BATCH_ID
    ),
    enriched AS (
        SELECT
            s.*,
            'USA-' || source_id   AS member_sk,
            'USA'                 AS source_country,
            CAST(NULL AS DATE)    AS dob,
            CAST(NULL AS CHAR(1)) AS segment,
            'A'                   AS is_active,
            CAST(NULL AS VARCHAR) AS state,
            CAST(NULL AS VARCHAR) AS post_code,
            'USA'                 AS country_iso3,
            CAST(NULL AS NUMBER)  AS age,
            CASE
                WHEN last_flight_date IS NULL THEN TRUE
                WHEN DATEDIFF(DAY, last_flight_date, CURRENT_DATE) > 90 THEN TRUE
                ELSE FALSE
            END                   AS stale_member
        FROM src s
    ),
    dq AS (
        SELECT e.*,
               ARRAY_COMPACT(ARRAY_CONSTRUCT(
                   IFF(source_id   IS NULL,                   'ERR_ID_NULL',                   NULL),
                   IFF(member_name IS NULL,                   'ERR_NAME_NULL',                 NULL),
                   IFF(enrollment_date IS NULL AND enrollment_raw IS NOT NULL,
                                                              'ERR_ENROLLMENT_UNPARSEABLE',    NULL),
                   IFF(enrollment_date IS NULL AND enrollment_raw IS NULL,
                                                              'ERR_ENROLLMENT_NULL',           NULL),
                   IFF(last_flight_date IS NULL AND flight_raw IS NOT NULL,
                                                              'WARN_FLIGHT_UNPARSEABLE',       NULL),
                   IFF(last_flight_date IS NOT NULL AND enrollment_date IS NOT NULL
                        AND last_flight_date < enrollment_date,
                                                              'ERR_FLIGHT_BEFORE_ENROLLMENT',  NULL),
                   IFF(tier_code NOT IN ('GLD','SLV','PLT','BRZ','DIA') AND tier_code IS NOT NULL,
                                                              'WARN_UNKNOWN_TIER',             NULL),
                   -- deterministic flag — USA source does not provide DOB
                   'WARN_NO_DOB_FROM_SOURCE'
               )) AS dq_errors
        FROM enriched e
    )
    SELECT
        member_sk, source_country, source_id, member_name, tier_code, dob,
        enrollment_date, last_flight_date, segment, is_active, state, post_code,
        country_iso3, age, stale_member,
        source_file_name, source_file_row_number, load_batch_id, load_ts,
        IFF(ARRAY_SIZE(ARRAY_INTERSECTION(dq_errors,
            ARRAY_CONSTRUCT('ERR_ID_NULL','ERR_NAME_NULL',
                            'ERR_ENROLLMENT_UNPARSEABLE','ERR_ENROLLMENT_NULL',
                            'ERR_FLIGHT_BEFORE_ENROLLMENT'))) > 0,
            'QUARANTINED', 'VALID')          AS dq_status,
        dq_errors
    FROM dq;

    v_count := SQLROWCOUNT;
    RETURN 'SP_NORMALIZE_USA batch=' || :P_BATCH_ID || ' rows=' || v_count::STRING;
END;
$$;

-- -----------------------------------------------------------------------
-- SP_NORMALIZE_AUS
--   Date format: ISO YYYY-MM-DD.
--   Known DQ hazard: sample contains '2021-13-13' (invalid month) which
--   must quarantine via ERR_ENROLLMENT_INVALID_DATE.
-- -----------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_NORMALIZE_AUS(P_BATCH_ID STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    v_count NUMBER;
BEGIN
    INSERT INTO STG_MEMBER
    WITH src AS (
        SELECT
            NULLIF(TRIM(UNIQUE_ID),   '')                        AS source_id,
            NULLIF(TRIM(MEMBER_NAME), '')                        AS member_name,
            UPPER(NULLIF(TRIM(TIER_TYPE), ''))                   AS tier_code,
            TRY_TO_DATE(TRIM(DATE_OF_BIRTH),      'YYYY-MM-DD')  AS dob,
            TRY_TO_DATE(TRIM(DATE_OF_ENROLLMENT), 'YYYY-MM-DD')  AS enrollment_date,
            TRY_TO_DATE(TRIM(DATE_OF_FLIGHT),     'YYYY-MM-DD')  AS last_flight_date,
            DATE_OF_BIRTH      AS dob_raw,
            DATE_OF_ENROLLMENT AS enrollment_raw,
            DATE_OF_FLIGHT     AS flight_raw,
            SOURCE_FILE_NAME, SOURCE_FILE_ROW_NUMBER, LOAD_BATCH_ID, LOAD_TS
        FROM RAW.RAW_AUS_MEMBERS
        WHERE LOAD_BATCH_ID = :P_BATCH_ID
    ),
    enriched AS (
        SELECT
            s.*,
            'AUS-' || source_id   AS member_sk,
            'AUS'                 AS source_country,
            CAST(NULL AS CHAR(1)) AS segment,
            'A'                   AS is_active,
            CAST(NULL AS VARCHAR) AS state,
            CAST(NULL AS VARCHAR) AS post_code,
            'AUS'                 AS country_iso3,
            CASE
                WHEN dob IS NULL THEN NULL
                ELSE DATEDIFF(YEAR, dob, CURRENT_DATE)
                     - IFF(TO_CHAR(dob,'MMDD') > TO_CHAR(CURRENT_DATE,'MMDD'), 1, 0)
            END                   AS age,
            CASE
                WHEN last_flight_date IS NULL THEN TRUE
                WHEN DATEDIFF(DAY, last_flight_date, CURRENT_DATE) > 90 THEN TRUE
                ELSE FALSE
            END                   AS stale_member
        FROM src s
    ),
    dq AS (
        SELECT e.*,
               ARRAY_COMPACT(ARRAY_CONSTRUCT(
                   IFF(source_id   IS NULL,                   'ERR_ID_NULL',                   NULL),
                   IFF(member_name IS NULL,                   'ERR_NAME_NULL',                 NULL),
                   IFF(enrollment_date IS NULL AND enrollment_raw IS NOT NULL,
                                                              'ERR_ENROLLMENT_INVALID_DATE',   NULL),
                   IFF(enrollment_date IS NULL AND enrollment_raw IS NULL,
                                                              'ERR_ENROLLMENT_NULL',           NULL),
                   IFF(dob IS NULL AND dob_raw IS NOT NULL,
                                                              'WARN_DOB_UNPARSEABLE',          NULL),
                   IFF(dob IS NULL AND dob_raw IS NULL,
                                                              'WARN_DOB_MISSING',              NULL),
                   IFF(last_flight_date IS NULL AND flight_raw IS NOT NULL,
                                                              'WARN_FLIGHT_UNPARSEABLE',       NULL),
                   IFF(last_flight_date IS NOT NULL AND enrollment_date IS NOT NULL
                        AND last_flight_date < enrollment_date,
                                                              'ERR_FLIGHT_BEFORE_ENROLLMENT',  NULL),
                   IFF(age IS NOT NULL AND (age < 0 OR age > 120),
                                                              'ERR_AGE_OUT_OF_RANGE',          NULL),
                   IFF(tier_code NOT IN ('GLD','SLV','PLT','BRZ','DIA') AND tier_code IS NOT NULL,
                                                              'WARN_UNKNOWN_TIER',             NULL)
               )) AS dq_errors
        FROM enriched e
    )
    SELECT
        member_sk, source_country, source_id, member_name, tier_code, dob,
        enrollment_date, last_flight_date, segment, is_active, state, post_code,
        country_iso3, age, stale_member,
        source_file_name, source_file_row_number, load_batch_id, load_ts,
        IFF(ARRAY_SIZE(ARRAY_INTERSECTION(dq_errors,
            ARRAY_CONSTRUCT('ERR_ID_NULL','ERR_NAME_NULL',
                            'ERR_ENROLLMENT_INVALID_DATE','ERR_ENROLLMENT_NULL',
                            'ERR_FLIGHT_BEFORE_ENROLLMENT','ERR_AGE_OUT_OF_RANGE'))) > 0,
            'QUARANTINED', 'VALID') AS dq_status,
        dq_errors
    FROM dq;

    v_count := SQLROWCOUNT;
    RETURN 'SP_NORMALIZE_AUS batch=' || :P_BATCH_ID || ' rows=' || v_count::STRING;
END;
$$;

-- -----------------------------------------------------------------------
-- SP_NORMALIZE_IND
--   Date format: US-style M/D/YYYY (single or double digits accepted).
--   Extra attribute: SEGMENT ∈ {I, C} from "Individual or Corporate".
-- -----------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_NORMALIZE_IND(P_BATCH_ID STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    v_count NUMBER;
BEGIN
    INSERT INTO STG_MEMBER
    WITH src AS (
        SELECT
            NULLIF(TRIM(ID),   '')                                       AS source_id,
            NULLIF(TRIM(NAME), '')                                       AS member_name,
            TRY_TO_DATE(TRIM(DOB),             'MM/DD/YYYY')             AS dob,
            UPPER(NULLIF(TRIM(TIER_CODE), ''))                           AS tier_code,
            TRY_TO_DATE(TRIM(ENROLLMENT_DATE), 'MM/DD/YYYY')             AS enrollment_date,
            UPPER(LEFT(NULLIF(TRIM(INDIVIDUAL_OR_CORPORATE),''),1))      AS segment,
            TRY_TO_DATE(TRIM(FLIGHT_DATE),     'MM/DD/YYYY')             AS last_flight_date,
            DOB AS dob_raw, ENROLLMENT_DATE AS enrollment_raw, FLIGHT_DATE AS flight_raw,
            SOURCE_FILE_NAME, SOURCE_FILE_ROW_NUMBER, LOAD_BATCH_ID, LOAD_TS
        FROM RAW.RAW_IND_MEMBERS
        WHERE LOAD_BATCH_ID = :P_BATCH_ID
    ),
    enriched AS (
        SELECT
            s.*,
            'IND-' || source_id   AS member_sk,
            'IND'                 AS source_country,
            'A'                   AS is_active,
            CAST(NULL AS VARCHAR) AS state,
            CAST(NULL AS VARCHAR) AS post_code,
            'IND'                 AS country_iso3,
            CASE
                WHEN dob IS NULL THEN NULL
                ELSE DATEDIFF(YEAR, dob, CURRENT_DATE)
                     - IFF(TO_CHAR(dob,'MMDD') > TO_CHAR(CURRENT_DATE,'MMDD'), 1, 0)
            END                   AS age,
            CASE
                WHEN last_flight_date IS NULL THEN TRUE
                WHEN DATEDIFF(DAY, last_flight_date, CURRENT_DATE) > 90 THEN TRUE
                ELSE FALSE
            END                   AS stale_member
        FROM src s
    ),
    dq AS (
        SELECT e.*,
               ARRAY_COMPACT(ARRAY_CONSTRUCT(
                   IFF(source_id   IS NULL,                   'ERR_ID_NULL',                   NULL),
                   IFF(member_name IS NULL,                   'ERR_NAME_NULL',                 NULL),
                   IFF(enrollment_date IS NULL AND enrollment_raw IS NOT NULL,
                                                              'ERR_ENROLLMENT_UNPARSEABLE',    NULL),
                   IFF(enrollment_date IS NULL AND enrollment_raw IS NULL,
                                                              'ERR_ENROLLMENT_NULL',           NULL),
                   IFF(dob IS NULL AND dob_raw IS NOT NULL,
                                                              'WARN_DOB_UNPARSEABLE',          NULL),
                   IFF(last_flight_date IS NULL AND flight_raw IS NOT NULL,
                                                              'WARN_FLIGHT_UNPARSEABLE',       NULL),
                   IFF(last_flight_date IS NOT NULL AND enrollment_date IS NOT NULL
                        AND last_flight_date < enrollment_date,
                                                              'ERR_FLIGHT_BEFORE_ENROLLMENT',  NULL),
                   IFF(age IS NOT NULL AND (age < 0 OR age > 120),
                                                              'ERR_AGE_OUT_OF_RANGE',          NULL),
                   IFF(segment NOT IN ('I','C') AND segment IS NOT NULL,
                                                              'WARN_UNKNOWN_SEGMENT',          NULL),
                   IFF(tier_code NOT IN ('GLD','SLV','PLT','BRZ','DIA') AND tier_code IS NOT NULL,
                                                              'WARN_UNKNOWN_TIER',             NULL)
               )) AS dq_errors
        FROM enriched e
    )
    SELECT
        member_sk, source_country, source_id, member_name, tier_code, dob,
        enrollment_date, last_flight_date, segment, is_active, state, post_code,
        country_iso3, age, stale_member,
        source_file_name, source_file_row_number, load_batch_id, load_ts,
        IFF(ARRAY_SIZE(ARRAY_INTERSECTION(dq_errors,
            ARRAY_CONSTRUCT('ERR_ID_NULL','ERR_NAME_NULL',
                            'ERR_ENROLLMENT_UNPARSEABLE','ERR_ENROLLMENT_NULL',
                            'ERR_FLIGHT_BEFORE_ENROLLMENT','ERR_AGE_OUT_OF_RANGE'))) > 0,
            'QUARANTINED', 'VALID') AS dq_status,
        dq_errors
    FROM dq;

    v_count := SQLROWCOUNT;
    RETURN 'SP_NORMALIZE_IND batch=' || :P_BATCH_ID || ' rows=' || v_count::STRING;
END;
$$;
