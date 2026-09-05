SELECT pgv_free();

-- Removing a package must release every VarState allocated for variables in
-- that package. Keep another package alive so ModuleContext itself cannot hide
-- the leak by being deleted. pg_backend_memory_contexts is unavailable on some
-- supported old PostgreSQL versions, where this assertion is skipped.
DO $$
DECLARE
    before_used bigint;
    after_used bigint;
    cycle_no integer;
    variable_no integer;
BEGIN
    IF to_regclass('pg_catalog.pg_backend_memory_contexts') IS NULL THEN
        RETURN;
    END IF;

    PERFORM pgv_set('memory_anchor', 'v', 1, false);
    EXECUTE $query$
        SELECT used_bytes
        FROM pg_catalog.pg_backend_memory_contexts
        WHERE name = 'pg_variables: main memory context'
    $query$ INTO STRICT before_used;

    FOR cycle_no IN 1..20 LOOP
        FOR variable_no IN 1..250 LOOP
            PERFORM pgv_set('memory_churn', 'v' || variable_no,
                            variable_no, false);
        END LOOP;
        PERFORM pgv_remove('memory_churn');
    END LOOP;

    EXECUTE $query$
        SELECT used_bytes
        FROM pg_catalog.pg_backend_memory_contexts
        WHERE name = 'pg_variables: main memory context'
    $query$ INTO STRICT after_used;

    IF after_used - before_used > 131072 THEN
        RAISE EXCEPTION 'package removal retained variable states';
    END IF;
END
$$;
SELECT pgv_free();
-- End package-state lifetime checks.

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

-- Transactional variables created by standalone statements must also be
-- discarded at top-level commit. This matters for transaction-pool backends
-- where autocommit statements can otherwise leak session state.
SELECT pgv_set('txlocal_implicit', 'v', 40::int, TRUE);
SELECT pgv_get('txlocal_implicit', 'v', NULL::int);
SELECT pgv_insert('txlocal_implicit_rec', 'r',
                  ROW (1::int, 'first'::text), TRUE);
SELECT pgv_insert('txlocal_implicit_rec', 'r',
                  ROW (1::int, 'second'::text), TRUE);
SELECT * FROM pgv_select('txlocal_implicit_rec', 'r') AS t(id int, val text);

-- Savepoint rollback restores a transactional variable inside the same
-- top-level transaction.  The variable is discarded once that transaction
-- commits.
BEGIN;
SELECT pgv_set('txlocal_existing', 'v', 1::int, TRUE);
SAVEPOINT txlocal_existing_sp;
SELECT pgv_set('txlocal_existing', 'v', 2::int, TRUE);
ROLLBACK TO txlocal_existing_sp;
SELECT pgv_get('txlocal_existing', 'v', NULL::int);
COMMIT;
SELECT pgv_get('txlocal_existing', 'v', NULL::int);
SELECT pgv_free();

-- Transactional record variables follow the same transaction-local lifetime.
BEGIN;
SELECT pgv_insert('txlocal_record', 'r', ROW (1::int, 'one'::text), TRUE);
COMMIT;
SELECT * FROM pgv_select('txlocal_record', 'r') AS t(id int, label text);

-- A cursor over a transactional record variable must not keep the variable
-- alive after the top-level transaction commits.
BEGIN;
SELECT pgv_insert('txlocal_cursor', 'r', ROW (1::int, 'a'::text), TRUE);
SELECT pgv_insert('txlocal_cursor', 'r', ROW (2::int, 'b'::text), TRUE);
DECLARE txlocal_cursor_cur CURSOR FOR SELECT pgv_select('txlocal_cursor', 'r');
FETCH 1 FROM txlocal_cursor_cur;
COMMIT;
SELECT * FROM pgv_select('txlocal_cursor', 'r') AS t(id int, val text);

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
BEGIN;
SELECT pgv_insert('rollback', 'rec', ROW (1::int, 'a'::text), TRUE);
SAVEPOINT rollback_sp;
SELECT pgv_remove('rollback', 'rec');
ROLLBACK TO rollback_sp;
SELECT pgv_insert('rollback', 'rec', ROW (2::int, 'b'::text), TRUE);
SELECT * FROM pgv_select('rollback', 'rec') AS t(id int, val text)
ORDER BY id;
COMMIT;
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
-- End lifetime checks.

-- Package removal must not leave a record marked for reinitialization after
-- rollback. Exercise both remove(package) and free(), including an inner
-- subtransaction that releases its removal into the aborted outer block.
DO $$
DECLARE
    clear_all boolean;
    ids integer[];
BEGIN
    FOREACH clear_all IN ARRAY ARRAY[false, true] LOOP
        PERFORM pgv_insert('rollback_package', 'r', ROW (1, 'a'::text), true);
        PERFORM pgv_insert('rollback_package', 'other', ROW (10), true);
        PERFORM pgv_set('rollback_package', 'regular', 1, false);

        BEGIN
            BEGIN
                IF clear_all THEN
                    PERFORM pgv_free();
                ELSE
                    PERFORM pgv_remove('rollback_package');
                END IF;
            EXCEPTION WHEN OTHERS THEN
                RAISE;
            END;
            RAISE SQLSTATE 'ZX001';
        EXCEPTION WHEN SQLSTATE 'ZX001' THEN
            NULL;
        END;

        IF pgv_exists('rollback_package', 'regular') THEN
            RAISE EXCEPTION 'rollback restored a regular variable';
        END IF;
        PERFORM pgv_insert('rollback_package', 'r', ROW (2, 'b'::text), true);
        SELECT array_agg(id ORDER BY id) INTO ids
        FROM pgv_select('rollback_package', 'r') AS t(id int, val text);
        IF ids IS DISTINCT FROM ARRAY[1, 2] THEN
            RAISE EXCEPTION 'package rollback lost records: %', ids;
        END IF;
        PERFORM pgv_insert('rollback_package', 'other', ROW (11), true);
        SELECT array_agg(id ORDER BY id) INTO ids
        FROM pgv_select('rollback_package', 'other') AS t(id int);
        IF ids IS DISTINCT FROM ARRAY[10, 11] THEN
            RAISE EXCEPTION 'package rollback lost untouched records: %', ids;
        END IF;

        -- A recreated collection must not overwrite the rollback snapshot.
        BEGIN
            IF clear_all THEN
                PERFORM pgv_free();
            ELSE
                PERFORM pgv_remove('rollback_package');
            END IF;
            PERFORM pgv_insert('rollback_package', 'r', ROW (99, 'new'::text), true);
            RAISE SQLSTATE 'ZX001';
        EXCEPTION WHEN SQLSTATE 'ZX001' THEN
            NULL;
        END;
        PERFORM pgv_insert('rollback_package', 'r', ROW (3, 'c'::text), true);
        SELECT array_agg(id ORDER BY id) INTO ids
        FROM pgv_select('rollback_package', 'r') AS t(id int, val text);
        IF ids IS DISTINCT FROM ARRAY[1, 2, 3] THEN
            RAISE EXCEPTION 'recreation rollback lost records: %', ids;
        END IF;
        SELECT array_agg(id ORDER BY id) INTO ids
        FROM pgv_select('rollback_package', 'other') AS t(id int);
        IF ids IS DISTINCT FROM ARRAY[10, 11] THEN
            RAISE EXCEPTION 'recreation rollback lost untouched records: %', ids;
        END IF;

        -- Recreating a removed package without a rollback must start empty.
        PERFORM pgv_remove('rollback_package');
        PERFORM pgv_insert('rollback_package', 'r', ROW (99, 'new'::text), true);
        SELECT array_agg(id ORDER BY id) INTO ids
        FROM pgv_select('rollback_package', 'r') AS t(id int, val text);
        IF ids IS DISTINCT FROM ARRAY[99] OR
           pgv_exists('rollback_package', 'other') THEN
            RAISE EXCEPTION 'recreated package retained old records';
        END IF;
        PERFORM pgv_free();
    END LOOP;
END
$$;

-- Context names and identifiers must remain valid after init_record returns.
-- This query also exercises the name reads under Valgrind.
DO $$
DECLARE
    named_contexts integer;
BEGIN
    IF to_regclass('pg_catalog.pg_backend_memory_contexts') IS NULL THEN
        RETURN;
    END IF;
    PERFORM pgv_insert('memory_names', 'first_record', ROW (1), true);
    PERFORM pgv_insert('memory_names', 'second_record', ROW (2), true);
    PERFORM pgv_set('memory_names', 'scalar', repeat('x', 1000), true);
    PERFORM * FROM pgv_list();
    EXECUTE $query$
        SELECT count(*)
        FROM pg_catalog.pg_backend_memory_contexts
        WHERE name = 'pg_variables: records'
          AND ident IN ('first_record', 'second_record')
    $query$ INTO named_contexts;
    IF named_contexts <> 2 THEN
        RAISE EXCEPTION 'record context names or identifiers did not survive';
    END IF;
END
$$;
