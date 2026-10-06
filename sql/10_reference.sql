-- Reference data. Adding a country is a data change here, not a code change:
-- SP_ENSURE_COUNTRY_TABLES creates the Country Table from COUNTRY_REF.

CREATE TABLE IF NOT EXISTS COUNTRY_REF (
  country_code  VARCHAR(3)   NOT NULL PRIMARY KEY,  -- ISO 3166-1 alpha-3
  country_name  VARCHAR(100) NOT NULL,
  target_table  VARCHAR(255) NOT NULL UNIQUE        -- unquoted identifier, e.g. TABLE_INDIA
);

-- Every spelling the source has been seen to use, mapped to one Country.
CREATE TABLE IF NOT EXISTS COUNTRY_ALIAS (
  alias         VARCHAR(10) NOT NULL PRIMARY KEY,   -- upper-cased source value
  country_code  VARCHAR(3)  NOT NULL REFERENCES COUNTRY_REF (country_code)
);

CREATE TABLE IF NOT EXISTS TIER_REF (
  tier_code  VARCHAR(5)  NOT NULL PRIMARY KEY,
  tier_name  VARCHAR(50) NOT NULL
);

-- The Member File layout from the design document, as data. Header validation
-- reads it; header_name is the spelling used in the H record.
CREATE TABLE IF NOT EXISTS MEMBER_FILE_LAYOUT (
  header_name         VARCHAR(50)  NOT NULL PRIMARY KEY,
  spec_name           VARCHAR(50)  NOT NULL,
  spec_position       NUMBER(2)    NOT NULL,
  spec_data_type      VARCHAR(20)  NOT NULL,
  max_length          NUMBER(4)    NOT NULL,
  is_mandatory        BOOLEAN      NOT NULL,
  required_in_header  BOOLEAN      NOT NULL
);

MERGE INTO MEMBER_FILE_LAYOUT t
USING (
  SELECT column1 AS header_name, column2 AS spec_name, column3 AS spec_position,
         column4 AS spec_data_type, column5 AS max_length, column6 AS is_mandatory,
         column7 AS required_in_header
  FROM VALUES
    ('Member_Name',      'Member Name',      1,  'VARCHAR', 255, TRUE,  TRUE),
    ('Member_Id',        'Member ID',        2,  'VARCHAR', 18,  TRUE,  TRUE),
    ('Enrollment_Date',  'Enrollment Date',  3,  'DATE',    8,   TRUE,  TRUE),
    ('Last_Flight_Date', 'Last Flight Date', 4,  'DATE',    8,   FALSE, TRUE),
    ('Tier_Code',        'Tier Code',        5,  'CHAR',    5,   FALSE, TRUE),
    ('Agent_Name',       'Agent Name',       6,  'CHAR',    255, FALSE, TRUE),
    ('State',            'State',            7,  'CHAR',    5,   FALSE, TRUE),
    ('Country',          'Country',          8,  'CHAR',    5,   FALSE, TRUE),
    -- In the spec but absent from the sample file: accepted when present.
    ('Post_Code',        'Post Code',        9,  'INT',     5,   FALSE, FALSE),
    ('DOB',              'Date of Birth',    10, 'DATE',    8,   FALSE, TRUE),
    ('Is_Active',        'Active Member',    11, 'CHAR',    1,   FALSE, TRUE)
) s
ON t.header_name = s.header_name
WHEN MATCHED THEN UPDATE SET
  spec_name = s.spec_name, spec_position = s.spec_position, spec_data_type = s.spec_data_type,
  max_length = s.max_length, is_mandatory = s.is_mandatory, required_in_header = s.required_in_header
WHEN NOT MATCHED THEN INSERT
  (header_name, spec_name, spec_position, spec_data_type, max_length, is_mandatory, required_in_header)
  VALUES (s.header_name, s.spec_name, s.spec_position, s.spec_data_type, s.max_length,
          s.is_mandatory, s.required_in_header);

MERGE INTO COUNTRY_REF t
USING (
  SELECT column1 AS country_code, column2 AS country_name, column3 AS target_table
  FROM VALUES
    ('USA', 'United States', 'TABLE_USA'),
    ('IND', 'India',         'TABLE_INDIA'),
    ('PHL', 'Philippines',   'TABLE_PHILIPPINES'),
    ('CAN', 'Canada',        'TABLE_CANADA'),
    ('AUS', 'Australia',     'TABLE_AUSTRALIA')
) s
ON t.country_code = s.country_code
WHEN MATCHED THEN UPDATE SET country_name = s.country_name, target_table = s.target_table
WHEN NOT MATCHED THEN INSERT (country_code, country_name, target_table)
  VALUES (s.country_code, s.country_name, s.target_table);

MERGE INTO COUNTRY_ALIAS t
USING (
  SELECT column1 AS alias, column2 AS country_code
  FROM VALUES
    ('USA', 'USA'), ('US', 'USA'),
    ('IND', 'IND'), ('IN', 'IND'),
    ('PHL', 'PHL'), ('PH', 'PHL'), ('PHIL', 'PHL'),
    ('CAN', 'CAN'), ('CA', 'CAN'),
    ('AUS', 'AUS'), ('AU', 'AUS')
) s
ON t.alias = s.alias
WHEN MATCHED THEN UPDATE SET country_code = s.country_code
WHEN NOT MATCHED THEN INSERT (alias, country_code) VALUES (s.alias, s.country_code);

MERGE INTO TIER_REF t
USING (
  SELECT column1 AS tier_code, column2 AS tier_name
  FROM VALUES ('SLV', 'Silver'), ('GLD', 'Gold'), ('PLT', 'Platinum')
) s
ON t.tier_code = s.tier_code
WHEN MATCHED THEN UPDATE SET tier_name = s.tier_name
WHEN NOT MATCHED THEN INSERT (tier_code, tier_name) VALUES (s.tier_code, s.tier_name);
