CREATE EXTENSION pg_variables;

SELECT pg_advisory_unlock_all();

-- Top-level ROLLBACK releases session-level advisory locks by default.
BEGIN;
SELECT pg_advisory_lock(64001);
ROLLBACK;
SELECT count(*) AS locks_after_rollback
FROM pg_locks
WHERE pid = pg_backend_pid()
  AND locktype = 'advisory';

-- Transaction abort after an error also releases session-level advisory locks.
BEGIN;
SELECT pg_advisory_lock(64002);
SELECT 1 / 0;
ROLLBACK;
SELECT count(*) AS locks_after_error
FROM pg_locks
WHERE pid = pg_backend_pid()
  AND locktype = 'advisory';

-- COMMIT keeps PostgreSQL's regular session advisory lock behavior.
BEGIN;
SELECT pg_advisory_lock(64003);
COMMIT;
SELECT count(*) AS locks_after_commit
FROM pg_locks
WHERE pid = pg_backend_pid()
  AND locktype = 'advisory';
SELECT pg_advisory_unlock_all();

-- The GUC can disable abort cleanup.
SET pg_variables.unlock_advisory_locks_on_abort = off;
BEGIN;
SELECT pg_advisory_lock(64004);
ROLLBACK;
SELECT count(*) AS locks_when_disabled
FROM pg_locks
WHERE pid = pg_backend_pid()
  AND locktype = 'advisory';
SELECT pg_advisory_unlock_all();
RESET pg_variables.unlock_advisory_locks_on_abort;

-- ROLLBACK TO SAVEPOINT must not release all session advisory locks.
BEGIN;
SELECT pg_advisory_lock(64005);
SAVEPOINT advisory_s;
SELECT pg_advisory_lock(64006);
ROLLBACK TO SAVEPOINT advisory_s;
COMMIT;
SELECT count(*) AS locks_after_subxact_rollback
FROM pg_locks
WHERE pid = pg_backend_pid()
  AND locktype = 'advisory';

SELECT pg_advisory_unlock_all();
DROP EXTENSION pg_variables;
