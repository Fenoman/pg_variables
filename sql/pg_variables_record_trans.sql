SELECT pgv_free();

-- Creating a record variable whose key type has no hash/match function must
-- fail cleanly. For a transactional variable the failed init_record() used to
-- physically remove a variable that was already registered in changesStack,
-- leaving a dangling ChangedObject that crashed the backend (SIGSEGV) once the
-- freed dynahash entry got reused and processChanges() dereferenced it at
-- commit or rollback.

-- Case 1: remove and re-insert a transactional record variable with an
-- unhashable key type under a savepoint, then reuse the freed slot and commit.
BEGIN;
SELECT pgv_insert('rtrans', 'r', ROW (1), true);
SELECT pgv_remove('rtrans', 'r');
SAVEPOINT sp;
SELECT pgv_insert('rtrans', 'r', ROW (point(1,2)), true);
ROLLBACK TO sp;
SELECT pgv_insert('rtrans', 'w', ROW (2), true);
COMMIT;
SELECT 'case1 survived commit' AS status;
SELECT pgv_exists('rtrans') AS pkg_exists;

-- Case 2: fresh transactional record variable with an unhashable key type,
-- then reuse the freed slot and commit another transactional variable.
SELECT pgv_free();
BEGIN;
SAVEPOINT sp;
SELECT pgv_insert('rtrans2', 'bad', ROW (point(3,4)), true);
ROLLBACK TO sp;
SELECT pgv_insert('rtrans2', 'ok', ROW (7), true);
COMMIT;
SELECT 'case2 survived commit' AS status;

-- Case 3: the non-transactional path still errors cleanly (no changesStack).
SELECT pgv_free();
SELECT pgv_insert('rtrans3', 'bad', ROW (point(5,6)), false);
SELECT 'case3 survived' AS status;

SELECT pgv_free();
