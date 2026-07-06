-- Non-transactional setter, one autocommit transaction per pgbench "tx".
-- No changesStack / discard machinery is exercised.
SELECT pgv_set('bench', 'v', 1, false);
