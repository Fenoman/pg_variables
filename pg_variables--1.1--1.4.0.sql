/* contrib/pg_variables/pg_variables--1.1--1.4.0.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_variables UPDATE TO '1.4.0'" to load this file. \quit

SET LOCAL client_min_messages = warning;

-- Update surviving SQL objects in place and remove obsolete objects.

-- Scalar variables functions

CREATE OR REPLACE FUNCTION pgv_set(package text, name text, value anynonarray, is_transactional bool default false)
RETURNS void
AS 'MODULE_PATHNAME', 'variable_set_any'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_get(package text, name text, var_type anynonarray, strict bool default true)
RETURNS anynonarray
AS 'MODULE_PATHNAME', 'variable_get_any'
LANGUAGE C VOLATILE;

-- Functions to work with arrays

CREATE OR REPLACE FUNCTION pgv_set(package text, name text, value anyarray, is_transactional bool default false)
RETURNS void
AS 'MODULE_PATHNAME', 'variable_set_array'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_get(package text, name text, var_type anyarray, strict bool default true)
RETURNS anyarray
AS 'MODULE_PATHNAME', 'variable_get_array'
LANGUAGE C VOLATILE;

-- Deprecated scalar variables functions

CREATE OR REPLACE FUNCTION pgv_set_int(package text, name text, value int, is_transactional bool default false)
RETURNS void
AS 'MODULE_PATHNAME', 'variable_set_int'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_get_int(package text, name text, strict bool default true)
RETURNS int
AS 'MODULE_PATHNAME', 'variable_get_int'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_set_text(package text, name text, value text, is_transactional bool default false)
RETURNS void
AS 'MODULE_PATHNAME', 'variable_set_text'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_get_text(package text, name text, strict bool default true)
RETURNS text
AS 'MODULE_PATHNAME', 'variable_get_text'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_set_numeric(package text, name text, value numeric, is_transactional bool default false)
RETURNS void
AS 'MODULE_PATHNAME', 'variable_set_numeric'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_get_numeric(package text, name text, strict bool default true)
RETURNS numeric
AS 'MODULE_PATHNAME', 'variable_get_numeric'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_set_timestamp(package text, name text, value timestamp, is_transactional bool default false)
RETURNS void
AS 'MODULE_PATHNAME', 'variable_set_timestamp'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_get_timestamp(package text, name text, strict bool default true)
RETURNS timestamp
AS 'MODULE_PATHNAME', 'variable_get_timestamp'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_set_timestamptz(package text, name text, value timestamptz, is_transactional bool default false)
RETURNS void
AS 'MODULE_PATHNAME', 'variable_set_timestamptz'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_get_timestamptz(package text, name text, strict bool default true)
RETURNS timestamptz
AS 'MODULE_PATHNAME', 'variable_get_timestamptz'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_set_date(package text, name text, value date, is_transactional bool default false)
RETURNS void
AS 'MODULE_PATHNAME', 'variable_set_date'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_get_date(package text, name text, strict bool default true)
RETURNS date
AS 'MODULE_PATHNAME', 'variable_get_date'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_set_jsonb(package text, name text, value jsonb, is_transactional bool default false)
RETURNS void
AS 'MODULE_PATHNAME', 'variable_set_jsonb'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_get_jsonb(package text, name text, strict bool default true)
RETURNS jsonb
AS 'MODULE_PATHNAME', 'variable_get_jsonb'
LANGUAGE C VOLATILE;

-- Functions to work with records

CREATE OR REPLACE FUNCTION pgv_insert(package text, name text, r record, is_transactional bool default false)
RETURNS void
AS 'MODULE_PATHNAME', 'variable_insert'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_update(package text, name text, r record)
RETURNS boolean
AS 'MODULE_PATHNAME', 'variable_update'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_delete(package text, name text, value anynonarray)
RETURNS boolean
AS 'MODULE_PATHNAME', 'variable_delete'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_select(package text, name text)
RETURNS setof record
AS 'MODULE_PATHNAME', 'variable_select'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_select(package text, name text, value anynonarray)
RETURNS record
AS 'MODULE_PATHNAME', 'variable_select_by_value'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_select(package text, name text, value anyarray)
RETURNS setof record
AS 'MODULE_PATHNAME', 'variable_select_by_values'
LANGUAGE C VOLATILE;

-- Functions to work with packages

CREATE OR REPLACE FUNCTION pgv_exists(package text, name text)
RETURNS bool
AS 'MODULE_PATHNAME', 'variable_exists'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_exists(package text)
RETURNS bool
AS 'MODULE_PATHNAME', 'package_exists'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_remove(package text, name text)
RETURNS void
AS 'MODULE_PATHNAME', 'remove_variable'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_remove(package text)
RETURNS void
AS 'MODULE_PATHNAME', 'remove_package'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_free()
RETURNS void
AS 'MODULE_PATHNAME', 'remove_packages'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_list()
RETURNS TABLE(package text, name text, is_transactional bool)
AS 'MODULE_PATHNAME', 'get_packages_and_variables'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION pgv_stats()
RETURNS TABLE(package text, allocated_memory bigint)
AS 'MODULE_PATHNAME', 'get_packages_stats'
LANGUAGE C VOLATILE;

-- Obsolete functions removed from the 1.4.0 API.

-- Obsolete names can also belong to user functions outside this extension.
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
        'pgv_set_int(text,text,int)',
        'pgv_set_text(text,text,text)',
        'pgv_set_numeric(text,text,numeric)',
        'pgv_set_timestamp(text,text,timestamp)',
        'pgv_set_timestamptz(text,text,timestamptz)',
        'pgv_set_date(text,text,date)',
        'pgv_set_jsonb(text,text,jsonb)',
        'pgv_insert(text,text,record)',
        'pgv_count(text,text)',
        'pgv_select_support(internal)',
        'pgv_first(text,text,anyelement)',
        'pgv_last(text,text,anyelement)',
        'pgv_next(text,text,anyelement)',
        'pgv_prior(text,text,anyelement)',
        'pgv_get_elem(text,text,integer,anyelement)',
        'pgv_get_elem(text,text,text,anyelement)',
        'pgv_set_elem(text,text,integer,anyelement,bool)',
        'pgv_set_elem(text,text,text,anyelement,bool)',
        'pgv_exists_elem(text,text,integer)',
        'pgv_exists_elem(text,text,text)',
        'pgv_remove_elem(text,text,integer)',
        'pgv_remove_elem(text,text,text)'
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
