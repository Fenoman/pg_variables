SELECT pgv_free();

-- Untyped fields and subsequent typed rows share a complete TEXT descriptor.
-- Record output uses the saved descriptor, including alignment and offsets.
DO $$
DECLARE
    payload_size integer;
BEGIN
    FOREACH payload_size IN ARRAY ARRAY[1, 126, 200, 32768] LOOP
        PERFORM pgv_insert('layout_smallint', 'r',
                           ROW(1::smallint, 'first', 7::bigint));
        PERFORM pgv_insert('layout_smallint', 'r',
                           ROW(2::smallint, repeat('y', payload_size), 9::bigint));
        IF pgv_select('layout_smallint', 'r', 2::smallint)::text
           IS DISTINCT FROM '(2,' || repeat('y', payload_size) || ',9)' THEN
            RAISE EXCEPTION 'converted descriptor changed typed row values';
        END IF;
        PERFORM pgv_insert('layout_bool', 'r', ROW(false, NULL));
        PERFORM pgv_insert('layout_bool', 'r',
                           ROW(true, repeat('z', payload_size)));
        IF pgv_select('layout_bool', 'r', true)::text
           IS DISTINCT FROM '(t,' || repeat('z', payload_size) || ')' THEN
            RAISE EXCEPTION 'converted NULL descriptor changed typed row values';
        END IF;
        PERFORM pgv_remove('layout_smallint');
        PERFORM pgv_remove('layout_bool');
    END LOOP;
END
$$;

-- pgv_insert() caches the last validated input rowtype so that a bulk insert of
-- identical records can skip the per-row tuple-descriptor lookup and attribute
-- check. These tests pin the behavior that must stay identical with or without
-- that cache: every structural check still fires, duplicate keys are still
-- rejected, and UNKNOWN literals are still coerced on every row.

-- Bulk insert of one anonymous rowtype: all rows land.
SELECT count(*) FROM (SELECT pgv_insert('p','r', row(g, 'v'||g)) FROM generate_series(1,5) g) t;
SELECT count(*) AS stored FROM pgv_select('p','r') AS x(k int, v text);

-- One more of the same structure (fast path), then a duplicate key: rejected.
SELECT pgv_insert('p','r', row(6, 'v6'::text));
SELECT pgv_insert('p','r', row(6, 'dup'::text));

-- A mismatching structure is still rejected even after the type was cached.
SELECT pgv_insert('p','r', row(7, 8));
SELECT pgv_insert('p','r', row(9, 'x'::text, 10));

-- The good structure still inserts afterwards.
SELECT pgv_insert('p','r', row(7, 'v7'::text));
SELECT k, v FROM pgv_select('p','r') AS x(k int, v text) ORDER BY k;
SELECT pgv_free();

-- UNKNOWN literals must be coerced to text on every row; the fast path must not
-- skip that coercion.
SELECT count(*) FROM (SELECT pgv_insert('u','r', row(g, 'lit')) FROM generate_series(1,4) g) t;
SELECT k, v FROM pgv_select('u','r') AS x(k int, v text) ORDER BY k;
SELECT pgv_free();

-- Interleaving a second, incompatible rowtype must not be masked by the cache;
-- switching back to the first rowtype must still work.
SELECT pgv_insert('m','r', row(1, 'a'::text));
SELECT pgv_insert('m','r', row(2, 2));
SELECT pgv_insert('m','r', row(3, 'c'::text));
SELECT k, v FROM pgv_select('m','r') AS x(k int, v text) ORDER BY k;
SELECT pgv_free();
