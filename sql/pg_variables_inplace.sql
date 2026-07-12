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

-- Fixed-length pass-by-reference values can reuse their stored buffer too.
SELECT pgv_set('ip_fixed', 'uuid_value',
               '00000000-0000-0000-0000-000000000001'::uuid);
SELECT pgv_set('ip_fixed', 'uuid_value',
               '00000000-0000-0000-0000-000000000002'::uuid);
SELECT pgv_get('ip_fixed', 'uuid_value', NULL::uuid) AS uuid_value;

SELECT pgv_set('ip_fixed', 'name_value', 'first-name'::name);
SELECT pgv_set('ip_fixed', 'name_value', 'second-name'::name);
SELECT pgv_get('ip_fixed', 'name_value', NULL::name) AS name_value;

SELECT pgv_set('ip_fixed', 'interval_value', '1 day'::interval);
SELECT pgv_set('ip_fixed', 'interval_value',
               '2 days 03:04:05'::interval);
SELECT pgv_get('ip_fixed', 'interval_value', NULL::interval)
       AS interval_value;

SELECT pgv_set('ip_fixed', 'tid_value', '(1,2)'::tid);
SELECT pgv_set('ip_fixed', 'tid_value', '(3,4)'::tid);
SELECT pgv_get('ip_fixed', 'tid_value', NULL::tid) AS tid_value;

SELECT pgv_set('ip_fixed', 'uuid_value', NULL::uuid);
SELECT pgv_get('ip_fixed', 'uuid_value', NULL::uuid, false) AS uuid_null;
SELECT pgv_free();

-- The current transactional state owns a distinct fixed-length buffer; an
-- in-place overwrite must not modify the state restored by ROLLBACK TO.
BEGIN;
SELECT pgv_set('ip_fixed_tx', 'uuid_value',
               '00000000-0000-0000-0000-000000000010'::uuid, true);
SAVEPOINT fixed_sp;
SELECT pgv_set('ip_fixed_tx', 'uuid_value',
               '00000000-0000-0000-0000-000000000020'::uuid, true);
SELECT pgv_get('ip_fixed_tx', 'uuid_value', NULL::uuid)
       AS fixed_before_rollback;
ROLLBACK TO fixed_sp;
SELECT pgv_get('ip_fixed_tx', 'uuid_value', NULL::uuid)
       AS fixed_after_rollback;
ROLLBACK;
SELECT pgv_free();
-- End fixed-length in-place checks.
