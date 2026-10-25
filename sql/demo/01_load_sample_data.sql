-- =======================================================================
-- Loads the exact sample rows from the three source systems plus a sample
-- JSON redemption feed. Use this instead of PUT + COPY INTO when running
-- the demo on a trial account without an external stage.
-- =======================================================================

USE DATABASE SKYPOINTS;
USE SCHEMA   RAW;

-- -----------------------------------------------------------------------
-- USA source
-- -----------------------------------------------------------------------
INSERT INTO RAW_USA_MEMBERS (ID, NAME, TIER_CODE, ENROLLMENT_DATE, FLIGHT_DATE,
                              SOURCE_FILE_NAME, SOURCE_FILE_ROW_NUMBER, LOAD_BATCH_ID) VALUES
('1','Sam', 'PLT','6152022',   '8202022',   'usa_members.csv', 1, 'DEMO-001'),
('2','John','SLV','1052022',   '1152022',   'usa_members.csv', 2, 'DEMO-001'),
('3','Mike','GLD','12282021',  '12302021',  'usa_members.csv', 3, 'DEMO-001');

-- -----------------------------------------------------------------------
-- AUS source
--   Jonnathan's enrollment '2021-13-13' is invalid (month 13) → quarantine.
--   Mike's DOB is NULL → AGE will be NULL and WARN_DOB_MISSING fires.
-- -----------------------------------------------------------------------
INSERT INTO RAW_AUS_MEMBERS (UNIQUE_ID, MEMBER_NAME, TIER_TYPE,
                              DATE_OF_BIRTH, DATE_OF_ENROLLMENT, DATE_OF_FLIGHT,
                              SOURCE_FILE_NAME, SOURCE_FILE_ROW_NUMBER, LOAD_BATCH_ID) VALUES
('1','Mike',     'PLT', NULL,        '2022-05-11','2022-08-01','aus_members.csv', 1, 'DEMO-001'),
('2','Jonnathan','GLD','1997-12-13', '2021-13-13','2022-01-05','aus_members.csv', 2, 'DEMO-001'),
('3','Cristina', 'SLV','1998-03-12', '2022-03-12','2022-03-20','aus_members.csv', 3, 'DEMO-001');

-- -----------------------------------------------------------------------
-- IND source
-- -----------------------------------------------------------------------
INSERT INTO RAW_IND_MEMBERS (ID, NAME, DOB, TIER_CODE, ENROLLMENT_DATE,
                              INDIVIDUAL_OR_CORPORATE, FLIGHT_DATE,
                              SOURCE_FILE_NAME, SOURCE_FILE_ROW_NUMBER, LOAD_BATCH_ID) VALUES
('1','Vikas', '12/1/1998','SLV','1/1/2022',  'I','6/15/2022','ind_members.csv', 1, 'DEMO-001'),
('2','Rahul', '8/13/1982','GLD','3/5/2022',  'C','3/10/2022','ind_members.csv', 2, 'DEMO-001'),
('3','Sameer','8/13/1952','GLD','2/20/2022', 'I','2/25/2022','ind_members.csv', 3, 'DEMO-001');

-- -----------------------------------------------------------------------
-- JSON redemption feed — two documents, three transactions in total.
-- -----------------------------------------------------------------------
INSERT INTO RAW_REDEMPTION_FEED (RAW_JSON, SOURCE_FILE_NAME, SOURCE_FILE_ROW_NUMBER, LOAD_BATCH_ID)
SELECT PARSE_JSON($$
{
  "member_id": "1",
  "feed_date": "20240115",
  "redemptions": [
    { "txn_id": "RX10091", "txn_date": "20240110", "partner": "AeroLink",  "miles_redeemed": 12000, "status": "COMPLETED" },
    { "txn_id": "RX10092", "txn_date": "20240113", "partner": "SkyPoints", "miles_redeemed": 5000,  "status": "PENDING" }
  ]
}
$$), 'redemptions_20240115.json', 1, 'DEMO-001';

INSERT INTO RAW_REDEMPTION_FEED (RAW_JSON, SOURCE_FILE_NAME, SOURCE_FILE_ROW_NUMBER, LOAD_BATCH_ID)
SELECT PARSE_JSON($$
{
  "member_id": "3",
  "feed_date": "20240115",
  "redemptions": [
    { "txn_id": "RX10093", "txn_date": "20240114", "partner": "AeroLink", "miles_redeemed": 8000, "status": "COMPLETED" }
  ]
}
$$), 'redemptions_20240115.json', 2, 'DEMO-001';
