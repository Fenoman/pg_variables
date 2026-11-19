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

-- Package-removal tombstones survive several nested rollbacks.
BEGIN;
SELECT pgv_set('nested_recreate', 'old_tx', 11, true);
SELECT pgv_set('nested_recreate', 'old_tx2', 22, true);
SELECT pgv_remove('nested_recreate');
SAVEPOINT outer_recreate;
SAVEPOINT middle_recreate;
SAVEPOINT inner_recreate;
SELECT pgv_set('nested_recreate', 'new_regular', 2, false);
ROLLBACK TO outer_recreate;
DO $$ BEGIN
 IF pgv_exists('nested_recreate', 'old_tx') OR
    pgv_exists('nested_recreate', 'old_tx2') OR
    pgv_get('nested_recreate', 'old_tx', NULL::integer, false) IS NOT NULL OR
    pgv_get('nested_recreate', 'old_tx2', NULL::integer, false) IS NOT NULL OR
    (SELECT count(*) FROM pgv_list() WHERE package = 'nested_recreate') <> 1 THEN
  RAISE EXCEPTION 'nested rollback resurrected a removed transactional value';
 END IF;
END $$;
COMMIT;
DO $$ BEGIN
 IF pgv_exists('nested_recreate', 'old_tx') OR
    pgv_exists('nested_recreate', 'old_tx2') OR
    pgv_get('nested_recreate', 'new_regular', NULL::integer) IS DISTINCT FROM 2 THEN
  RAISE EXCEPTION 'commit retained a removed value or lost regular data';
 END IF;
END $$;
SELECT pgv_free();

-- Revalidated values start independent savepoint histories.
SELECT pgv_free();
BEGIN;
SELECT pgv_set('reuse_removed', 'tx', 11, true);
SELECT pgv_remove('reuse_removed');
SELECT pgv_set('reuse_removed', 'reg', 1, false);
SELECT pgv_set('reuse_removed', 'tx', 22, true);
SAVEPOINT later;
SELECT pgv_set('reuse_removed', 'tx', 33, true);
ROLLBACK TO later;
DO $$ BEGIN
 IF pgv_get('reuse_removed', 'tx', NULL::integer, false) IS DISTINCT FROM 22 THEN
  RAISE EXCEPTION 'later rollback lost a revalidated value';
 END IF;
END $$;
ROLLBACK;
SELECT pgv_free();
BEGIN;
SELECT pgv_set('reuse_release', 'tx', 11, true);
SAVEPOINT removal;
SELECT pgv_remove('reuse_release');
SAVEPOINT recreate;
SELECT pgv_set('reuse_release', 'reg', 1, false);
SELECT pgv_set('reuse_release', 'tx', 22, true);
RELEASE removal;
SAVEPOINT later_outer;
SAVEPOINT later_inner;
SELECT pgv_set('reuse_release', 'tx', 33, true);
ROLLBACK TO later_inner;
DO $$ BEGIN
 IF pgv_get('reuse_release', 'tx', NULL::integer, false) IS DISTINCT FROM 22 THEN
  RAISE EXCEPTION 'released removal contaminated a later rollback';
 END IF;
END $$;
ROLLBACK;
SELECT pgv_free();

-- Revalidation deeper than an unreleased removal preserves its own savepoint
-- history while still hiding the pre-removal value if the recreation rolls back.
BEGIN;
SELECT pgv_set('reuse_deep', 'tx', 11, true);
SAVEPOINT removal;
SELECT pgv_remove('reuse_deep');
SAVEPOINT recreate;
SELECT pgv_set('reuse_deep', 'reg', 1, false);
SELECT pgv_set('reuse_deep', 'tx', 22, true);
SAVEPOINT later;
SELECT pgv_set('reuse_deep', 'tx', 33, true);
ROLLBACK TO later;
DO $$ BEGIN
 IF pgv_get('reuse_deep', 'tx', NULL::integer, false) IS DISTINCT FROM 22 OR
    (SELECT count(*) FROM pgv_list() WHERE package = 'reuse_deep') IS DISTINCT FROM 2 THEN
  RAISE EXCEPTION 'rollback to post-revalidation savepoint lost the revalidated value';
 END IF;
END $$;
ROLLBACK TO recreate;
DO $$ BEGIN
 IF pgv_exists('reuse_deep', 'tx') OR
    pgv_get('reuse_deep', 'tx', NULL::integer, false) IS NOT NULL OR
    (SELECT count(*) FROM pgv_list() WHERE package = 'reuse_deep') IS DISTINCT FROM 1 THEN
  RAISE EXCEPTION 'rolling back revalidation revived the pre-removal value';
 END IF;
END $$;
ROLLBACK TO removal;
DO $$ BEGIN
 IF pgv_get('reuse_deep', 'tx', NULL::integer, false) IS DISTINCT FROM 11 OR
    pgv_get('reuse_deep', 'reg', NULL::integer, false) IS DISTINCT FROM 1 OR
    (SELECT count(*) FROM pgv_list() WHERE package = 'reuse_deep') IS DISTINCT FROM 2 THEN
  RAISE EXCEPTION 'rolling back package removal did not restore the pre-removal value';
 END IF;
END $$;
COMMIT;
DO $$ BEGIN
 IF pgv_exists('reuse_deep', 'tx') OR
    pgv_get('reuse_deep', 'reg', NULL::integer, false) IS DISTINCT FROM 1 THEN
  RAISE EXCEPTION 'commit after rollback retained transactional state or lost regular data';
 END IF;
END $$;
SELECT pgv_free();

-- Releasing a deeper revalidating savepoint into a tombstone savepoint keeps
-- both later savepoint rollback and the outer removal boundary intact.
BEGIN;
SELECT pgv_set('reuse_squash', 'tx', 11, true);
SAVEPOINT removal;
SELECT pgv_remove('reuse_squash');
SAVEPOINT recreate;
SELECT pgv_set('reuse_squash', 'reg', 1, false);
SAVEPOINT revalidate_sp;
SELECT pgv_set('reuse_squash', 'tx', 22, true);
RELEASE SAVEPOINT revalidate_sp;
SAVEPOINT later;
SELECT pgv_set('reuse_squash', 'tx', 33, true);
ROLLBACK TO later;
DO $$ BEGIN
 IF pgv_get('reuse_squash', 'tx', NULL::integer, false) IS DISTINCT FROM 22 THEN
  RAISE EXCEPTION 'rollback after released revalidation lost the revalidated value';
 END IF;
END $$;
ROLLBACK TO recreate;
DO $$ BEGIN
 IF pgv_exists('reuse_squash', 'tx') OR
    pgv_get('reuse_squash', 'tx', NULL::integer, false) IS NOT NULL THEN
  RAISE EXCEPTION 'rolling back squashed revalidation revived the pre-removal value';
 END IF;
END $$;
ROLLBACK;
SELECT pgv_free();

-- Removing a transactional variable that has no older valid savepoint state
-- allows reusing its name for a regular variable, whereas an older valid state
-- across a savepoint still blocks opposite-mode creation.
BEGIN;
SELECT pgv_set('opp_same_lvl', 'x', 1, true);
SELECT pgv_remove('opp_same_lvl', 'x');
SELECT pgv_set('opp_same_lvl', 'x', 2, false);
DO $$ BEGIN
 IF pgv_get('opp_same_lvl', 'x', NULL::integer) IS DISTINCT FROM 2 OR
    (SELECT count(*) FROM pgv_list() WHERE package = 'opp_same_lvl' AND name = 'x') <> 1 THEN
  RAISE EXCEPTION 'same-level tombstoned transactional variable blocked regular reuse';
 END IF;
END $$;
COMMIT;
SELECT pgv_free();
BEGIN;
SELECT pgv_set('opp_sp_lvl', 'x', 1, true);
SAVEPOINT opp_sp;
SELECT pgv_remove('opp_sp_lvl', 'x');
SELECT pgv_set('opp_sp_lvl', 'x', 2, false);
ROLLBACK TO opp_sp;
SELECT pgv_get('opp_sp_lvl', 'x', NULL::integer) AS x_restored;
COMMIT;
SELECT pgv_free();

-- Removing an entire package at the same transaction level makes pre-removal
-- transactional variables unreachable across nested savepoints, so opposite-mode
-- regular creation inside a savepoint must succeed, whereas package removal
-- inside a savepoint must still block opposite-mode creation when rollback can
-- restore the pre-savepoint transactional value.
BEGIN;
SELECT pgv_set('opp_pkg_same', 'x', 10, true);
SELECT pgv_remove('opp_pkg_same');
SAVEPOINT opp_pkg_sp;
SELECT pgv_set('opp_pkg_same', 'x', 20, false);
ROLLBACK TO opp_pkg_sp;
DO $$ BEGIN
 IF pgv_get('opp_pkg_same', 'x', NULL::integer) IS DISTINCT FROM 20 OR
    (SELECT count(*) FROM pgv_list() WHERE package = 'opp_pkg_same' AND name = 'x') <> 1 THEN
  RAISE EXCEPTION 'regular variable lost or duplicated after rolling back savepoint over irreversible package removal';
 END IF;
END $$;
COMMIT;
SELECT pgv_get('opp_pkg_same', 'x', NULL::integer) AS opp_pkg_same_after_commit;
SELECT pgv_free();

BEGIN;
SELECT pgv_set('opp_pkg_rev', 'x', 10, true);
SAVEPOINT opp_pkg_rm;
SELECT pgv_remove('opp_pkg_rev');
SAVEPOINT opp_pkg_recreate;
SELECT pgv_set('opp_pkg_rev', 'x', 20, false);
ROLLBACK TO opp_pkg_rm;
SELECT pgv_get('opp_pkg_rev', 'x', NULL::integer) AS opp_pkg_rev_restored;
COMMIT;
SELECT pgv_free();

BEGIN;
SELECT pgv_set('opp_pkg_readd', 'x', 10, true);
SELECT pgv_remove('opp_pkg_readd');
SAVEPOINT opp_readd_sp1;
SELECT pgv_set('opp_pkg_readd', 'x', 30, true);
SAVEPOINT opp_readd_sp2;
SELECT pgv_remove('opp_pkg_readd', 'x');
SELECT pgv_set('opp_pkg_readd', 'x', 40, false);
ROLLBACK TO opp_readd_sp2;
SELECT pgv_get('opp_pkg_readd', 'x', NULL::integer) AS opp_pkg_readd_restored;
COMMIT;
SELECT pgv_free();

-- Repeated removal across a nested savepoint (e.g. pgv_free() after same-level
-- pgv_remove()) must preserve the earliest contiguous removal boundary so
-- opposite-mode creation is still allowed.
BEGIN;
SELECT pgv_set('opp_pkg_dbl_rm', 'x', 10, true);
SELECT pgv_remove('opp_pkg_dbl_rm');
SAVEPOINT opp_dbl_sp;
SELECT pgv_free();
SELECT pgv_set('opp_pkg_dbl_rm', 'x', 25, false);
ROLLBACK TO opp_dbl_sp;
SELECT pgv_get('opp_pkg_dbl_rm', 'x', NULL::integer) AS opp_pkg_dbl_rm_val;
COMMIT;
SELECT pgv_free();

-- Recreating an irreversibly removed transactional variable with a new type or
-- scalar/record mode must succeed, while reversible removal inside a savepoint
-- must still reject type changes and restore the original value on rollback.
BEGIN;
SELECT pgv_set('retype_irrev', 'x', 10, true);
SELECT pgv_remove('retype_irrev');
SAVEPOINT sp_retype_1;
SELECT pgv_set('retype_irrev', 'x', 'as_text'::text, true);
SELECT pgv_get('retype_irrev', 'x', NULL::text) AS retype_after_pkg_rm;
ROLLBACK TO sp_retype_1;
SELECT pgv_exists('retype_irrev') AS retype_pkg_exists_after_rb;
SELECT pgv_insert('retype_irrev', 'm', ROW(1, 'rec'::text), true);
SELECT pgv_remove('retype_irrev', 'm');
SELECT pgv_set('retype_irrev', 'm', 77, true);
SELECT pgv_get('retype_irrev', 'm', NULL::integer) AS retype_rec_to_scalar;
COMMIT;
SELECT pgv_free();

BEGIN;
SELECT pgv_set('retype_rev', 'x', 10, true);
SAVEPOINT sp_retype_rev;
SELECT pgv_remove('retype_rev', 'x');
SELECT pgv_set('retype_rev', 'x', 'wrong'::text, true);
ROLLBACK TO sp_retype_rev;
SELECT pgv_get('retype_rev', 'x', NULL::integer) AS retype_rev_restored;
COMMIT;
SELECT pgv_free();
