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
