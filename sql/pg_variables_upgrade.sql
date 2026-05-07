SET client_min_messages = warning;

-- Direct recreate-style upgrade paths to 1.4.0.
CREATE EXTENSION pg_variables VERSION '1.0';
SELECT extversion AS installed_version FROM pg_extension WHERE extname = 'pg_variables';
ALTER EXTENSION pg_variables UPDATE TO '1.4.0';
SELECT extversion AS upgraded_version FROM pg_extension WHERE extname = 'pg_variables';
SELECT pgv_set('upgrade_10', 'v', 10::int, false);
SELECT pgv_get('upgrade_10', 'v', NULL::int);
SELECT pgv_free();
DROP EXTENSION pg_variables;

CREATE EXTENSION pg_variables VERSION '1.0';
ALTER EXTENSION pg_variables UPDATE TO '1.1';
SELECT extversion AS installed_version FROM pg_extension WHERE extname = 'pg_variables';
ALTER EXTENSION pg_variables UPDATE TO '1.4.0';
SELECT extversion AS upgraded_version FROM pg_extension WHERE extname = 'pg_variables';
SELECT pgv_set_text('upgrade_11', 'v', 'eleven', false);
SELECT pgv_get_text('upgrade_11', 'v');
SELECT pgv_free();
DROP EXTENSION pg_variables;

CREATE EXTENSION pg_variables VERSION '1.0';
ALTER EXTENSION pg_variables UPDATE TO '1.2';
SELECT extversion AS installed_version FROM pg_extension WHERE extname = 'pg_variables';
ALTER EXTENSION pg_variables UPDATE TO '1.4.0';
SELECT extversion AS upgraded_version FROM pg_extension WHERE extname = 'pg_variables';
SELECT pgv_set('upgrade_12', 'arr', ARRAY[1, 2]::int[], false);
SELECT pgv_get('upgrade_12', 'arr', NULL::int[]);
SELECT pgv_free();
DROP EXTENSION pg_variables;

CREATE EXTENSION pg_variables VERSION '1.0';
ALTER EXTENSION pg_variables UPDATE TO '1.2';
-- There is no historical 1.3 install script in this tree, so simulate an
-- already-installed 1.3 catalog version and validate the direct 1.3 path.
DO $$
BEGIN
    EXECUTE $sql$CREATE FUNCTION pgv_count(text,text) RETURNS integer LANGUAGE sql AS 'SELECT 0'$sql$;
    EXECUTE $sql$CREATE FUNCTION pgv_exists_elem(text,text,integer) RETURNS boolean LANGUAGE sql AS 'SELECT false'$sql$;
    EXECUTE $sql$CREATE FUNCTION pgv_exists_elem(text,text,text) RETURNS boolean LANGUAGE sql AS 'SELECT false'$sql$;
    EXECUTE $sql$CREATE FUNCTION pgv_first(text,text,anyelement) RETURNS anyelement LANGUAGE sql AS 'SELECT $3'$sql$;
    EXECUTE $sql$CREATE FUNCTION pgv_last(text,text,anyelement) RETURNS anyelement LANGUAGE sql AS 'SELECT $3'$sql$;
    EXECUTE $sql$CREATE FUNCTION pgv_next(text,text,anyelement) RETURNS anyelement LANGUAGE sql AS 'SELECT $3'$sql$;
    EXECUTE $sql$CREATE FUNCTION pgv_prior(text,text,anyelement) RETURNS anyelement LANGUAGE sql AS 'SELECT $3'$sql$;
    EXECUTE $sql$CREATE FUNCTION pgv_get_elem(text,text,integer,anyelement) RETURNS anyelement LANGUAGE sql AS 'SELECT $4'$sql$;
    EXECUTE $sql$CREATE FUNCTION pgv_get_elem(text,text,text,anyelement) RETURNS anyelement LANGUAGE sql AS 'SELECT $4'$sql$;
    EXECUTE $sql$CREATE FUNCTION pgv_set_elem(text,text,integer,anyelement,boolean) RETURNS void LANGUAGE sql AS 'SELECT NULL::void'$sql$;
    EXECUTE $sql$CREATE FUNCTION pgv_set_elem(text,text,text,anyelement,boolean) RETURNS void LANGUAGE sql AS 'SELECT NULL::void'$sql$;
    EXECUTE $sql$CREATE FUNCTION pgv_remove_elem(text,text,integer) RETURNS void LANGUAGE sql AS 'SELECT NULL::void'$sql$;
    EXECUTE $sql$CREATE FUNCTION pgv_remove_elem(text,text,text) RETURNS void LANGUAGE sql AS 'SELECT NULL::void'$sql$;
    EXECUTE $sql$CREATE FUNCTION pgv_select_support(internal) RETURNS internal AS '$libdir/pg_variables', 'package_exists' LANGUAGE C STRICT$sql$;
    EXECUTE $sql$ALTER EXTENSION pg_variables ADD FUNCTION pgv_count(text,text)$sql$;
    EXECUTE $sql$ALTER EXTENSION pg_variables ADD FUNCTION pgv_exists_elem(text,text,integer)$sql$;
    EXECUTE $sql$ALTER EXTENSION pg_variables ADD FUNCTION pgv_exists_elem(text,text,text)$sql$;
    EXECUTE $sql$ALTER EXTENSION pg_variables ADD FUNCTION pgv_first(text,text,anyelement)$sql$;
    EXECUTE $sql$ALTER EXTENSION pg_variables ADD FUNCTION pgv_last(text,text,anyelement)$sql$;
    EXECUTE $sql$ALTER EXTENSION pg_variables ADD FUNCTION pgv_next(text,text,anyelement)$sql$;
    EXECUTE $sql$ALTER EXTENSION pg_variables ADD FUNCTION pgv_prior(text,text,anyelement)$sql$;
    EXECUTE $sql$ALTER EXTENSION pg_variables ADD FUNCTION pgv_get_elem(text,text,integer,anyelement)$sql$;
    EXECUTE $sql$ALTER EXTENSION pg_variables ADD FUNCTION pgv_get_elem(text,text,text,anyelement)$sql$;
    EXECUTE $sql$ALTER EXTENSION pg_variables ADD FUNCTION pgv_set_elem(text,text,integer,anyelement,boolean)$sql$;
    EXECUTE $sql$ALTER EXTENSION pg_variables ADD FUNCTION pgv_set_elem(text,text,text,anyelement,boolean)$sql$;
    EXECUTE $sql$ALTER EXTENSION pg_variables ADD FUNCTION pgv_remove_elem(text,text,integer)$sql$;
    EXECUTE $sql$ALTER EXTENSION pg_variables ADD FUNCTION pgv_remove_elem(text,text,text)$sql$;
    EXECUTE $sql$ALTER EXTENSION pg_variables ADD FUNCTION pgv_select_support(internal)$sql$;
END$$;
UPDATE pg_extension SET extversion = '1.3' WHERE extname = 'pg_variables';
SELECT extversion AS installed_version FROM pg_extension WHERE extname = 'pg_variables';
CREATE FUNCTION upgrade_dep_get()
RETURNS integer
LANGUAGE sql
AS $$SELECT pgv_get_int('upgrade_13', 'v', false)$$;
CREATE VIEW upgrade_dep_select AS
SELECT * FROM pgv_select('upgrade_13', 'r') AS t(id int, val text);
CREATE VIEW upgrade_dep_exists AS
SELECT pgv_exists('upgrade_13') AS package_exists,
       pgv_exists('upgrade_13', 'v') AS variable_exists;
ALTER EXTENSION pg_variables UPDATE TO '1.4.0';
SELECT extversion AS upgraded_version FROM pg_extension WHERE extname = 'pg_variables';
SELECT count(*) AS old_pgpro_13_functions_left
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = ANY (ARRAY[
    'pgv_count', 'pgv_exists_elem', 'pgv_first', 'pgv_last', 'pgv_next',
    'pgv_prior', 'pgv_get_elem', 'pgv_set_elem', 'pgv_remove_elem',
    'pgv_select_support'
  ]);
SELECT pgv_set_int('upgrade_13', 'v', 13, false);
SELECT upgrade_dep_get();
SELECT * FROM upgrade_dep_exists;
SELECT pgv_insert('upgrade_13', 'r', ROW(13::int, 'thirteen'::text), false);
SELECT * FROM upgrade_dep_select;
SELECT pgv_free();
DROP VIEW upgrade_dep_exists;
DROP VIEW upgrade_dep_select;
DROP FUNCTION upgrade_dep_get();
DROP EXTENSION pg_variables;
