SELECT pgv_free();

-- Deleting a live key cannot invalidate an unfinished full scan. A missing
-- key is harmless, and deletion is available once all full scans are done.
DO $$
DECLARE
    first_cursor refcursor;
    second_cursor refcursor;
    row_value text;
    blocked boolean;
    remaining integer;
    payload_size integer;
BEGIN
    FOREACH payload_size IN ARRAY ARRAY[32, 32768] LOOP
        PERFORM pgv_insert('scan_delete', 'r', ROW(k, repeat('x', payload_size)))
        FROM (VALUES (6), (40)) keys(k);
        OPEN first_cursor FOR SELECT pgv_select('scan_delete', 'r')::text;
        OPEN second_cursor FOR SELECT pgv_select('scan_delete', 'r')::text;
        FETCH first_cursor INTO row_value;
        FETCH second_cursor INTO row_value;
        IF pgv_delete('scan_delete', 'r', 999) THEN
            RAISE EXCEPTION 'missing key was deleted';
        END IF;
        CLOSE first_cursor;
        blocked := false;
        BEGIN
            PERFORM pgv_delete('scan_delete', 'r', 40);
        EXCEPTION WHEN object_in_use THEN
            blocked := true;
        END;
        IF NOT blocked THEN
            RAISE EXCEPTION 'delete invalidated an unfinished full scan';
        END IF;
        remaining := 0;
        LOOP
            FETCH second_cursor INTO row_value;
            EXIT WHEN NOT FOUND;
            remaining := remaining + 1;
        END LOOP;
        IF remaining <> 1 THEN
            RAISE EXCEPTION 'rejected delete changed unread rows';
        END IF;
        IF NOT pgv_delete('scan_delete', 'r', 40) THEN
            RAISE EXCEPTION 'completed scan still blocks deletion';
        END IF;
        CLOSE second_cursor;
        PERFORM pgv_free();
    END LOOP;
END
$$;

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

-- Both SRF selectors must own the returned tuple before another ProjectSet
-- expression updates its source. Test small AllocSet chunks and large tuples
-- that pfree returns to malloc, for both regular and transactional variables.
DO $$
DECLARE
    transactional boolean;
    array_selector boolean;
    payload_size integer;
    before_update text;
    updated boolean;
BEGIN
    FOREACH transactional IN ARRAY ARRAY[false, true] LOOP
        FOREACH array_selector IN ARRAY ARRAY[false, true] LOOP
            FOREACH payload_size IN ARRAY ARRAY[32, 32768] LOOP
                PERFORM pgv_insert('srf_result', 'r',
                                   ROW (1, repeat('a', payload_size)),
                                   transactional);
                IF array_selector THEN
                    SELECT r::text, changed INTO before_update, updated
                    FROM (
                        SELECT pgv_select('srf_result', 'r', ARRAY[1]) AS r,
                               pgv_update('srf_result', 'r',
                                          ROW (1, repeat('b', payload_size)))
                               AS changed
                    ) AS s;
                ELSE
                    SELECT r::text, changed INTO before_update, updated
                    FROM (
                        SELECT pgv_select('srf_result', 'r') AS r,
                               pgv_update('srf_result', 'r',
                                          ROW (1, repeat('b', payload_size)))
                               AS changed
                    ) AS s;
                END IF;
                IF NOT updated OR before_update IS DISTINCT FROM
                   '(1,' || repeat('a', payload_size) || ')' THEN
                    RAISE EXCEPTION 'SRF result changed after source update';
                END IF;
                IF pgv_select('srf_result', 'r', 1)::text IS DISTINCT FROM
                   '(1,' || repeat('b', payload_size) || ')' THEN
                    RAISE EXCEPTION 'record update was not executed';
                END IF;
                PERFORM pgv_free();
            END LOOP;
        END LOOP;
    END LOOP;
END
$$;

-- RELEASE preserves unread full, array and stats cursors across nested levels.
SELECT pgv_free();
CREATE FUNCTION pg_temp.pgv_fetch_text(c refcursor, n integer DEFAULT 2147483647)
RETURNS text[] LANGUAGE plpgsql AS $$
DECLARE
    value text;
    result text[] := ARRAY[]::text[];
    i integer := 0;
BEGIN
    WHILE i < n LOOP
        FETCH c INTO value;
        EXIT WHEN NOT FOUND;
        result := array_append(result, value);
        i := i + 1;
    END LOOP;
    RETURN result;
END
$$;
CREATE TEMP TABLE promoted_seen(name text PRIMARY KEY, rows text[]);
BEGIN;
DO $$
BEGIN
    PERFORM pgv_insert('promoted', 'regular', ROW(i), false)
    FROM generate_series(1, 5) i;
    PERFORM pgv_insert('promoted', 'transactional', ROW(i), true)
    FROM generate_series(1, 5) i;
    PERFORM pgv_set('promoted_stats', 'v', 1);
END
$$;
SAVEPOINT outer_level;
DECLARE promoted_full CURSOR FOR SELECT pgv_select('promoted', 'regular')::text;
DECLARE promoted_tx CURSOR FOR SELECT pgv_select('promoted', 'transactional')::text;
DECLARE promoted_array CURSOR FOR SELECT pgv_select('promoted', 'regular', ARRAY[1,2,3,4,5])::text;
DECLARE promoted_stats CURSOR FOR SELECT pgv_stats()::text;
INSERT INTO promoted_seen VALUES
    ('promoted_full', pg_temp.pgv_fetch_text('promoted_full', 1)),
    ('promoted_tx', pg_temp.pgv_fetch_text('promoted_tx', 1)),
    ('promoted_array', pg_temp.pgv_fetch_text('promoted_array', 1)),
    ('promoted_stats', pg_temp.pgv_fetch_text('promoted_stats', 1));
SAVEPOINT inner_level;
DECLARE promoted_nested CURSOR FOR SELECT pgv_select('promoted', 'regular')::text;
DECLARE promoted_early_close CURSOR FOR SELECT pgv_select('promoted', 'regular')::text;
INSERT INTO promoted_seen VALUES
    ('promoted_nested', pg_temp.pgv_fetch_text('promoted_nested', 1)),
    ('promoted_early_close', pg_temp.pgv_fetch_text('promoted_early_close', 1));
CLOSE promoted_early_close;
RELEASE inner_level;
RELEASE outer_level;
DO $$
DECLARE
    cursor_name text;
    actual text[];
    rejected boolean := false;
BEGIN
    BEGIN
        PERFORM pgv_delete('promoted', 'regular', 1);
    EXCEPTION WHEN object_in_use THEN
        rejected := true;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'promoted full scan did not protect its unread entries';
    END IF;
    PERFORM pgv_insert('promoted', 'regular', ROW(i), false)
    FROM generate_series(100, 200) i;
    FOREACH cursor_name IN ARRAY ARRAY['promoted_full', 'promoted_tx',
                                       'promoted_array', 'promoted_nested'] LOOP
        SELECT array_agg(value ORDER BY value) INTO actual
        FROM unnest((SELECT rows FROM promoted_seen WHERE name = cursor_name) ||
                    pg_temp.pgv_fetch_text(cursor_name::refcursor)) AS t(value);
        IF actual IS DISTINCT FROM ARRAY['(1)', '(2)', '(3)', '(4)', '(5)'] THEN
            RAISE EXCEPTION 'RELEASE changed unread rows for %: %', cursor_name, actual;
        END IF;
    END LOOP;
    SELECT array_agg(split_part(ltrim(value, '('), ',', 1) ORDER BY value)
    INTO actual
    FROM unnest((SELECT rows FROM promoted_seen WHERE name = 'promoted_stats') ||
                pg_temp.pgv_fetch_text('promoted_stats')) AS t(value);
    IF actual IS DISTINCT FROM ARRAY['promoted', 'promoted_stats'] THEN
        RAISE EXCEPTION 'RELEASE changed unread stats rows: %', actual;
    END IF;
END
$$;
CLOSE promoted_full;
CLOSE promoted_tx;
CLOSE promoted_array;
CLOSE promoted_stats;
CLOSE promoted_nested;
SAVEPOINT aborted_level;
DECLARE aborted_full CURSOR FOR SELECT pgv_select('promoted', 'regular')::text;
INSERT INTO promoted_seen VALUES ('aborted_full', pg_temp.pgv_fetch_text('aborted_full', 1));
ROLLBACK TO aborted_level;
DO $$
BEGIN
    IF NOT pgv_delete('promoted', 'regular', 100) THEN
        RAISE EXCEPTION 'aborted cursor left an active scan';
    END IF;
END
$$;
COMMIT;
DO $$
BEGIN
    IF pgv_exists('promoted', 'transactional') THEN
        RAISE EXCEPTION 'released cursor retained transactional values after commit';
    END IF;
END
$$;
DROP TABLE promoted_seen;
DROP FUNCTION pg_temp.pgv_fetch_text(refcursor, integer);
SELECT pgv_free();
