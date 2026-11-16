-- Transactional setter in autocommit includes changesStack setup, DISCARD and
-- ModuleContext teardown on each implicit commit.
SELECT pgv_set('bench', 'v', 1, true);
