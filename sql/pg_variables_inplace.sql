SELECT pgv_free();

-- Rewriting a scalar variable with a same-sized varlena reuses the stored
-- buffer in place. Verify the stored value always tracks the latest set across
-- equal / smaller / larger sizes.
SELECT pgv_set('ip', 's', 'AAAA'::text);
SELECT pgv_set('ip', 's', 'BBBB'::text);        -- same size -> in-place
SELECT pgv_get('ip', 's', NULL::text) AS same_size;
SELECT pgv_set('ip', 's', 'CC'::text);          -- smaller -> copy path
SELECT pgv_get('ip', 's', NULL::text) AS smaller;
SELECT pgv_set('ip', 's', 'DDDDDDDD'::text);    -- larger -> copy path
SELECT pgv_get('ip', 's', NULL::text) AS larger;
SELECT pgv_set('ip', 's', NULL::text);          -- to NULL -> free
SELECT pgv_get('ip', 's', NULL::text, false) AS to_null;
SELECT pgv_free();

-- Transactional variable + savepoint rollback: the savepointed value must be
-- restored intact even though the current state was overwritten in place.
BEGIN;
SELECT pgv_set('ip2', 'v', 'XXXX'::text, true);
SAVEPOINT s;
SELECT pgv_set('ip2', 'v', 'YYYY'::text, true);  -- same size -> in-place on top state
SELECT pgv_get('ip2', 'v', NULL::text) AS before_rollback;
ROLLBACK TO s;
SELECT pgv_get('ip2', 'v', NULL::text) AS after_rollback;
COMMIT;
SELECT pgv_free();
