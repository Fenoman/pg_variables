SELECT pgv_free();

-- Cache hits must not bypass record/scalar type validation.
SELECT pgv_set('cache', 'same', 1::int);
SELECT pgv_insert('cache', 'same', ROW (1::int), FALSE); -- fail
SELECT pgv_select('cache', 'same'); -- fail
SELECT pgv_free();

-- A by-reference scalar value returned by pgv_get() must not alias the
-- stored value that can be replaced later in the same statement.
SELECT pgv_set('lifetime', 'textval', 'aaaaaaaa'::text);
SELECT pgv_get('lifetime', 'textval', NULL::text) AS before_set,
       pgv_set('lifetime', 'textval', 'bbbbbbbb'::text) AS set_again;
SELECT pgv_get('lifetime', 'textval', NULL::text) AS after_set;

SELECT pgv_free();

-- Re-creating a transactional record variable after pgv_remove(package)
-- must discard the old record hash context instead of accumulating it.
BEGIN;
SELECT pgv_insert('test', 'x', ROW (1::int), TRUE);
CREATE TEMP TABLE pgv_lifetime_stats(before_remove bigint);
INSERT INTO pgv_lifetime_stats
SELECT allocated_memory FROM pgv_stats() WHERE package = 'test';
SELECT pgv_remove('test');
SELECT pgv_insert('test', 'x', ROW (1::int), TRUE);
SELECT pgv_exists('test') AS package_exists,
       pgv_exists('test', 'x') AS variable_exists,
       (SELECT count(*) FROM pgv_select('test', 'x') AS t(id int)) AS rows_after_reinsert,
       (SELECT allocated_memory FROM pgv_stats() WHERE package = 'test') <=
       (SELECT before_remove FROM pgv_lifetime_stats) AS record_context_reused;
COMMIT;
DROP TABLE pgv_lifetime_stats;
SELECT pgv_free();

-- Keep an expression-built array argument alive for all calls of
-- pgv_select(package, name, anyarray).
SELECT pgv_insert('lifetime', 'rec', ROW (1::int, 'one'::text));
SELECT pgv_insert('lifetime', 'rec', ROW (2::int, 'two'::text));
SELECT * FROM pgv_select('lifetime', 'rec',
                         ARRAY(SELECT generate_series(1, 2))) AS t(id int, label text)
ORDER BY id;
SELECT pgv_free();

-- Active pgv_select(package, name, anyarray) cursors must be invalidated
-- before the underlying record variable can be freed by pgv_free().
SELECT pgv_insert('lifetime', 'rec', ROW (1::int, 'one'::text));
SELECT pgv_insert('lifetime', 'rec', ROW (2::int, 'two'::text));
BEGIN;
DECLARE array_cur CURSOR FOR SELECT pgv_select('lifetime', 'rec', ARRAY[1, 2]);
FETCH 1 FROM array_cur;
SELECT pgv_free();
FETCH ALL FROM array_cur;
COMMIT;
SELECT pgv_free();

-- Active pgv_stats cursors must be invalidated before packagesHash can be
-- freed by pgv_free().
SELECT pgv_set('stats', 'a', '1'::text);
BEGIN;
DECLARE stats_cur CURSOR FOR SELECT package FROM pgv_stats();
FETCH 1 FROM stats_cur;
SELECT pgv_free();
FETCH 1 FROM stats_cur;
COMMIT;
SELECT pgv_free();
