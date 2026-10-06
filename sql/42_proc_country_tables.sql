-- Country Tables (ADR 0001): one physical table per row of COUNTRY_REF.

-- Creates any missing Country Table, shaped LIKE MEMBER_HUB. Table names come
-- from reference data and are spliced into DDL, so they are validated first.
CREATE OR REPLACE PROCEDURE SP_ENSURE_COUNTRY_TABLES()
RETURNS ARRAY
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  bad_reference EXCEPTION (-20001, 'COUNTRY_REF holds an invalid country_code or target_table');
  countries CURSOR FOR SELECT country_code, target_table FROM COUNTRY_REF ORDER BY country_code;
  stmt VARCHAR;
  tables ARRAY DEFAULT ARRAY_CONSTRUCT();
BEGIN
  FOR c IN countries DO
    IF (NOT REGEXP_LIKE(c.country_code, '[A-Z]{3}')
        OR NOT REGEXP_LIKE(c.target_table, '[A-Z][A-Z0-9_]{0,254}')) THEN
      RAISE bad_reference;
    END IF;
    stmt := 'CREATE TABLE IF NOT EXISTS ' || c.target_table || ' LIKE MEMBER_HUB';
    EXECUTE IMMEDIATE :stmt;
    tables := ARRAY_APPEND(tables, c.target_table);
  END FOR;
  RETURN tables;
END;
$$;

-- Member Hub -> Country Tables, for the Members the last hub MERGE touched.
--
-- MEMBER_HUB_STREAM yields both row images of every changed Member: the old
-- one (old country) and the new one. For each affected country, the changed
-- Members are deleted and their current hub rows for that country inserted.
-- A Country Move therefore deletes from the old table and inserts into the
-- new one in the same transaction: a Member is never in two Country Tables.
CREATE OR REPLACE PROCEDURE SP_REFRESH_COUNTRY_TABLES()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  affected CURSOR FOR
    SELECT r.country_code, r.target_table
    FROM COUNTRY_REF r
    WHERE r.country_code IN (SELECT country_code FROM WRK_HUB_CHANGES)
    ORDER BY r.country_code;
  stmt VARCHAR;
  changed_members NUMBER;
  refreshed ARRAY DEFAULT ARRAY_CONSTRUCT();
BEGIN
  -- DDL commits implicitly, so it must run before the transaction opens.
  CALL SP_ENSURE_COUNTRY_TABLES();

  BEGIN TRANSACTION;

  DELETE FROM WRK_HUB_CHANGES;
  INSERT INTO WRK_HUB_CHANGES (member_id, country_code)
    SELECT DISTINCT member_id, country_code FROM MEMBER_HUB_STREAM;
  changed_members := (SELECT COUNT(DISTINCT member_id) FROM WRK_HUB_CHANGES);

  FOR c IN affected DO
    stmt := 'DELETE FROM ' || c.target_table
         || ' WHERE member_id IN (SELECT member_id FROM WRK_HUB_CHANGES)';
    EXECUTE IMMEDIATE :stmt;

    stmt := 'INSERT INTO ' || c.target_table
         || ' SELECT h.* FROM MEMBER_HUB h'
         || ' WHERE h.country_code = ''' || c.country_code || ''''
         || ' AND h.member_id IN (SELECT member_id FROM WRK_HUB_CHANGES)';
    EXECUTE IMMEDIATE :stmt;

    refreshed := ARRAY_APPEND(refreshed, c.target_table);
  END FOR;

  COMMIT;
  RETURN OBJECT_CONSTRUCT('changed_members', changed_members, 'tables_refreshed', refreshed);

EXCEPTION
  WHEN OTHER THEN
    ROLLBACK;
    RAISE;
END;
$$;
