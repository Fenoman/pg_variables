SELECT pgv_free();

-- pgv_get(strict := false) must return NULL for a transactionally removed
-- variable instead of its pre-removal value. getVariableInternal() treats a
-- removed variable as absent at strict=false and returns NULL even when the
-- requested type differs from the removed variable's former type.
BEGIN;
SELECT pgv_set('strictpkg', 'keep', 1);
SELECT pgv_set('strictpkg', 'v', 42, true);
SELECT pgv_remove('strictpkg', 'v');
SELECT pgv_exists('strictpkg', 'v') AS var_exists;
SELECT pgv_get('strictpkg', 'v', NULL::int, false) AS get_nonstrict;
SELECT pgv_get('strictpkg', 'v', NULL::text, false) AS get_other_type;
SELECT pgv_get('strictpkg', 'v', NULL::int[], false) AS get_other_array_type;
-- strict=true still raises for the removed variable.
SELECT pgv_get('strictpkg', 'v', NULL::int, true);
ROLLBACK;
SELECT pgv_free();
