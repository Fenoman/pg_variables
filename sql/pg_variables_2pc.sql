SELECT pgv_free();

-- Pending backend-local histories cannot be transferred by two-phase commit.
-- The extension check precedes the max_prepared_transactions server guard.
BEGIN;
SELECT pgv_set('tx2pc', 'v', 'x'::text, true);
PREPARE TRANSACTION 'pgv_2pc';
-- The failed prepare aborts the transaction, so nothing leaks into the session.
SELECT pgv_exists('tx2pc') AS leaked;
SELECT pgv_free();

-- The session stays healthy afterwards: changesStack is not corrupted, so a
-- normal transactional variable still commits (and is discarded) as usual.
BEGIN;
SELECT pgv_set('ok2pc', 'v', 1, true);
COMMIT;
SELECT pgv_exists('ok2pc') AS exists_after_commit;
SELECT pgv_free();

-- Creating regular variables also registers package bookkeeping.
BEGIN;
SELECT pgv_set('regular2pc', 'v', 7, false);
PREPARE TRANSACTION 'pgv_regular_2pc';
SELECT pgv_get('regular2pc', 'v', NULL::integer) AS regular_survives_abort;
SELECT pgv_free();
