-- Explicit transaction block with several transactional sets and one commit,
-- so the per-commit discard cost is amortised over N sets (changesStack grows,
-- then a single processChanges(DISCARD) + teardown).
BEGIN;
SELECT pgv_set('bench', 'a', 1, true);
SELECT pgv_set('bench', 'b', 2, true);
SELECT pgv_set('bench', 'c', 3, true);
SELECT pgv_set('bench', 'd', 4, true);
COMMIT;
