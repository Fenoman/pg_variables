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
