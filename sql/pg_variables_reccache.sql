SELECT pgv_free();

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
