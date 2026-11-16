SELECT pgv_free();

-- Regular recreation survives rollback without reviving removed values.
-- An outer rollback still restores transactional data from before removal.
DO $$
BEGIN
    PERFORM pgv_set('recreated', 'old_regular', 1, false);
    PERFORM pgv_set('recreated', 'old_transactional', 11, true);
    BEGIN
        PERFORM pgv_remove('recreated');
        BEGIN
            PERFORM pgv_set('recreated', 'new_regular', 2, false);
            PERFORM pgv_set('recreated', 'new_transactional', 22, true);
            RAISE EXCEPTION USING ERRCODE = 'PZ010';
        EXCEPTION WHEN SQLSTATE 'PZ010' THEN
            NULL;
        END;
        IF pgv_get('recreated', 'new_regular', NULL::integer, false)
           IS DISTINCT FROM 2 OR
           pgv_exists('recreated', 'old_regular') OR
           pgv_exists('recreated', 'old_transactional') OR
           pgv_exists('recreated', 'new_transactional') THEN
            RAISE EXCEPTION 'recreation rollback lost regular or revived removed data';
        END IF;
        PERFORM pgv_set('recreated', 'later_transactional', 33, true);
        RAISE EXCEPTION USING ERRCODE = 'PZ011';
    EXCEPTION WHEN SQLSTATE 'PZ011' THEN
        NULL;
    END;
    IF pgv_get('recreated', 'new_regular', NULL::integer, false)
       IS DISTINCT FROM 2 OR
       pgv_get('recreated', 'old_transactional', NULL::integer, false)
       IS DISTINCT FROM 11 OR pgv_exists('recreated', 'later_transactional') THEN
        RAISE EXCEPTION 'outer rollback did not restore the proper transaction state';
    END IF;
END
$$;
DO $$
BEGIN
    IF pgv_get('recreated', 'new_regular', NULL::integer, false)
       IS DISTINCT FROM 2 OR pgv_exists('recreated', 'old_transactional') THEN
        RAISE EXCEPTION 'commit lost regular data or retained transactional data';
    END IF;
END
$$;
SELECT pgv_free();

-- Revalidating a removed transactional variable inside a subtransaction must
-- create a package savepoint before bumping trans_var_num. Otherwise ROLLBACK
-- TO cannot restore the counter and leaves a phantom package that pgv_exists()
-- still reports after commit even though no variable remains (regression from
-- the package-lookup fast path: cache-hit skips createPackage(), and
-- createVariableInternal() bumped the counter without a package savepoint).

-- Case 1: rollback of the revalidating subtransaction must not leak a package.
BEGIN;
SELECT pgv_set('phantom', 'reg', 1);
SELECT pgv_set('phantom', 'v', 1, true);
SELECT pgv_remove('phantom', 'v');
SELECT pgv_exists('phantom');           -- prime the package lookup cache
SAVEPOINT s1;
SELECT pgv_set('phantom', 'v', 2, true);
ROLLBACK TO s1;
COMMIT;
SELECT pgv_remove('phantom', 'reg');
-- No live variable remains, so the package must be gone.
SELECT pgv_exists('phantom') AS pkg_exists;
SELECT count(*) AS rows_for_phantom FROM pgv_list() WHERE package = 'phantom';
SELECT pgv_free();

-- Case 2 (control): releasing the revalidating subtransaction keeps the value
-- and a correct counter; the regular variable survives commit, the
-- transactional one is discarded.
BEGIN;
SELECT pgv_set('keep', 'reg', 1);
SELECT pgv_set('keep', 'v', 1, true);
SELECT pgv_remove('keep', 'v');
SELECT pgv_exists('keep');
SAVEPOINT s1;
SELECT pgv_set('keep', 'v', 2, true);
RELEASE SAVEPOINT s1;
SELECT pgv_get('keep', 'v', NULL::int) AS v_after_release;
COMMIT;
SELECT pgv_exists('keep') AS keep_exists;
SELECT pgv_get('keep', 'reg', NULL::int) AS reg_after_commit;
SELECT pgv_free();
