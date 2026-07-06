SELECT pgv_free();

-- Transactional variables live in backend-local memory and cannot travel with
-- a prepared transaction to the session that finally commits it. Preparing a
-- transaction that modified them used to leak the values into the current
-- session (visible to the next pooled client) and leave a stale changesStack
-- that the next statement's commit corrupted. The prepare must now be refused.
-- The check runs in the XACT_EVENT_PRE_PREPARE callback, which fires before the
-- max_prepared_transactions guard, so the outcome does not depend on that GUC.
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
