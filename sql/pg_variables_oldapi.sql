SET client_min_messages = warning;
DROP EXTENSION IF EXISTS pg_variables;

-- A pre-1.4 catalog still ships 3-argument setters (pgv_set*, pgv_insert)
-- bound to the current .so. Reading a non-existent is_transactional flag past
-- the end of fcinfo used to make the value transactional at random and lose it
-- on the implicit commit -- a silent data-loss window after pg_upgrade from
-- 1.0. The 3-argument form must store a plain, session-lived variable.
CREATE EXTENSION pg_variables VERSION '1.0';

-- Scalar setters (3-arg): value must survive its own autocommit.
SELECT pgv_set_int('oldapi', 'i', 1);
SELECT pgv_get_int('oldapi', 'i') AS scalar_int;
SELECT pgv_set('oldapi', 'g', 42::int);
SELECT pgv_get('oldapi', 'g', NULL::int) AS scalar_any;

-- Record insert (3-arg): rows must survive.
SELECT pgv_insert('oldapi', 'r', ROW (1::int, 'a'::text));
SELECT pgv_insert('oldapi', 'r', ROW (2::int, 'b'::text));
SELECT count(*) AS rec_rows FROM pgv_select('oldapi', 'r') AS t(i int, s text);

-- A getter with an explicit NULL strict flag falls back to strict = true.
SELECT pgv_get_int('oldapi', 'i', NULL::bool) AS strict_null_ok;

DROP EXTENSION pg_variables;
