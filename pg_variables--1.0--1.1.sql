/* contrib/pg_variables/pg_variables--1.0--1.1.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_variables UPDATE TO '1.1'" to load this file. \quit

-- Remove obsolete signatures only when they belong to this extension.
DO $pg_variables_upgrade$
DECLARE
    function_signature text;
    function_oid oid;
    extension_oid oid;
BEGIN
    SELECT oid INTO STRICT extension_oid
    FROM pg_catalog.pg_extension WHERE extname = 'pg_variables';
    FOREACH function_signature IN ARRAY ARRAY[
        'pgv_set(text,text,anynonarray)',
        'pgv_set_int(text,text,integer)',
        'pgv_set_text(text,text,text)',
        'pgv_set_numeric(text,text,numeric)',
        'pgv_set_timestamp(text,text,timestamp without time zone)',
        'pgv_set_timestamptz(text,text,timestamp with time zone)',
        'pgv_set_date(text,text,date)',
        'pgv_set_jsonb(text,text,jsonb)',
        'pgv_insert(text,text,record)',
        'pgv_list()'
    ] LOOP
        function_oid := pg_catalog.to_regprocedure(function_signature);
        IF function_oid IS NULL THEN
            CONTINUE;
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM pg_catalog.pg_depend
            WHERE classid = 'pg_catalog.pg_proc'::pg_catalog.regclass
              AND objid = function_oid AND objsubid = 0
              AND refclassid = 'pg_catalog.pg_extension'::pg_catalog.regclass
              AND refobjid = extension_oid AND deptype = 'e'
        ) THEN
            RAISE EXCEPTION 'cannot remove function %: it is not a member of pg_variables',
                            function_oid::pg_catalog.regprocedure
                USING ERRCODE = '55000';
        END IF;
        EXECUTE pg_catalog.format('DROP FUNCTION %s',
                                  function_oid::pg_catalog.regprocedure);
    END LOOP;
END
$pg_variables_upgrade$;

-- Create new versions of setters
CREATE FUNCTION pgv_set(package text, name text, value anynonarray, is_transactional bool default false)
RETURNS void
AS 'MODULE_PATHNAME', 'variable_set_any'
LANGUAGE C VOLATILE;

CREATE FUNCTION pgv_set_int(package text, name text, value int, is_transactional bool default false)
RETURNS void
AS 'MODULE_PATHNAME', 'variable_set_int'
LANGUAGE C VOLATILE;

CREATE FUNCTION pgv_set_text(package text, name text, value text, is_transactional bool default false)
RETURNS void
AS 'MODULE_PATHNAME', 'variable_set_text'
LANGUAGE C VOLATILE;

CREATE FUNCTION pgv_set_numeric(package text, name text, value numeric, is_transactional bool default false)
RETURNS void
AS 'MODULE_PATHNAME', 'variable_set_numeric'
LANGUAGE C VOLATILE;

CREATE FUNCTION pgv_set_timestamp(package text, name text, value timestamp, is_transactional bool default false)
RETURNS void
AS 'MODULE_PATHNAME', 'variable_set_timestamp'
LANGUAGE C VOLATILE;

CREATE FUNCTION pgv_set_timestamptz(package text, name text, value timestamptz, is_transactional bool default false)
RETURNS void
AS 'MODULE_PATHNAME', 'variable_set_timestamptz'
LANGUAGE C VOLATILE;

CREATE FUNCTION pgv_set_date(package text, name text, value date, is_transactional bool default false)
RETURNS void
AS 'MODULE_PATHNAME', 'variable_set_date'
LANGUAGE C VOLATILE;

CREATE FUNCTION pgv_set_jsonb(package text, name text, value jsonb, is_transactional bool default false)
RETURNS void
AS 'MODULE_PATHNAME', 'variable_set_jsonb'
LANGUAGE C VOLATILE;

CREATE FUNCTION pgv_insert(package text, name text, r record, is_transactional bool default false)
RETURNS void
AS 'MODULE_PATHNAME', 'variable_insert'
LANGUAGE C VOLATILE;

-- pgv_list() changed output
CREATE FUNCTION pgv_list()
RETURNS TABLE(package text, name text, is_transactional bool)
AS 'MODULE_PATHNAME', 'get_packages_and_variables'
LANGUAGE C VOLATILE;
