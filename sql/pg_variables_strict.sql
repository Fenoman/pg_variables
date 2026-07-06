SELECT pgv_free();

-- pgv_get(strict := false) must return NULL for a transactionally removed
-- variable, not its stale pre-removal value: getVariableInternal() returns the
-- now-invalid entry at strict=false, so variable_get() has to check validity
-- itself. Only observable while the package stays alive through another
-- variable (otherwise the package lookup already returns NULL).
BEGIN;
SELECT pgv_set('strictpkg', 'keep', 1);
SELECT pgv_set('strictpkg', 'v', 42, true);
SELECT pgv_remove('strictpkg', 'v');
SELECT pgv_exists('strictpkg', 'v') AS var_exists;
SELECT pgv_get('strictpkg', 'v', NULL::int, false) AS get_nonstrict;
-- strict=true still raises for the removed variable.
SELECT pgv_get('strictpkg', 'v', NULL::int, true);
ROLLBACK;
SELECT pgv_free();
