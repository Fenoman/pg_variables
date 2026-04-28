SELECT pgv_free();

-- Transactional variables created inside an explicit transaction must not
-- leak into the session after COMMIT.
BEGIN;
SELECT pgv_set('txlocal_scalar', 'v', 10::int, TRUE);
COMMIT;
SELECT pgv_get('txlocal_scalar', 'v', NULL::int);

-- Non-transactional variables in the same package must keep the package alive,
-- while transactional variables from that transaction disappear.
BEGIN;
SELECT pgv_set('txlocal_mixed', 'regular', 20::int, FALSE);
SELECT pgv_set('txlocal_mixed', 'trans', 30::int, TRUE);
COMMIT;
SELECT pgv_get('txlocal_mixed', 'regular', NULL::int);
SELECT pgv_get('txlocal_mixed', 'trans', NULL::int);
SELECT pgv_free();

-- A transactional variable that existed before the explicit transaction must
-- be restored to its previous value after COMMIT.
SELECT pgv_set('txlocal_existing', 'v', 1::int, TRUE);
BEGIN;
SELECT pgv_set('txlocal_existing', 'v', 2::int, TRUE);
COMMIT;
SELECT pgv_get('txlocal_existing', 'v', NULL::int);
SELECT pgv_free();

-- Transactional record variables follow the same transaction-local lifetime.
BEGIN;
SELECT pgv_insert('txlocal_record', 'r', ROW (1::int, 'one'::text), TRUE);
COMMIT;
SELECT * FROM pgv_select('txlocal_record', 'r') AS t(id int, label text);

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

-- Active pgv_select cursors over a transactional record variable must be
-- invalidated before pgv_remove(variable) can free/reinitialize its record hash.
BEGIN;
SELECT pgv_insert('uaf', 'x', ROW (1::int, 'a'::text), TRUE);
SELECT pgv_insert('uaf', 'x', ROW (2::int, 'b'::text), TRUE);
SELECT pgv_insert('uaf', 'x', ROW (3::int, 'c'::text), TRUE);
DECLARE trans_var_cur CURSOR FOR
SELECT pgv_select('uaf', 'x');
MOVE 1 FROM trans_var_cur;
SELECT pgv_remove('uaf', 'x');
SELECT pgv_insert('uaf', 'x', ROW (99::int, 'z'::text), TRUE);
FETCH ALL FROM trans_var_cur;
ROLLBACK;
SELECT pgv_free();

-- Rolling back pgv_remove(transactional_variable) must restore the deletion
-- flag as well as the previous value state.
SELECT pgv_insert('rollback', 'rec', ROW (1::int, 'a'::text), TRUE);
BEGIN;
SELECT pgv_remove('rollback', 'rec');
ROLLBACK;
SELECT pgv_insert('rollback', 'rec', ROW (2::int, 'b'::text), TRUE);
SELECT * FROM pgv_select('rollback', 'rec') AS t(id int, val text)
ORDER BY id;
SELECT pgv_free();

-- Rollback of a transaction that created a record variable must terminate
-- active scans before freeing that variable's only record state.
BEGIN;
SELECT pgv_insert('rollback_scan', 'rec', ROW (1::int, 'x'::text), TRUE);
DECLARE rollback_scan_cur CURSOR FOR SELECT pgv_select('rollback_scan', 'rec');
MOVE 1 FROM rollback_scan_cur;
ROLLBACK;
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
