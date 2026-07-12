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

-- Updating a record with a by-reference key must move the hash entry's stored
-- key pointer to the new tuple. Reusing the freed old tuple for another row
-- must not make the updated row disappear from keyed lookup.
SELECT pgv_insert('sel_text_key', 'r',
                  ROW ('aaaa'::text, 'old-value'::text), false);
SELECT pgv_update('sel_text_key', 'r',
                  ROW ('aaaa'::text, 'new-value'::text));
SELECT pgv_insert('sel_text_key', 'r',
                  ROW ('bbbb'::text, 'other-val'::text), false);
SELECT ROW (k, v) IS NOT DISTINCT FROM
       ROW ('aaaa'::text, 'new-value'::text) AS text_key_still_indexed
FROM pgv_select('sel_text_key', 'r', 'aaaa'::text) AS t(k text, v text);

-- Fixed-length pass-by-reference keys, notably UUID, have the same lifetime
-- requirement as varlena keys.
SELECT pgv_insert('sel_uuid_key', 'r',
                  ROW ('00000000-0000-0000-0000-000000000001'::uuid,
                       'old-value'::text), false);
SELECT pgv_update('sel_uuid_key', 'r',
                  ROW ('00000000-0000-0000-0000-000000000001'::uuid,
                       'new-value'::text));
SELECT pgv_insert('sel_uuid_key', 'r',
                  ROW ('00000000-0000-0000-0000-000000000002'::uuid,
                       'other-val'::text), false);
SELECT ROW (k, v) IS NOT DISTINCT FROM
       ROW ('00000000-0000-0000-0000-000000000001'::uuid,
            'new-value'::text) AS uuid_key_still_indexed
FROM pgv_select('sel_uuid_key', 'r',
                '00000000-0000-0000-0000-000000000001'::uuid)
     AS t(k uuid, v text);
SELECT pgv_free();
-- End record-key lifetime checks.

-- HASH_REMOVE invalidates its returned entry. Deleting a record must capture
-- the separately allocated tuple before removing the hash entry, while the
-- by-reference key still points into that tuple.
SELECT pgv_insert('sel_delete_text', 'r',
                  ROW ('text-key'::text, 'old'::text), false);
SELECT pgv_delete('sel_delete_text', 'r', 'text-key'::text)
       AS text_key_deleted;
SELECT pgv_delete('sel_delete_text', 'r', 'text-key'::text)
       AS text_key_missing;
SELECT pgv_insert('sel_delete_text', 'r',
                  ROW ('text-key'::text, 'new'::text), false);
SELECT *
FROM pgv_select('sel_delete_text', 'r', 'text-key'::text)
     AS t(k text, v text);

SELECT pgv_insert('sel_delete_uuid', 'r',
                  ROW ('00000000-0000-0000-0000-000000000003'::uuid,
                       'old'::text), false);
SELECT pgv_delete('sel_delete_uuid', 'r',
                  '00000000-0000-0000-0000-000000000003'::uuid)
       AS uuid_key_deleted;
SELECT pgv_insert('sel_delete_uuid', 'r',
                  ROW ('00000000-0000-0000-0000-000000000003'::uuid,
                       'new'::text), false);
SELECT *
FROM pgv_select('sel_delete_uuid', 'r',
                '00000000-0000-0000-0000-000000000003'::uuid)
     AS t(k uuid, v text);
SELECT pgv_free();
-- End delete lifetime checks.
