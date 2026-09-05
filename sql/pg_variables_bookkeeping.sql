SELECT pgv_free();

-- A valid regular-only package may need its transactional hash created by the
-- fast path.  An error before a variable is added must not poison the package,
-- and the next transactional create must still roll back cleanly.
SELECT pgv_set('book_opposite', 'same_name', 1::int, false);
BEGIN;
SAVEPOINT opposite_error;
SELECT pgv_set('book_opposite', 'same_name', 2::int, true); -- fail
ROLLBACK TO opposite_error;
SELECT pgv_set('book_opposite', 'transactional', 3::int, true);
SELECT pgv_get('book_opposite', 'transactional', NULL::int)
       AS transactional_before_rollback;
ROLLBACK;
SELECT pgv_get('book_opposite', 'same_name', NULL::int)
       AS regular_after_rollback;
SELECT pgv_get('book_opposite', 'transactional', NULL::int, false)
       AS transactional_after_rollback;
SELECT pgv_free();

-- The inverse missing-HTAB path must preserve a regular variable created in a
-- package that initially contained only a transactional variable.
SELECT pgv_set('book_other', 'v', 10::int, false);
BEGIN;
SELECT pgv_set('book_tx_first', 'transactional', 20::int, true);
SELECT pgv_get('book_other', 'v', NULL::int); -- force package cache miss
SELECT pgv_set('book_tx_first', 'regular', 30::int, false);
ROLLBACK;
SELECT pgv_get('book_tx_first', 'regular', NULL::int)
       AS opposite_regular_after_rollback;
SELECT pgv_get('book_tx_first', 'transactional', NULL::int, false)
       AS opposite_tx_after_rollback;
SELECT pgv_free();

-- A regular scalar write to an existing valid package must not create package
-- transaction state merely because another package displaced the one-entry
-- cache.  The value write itself is session-scoped and requires no rollback.
DO $$
BEGIN
    PERFORM pgv_set('book_scalar', 'v', 1::int, false);
    PERFORM pgv_set('book_other', 'v', 10::int, false);
END
$$;

DO $$
DECLARE
    stack_contexts integer;
BEGIN
    PERFORM pgv_get('book_other', 'v', NULL::int);
    PERFORM pgv_set('book_scalar', 'v', 2::int, false);

    IF to_regclass('pg_catalog.pg_backend_memory_contexts') IS NULL THEN
        RETURN;
    END IF;

    EXECUTE $query$
        SELECT count(*)
        FROM pg_catalog.pg_backend_memory_contexts
        WHERE name = 'pg_variables: changesStack'
    $query$ INTO stack_contexts;

    IF stack_contexts <> 0 THEN
        RAISE EXCEPTION
            'regular scalar cache miss created package transaction state';
    END IF;
END
$$;

SELECT pgv_get('book_scalar', 'v', NULL::int) AS scalar_after_cache_miss;
SELECT pgv_free();

-- The same invariant applies to an existing regular record variable.
DO $$
BEGIN
    PERFORM pgv_insert('book_record', 'r',
                       ROW (1::int, 'one'::text), false);
    PERFORM pgv_set('book_other', 'v', 10::int, false);
END
$$;

DO $$
DECLARE
    stack_contexts integer;
BEGIN
    PERFORM pgv_get('book_other', 'v', NULL::int);
    PERFORM pgv_insert('book_record', 'r',
                       ROW (2::int, 'two'::text), false);

    IF to_regclass('pg_catalog.pg_backend_memory_contexts') IS NULL THEN
        RETURN;
    END IF;

    EXECUTE $query$
        SELECT count(*)
        FROM pg_catalog.pg_backend_memory_contexts
        WHERE name = 'pg_variables: changesStack'
    $query$ INTO stack_contexts;

    IF stack_contexts <> 0 THEN
        RAISE EXCEPTION
            'regular record cache miss created package transaction state';
    END IF;
END
$$;

SELECT *
FROM pgv_select('book_record', 'r') AS t(id int, label text)
ORDER BY id;
SELECT pgv_free();
-- End package bookkeeping checks.

-- Completed savepoints must release their own stack metadata, even when they
-- contain no variable changes. A fixed depth must use bounded memory for both
-- subcommit and subabort; warming up avoids testing AllocSet's initial growth.
DO $$
DECLARE
    before_used bigint;
    after_used bigint;
    phase integer;
    i integer;
BEGIN
    IF to_regclass('pg_catalog.pg_backend_memory_contexts') IS NULL THEN
        RETURN;
    END IF;
    PERFORM pgv_set('stack_churn', 'v', 1, true);
    FOR phase IN 1..2 LOOP
        FOR i IN 1..10000 LOOP
            BEGIN
                IF i % 2 = 0 THEN
                    RAISE SQLSTATE 'ZX002';
                END IF;
            EXCEPTION WHEN SQLSTATE 'ZX002' THEN
                NULL;
            END;
        END LOOP;
        EXECUTE $query$
            SELECT used_bytes
            FROM pg_catalog.pg_backend_memory_contexts
            WHERE name = 'pg_variables: changesStack'
        $query$ INTO STRICT after_used;
        IF phase = 1 THEN
            before_used := after_used;
        ELSIF after_used - before_used > 65536 THEN
            RAISE EXCEPTION 'completed savepoints retained stack metadata';
        END IF;
    END LOOP;
END
$$;
