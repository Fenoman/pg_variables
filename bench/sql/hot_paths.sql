\set ON_ERROR_STOP on
\pset tuples_only on
\pset format aligned

SET jit = off;
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_variables;

\echo === provenance ===
SELECT current_setting('server_version') AS server_version,
       :iterations AS iterations, :text_iterations AS text_iterations,
       :record_iterations AS record_iterations;

\timing on

\echo === setup ===
SELECT pgv_free();
SELECT pgv_set('bench_scalar', 'int_value', 0);
SELECT pgv_set('bench_scalar', 'text_value', repeat('x', 32));

\echo === baseline (generate_series + count, no pgv call) ===
\echo baseline count(g)
SELECT count(g)
FROM (SELECT generate_series(1, :iterations) AS g) AS s;

\echo === generic scalar hot paths ===
\echo pgv_set int
SELECT count(pgv_set('bench_scalar', 'int_value', g::int))
FROM (SELECT generate_series(1, :iterations) AS g) AS s;

\echo pgv_get int
SELECT count(pgv_get('bench_scalar', 'int_value', NULL::int))
FROM (SELECT generate_series(1, :iterations) AS g) AS s;

\echo pgv_exists variable
SELECT count(pgv_exists('bench_scalar', 'int_value'))
FROM (SELECT generate_series(1, :iterations) AS g) AS s;

\echo pgv_get text32
SELECT count(pgv_get('bench_scalar', 'text_value', NULL::text))
FROM (SELECT generate_series(1, :iterations) AS g) AS s;

\echo pgv_set text32
SELECT count(pgv_set('bench_scalar', 'text_value', repeat('x', 32)))
FROM (SELECT generate_series(1, :text_iterations) AS g) AS s;

\if :run_typed
\echo === typed scalar wrappers ===
\echo pgv_set_int
SELECT count(pgv_set_int('bench_scalar', 'int_value', g::int))
FROM (SELECT generate_series(1, :iterations) AS g) AS s;

\echo pgv_get_int
SELECT count(pgv_get_int('bench_scalar', 'int_value'))
FROM (SELECT generate_series(1, :iterations) AS g) AS s;

\echo pgv_get_text
SELECT count(pgv_get_text('bench_scalar', 'text_value'))
FROM (SELECT generate_series(1, :iterations) AS g) AS s;

\echo pgv_set_text
SELECT count(pgv_set_text('bench_scalar', 'text_value', repeat('x', 32)))
FROM (SELECT generate_series(1, :text_iterations) AS g) AS s;
\endif

\if :run_records
\echo === small record/package paths ===
SELECT pgv_remove('bench_record') WHERE pgv_exists('bench_record');

\echo pgv_insert records
SELECT count(pgv_insert('bench_record', 'items',
                        ROW(g::int, ('value-' || g)::text),
                        false))
FROM (SELECT generate_series(1, :record_iterations) AS g) AS s;

\echo pgv_select records
SELECT count(*)
FROM pgv_select('bench_record', 'items') AS t(id int, val text);

\echo pgv_select by key
SELECT count(*)
FROM pgv_select('bench_record', 'items', (:record_iterations / 2)::int) AS t(id int, val text);

\echo pgv_list
SELECT count(*) FROM pgv_list();

\echo pgv_remove variable
SELECT pgv_remove('bench_record', 'items');

\echo pgv_free
SELECT pgv_free();
\endif
