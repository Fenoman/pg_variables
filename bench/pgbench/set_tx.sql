-- Transactional setter in autocommit: this is the hot per-commit DISCARD path
-- added by e18070b/c4ea3f0 (prepareChangesStack + createSavepoint +
-- addToChangesStack on the set, then processChanges(DISCARD) + ModuleContext
-- teardown on the implicit commit). Invisible to the in-statement hot_paths.sql.
SELECT pgv_set('bench', 'v', 1, true);
