SELECT pgv_free();

-- pgv_select() by value returns a record that lives in the variable's own
-- memory context. If the same record is updated in the same query -- freeing
-- the old tuple -- while the returned Datum is still being materialised, the
-- result must stay the value captured at select time, not freed/reused memory.
-- This mirrors the datumCopy() that pgv_get() performs for by-reference
-- scalars; without it this is a use-after-free that a CLOBBER_FREED_MEMORY
-- build turns into a crash or garbage.
SELECT pgv_insert('sel', 'r', ROW (1::int, 'AAAAAAAA'::text), false);
SELECT pgv_select('sel', 'r', 1::int) AS rec_value,
       pgv_update('sel', 'r', ROW (1::int, 'BBBBBBBB'::text)) AS updated;
-- The update is visible to a fresh select.
SELECT pgv_select('sel', 'r', 1::int) AS rec_after_update;
SELECT pgv_free();
