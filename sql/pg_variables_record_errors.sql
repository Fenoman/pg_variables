SELECT pgv_free();

-- A rejected initial record must not leave a visible, uninitialized variable.
CREATE TEMP TABLE dropped_record_key(dead integer, id integer);
ALTER TABLE dropped_record_key DROP COLUMN dead;
INSERT INTO dropped_record_key VALUES (1);
DO $$
DECLARE
    transactional boolean;
    rejected boolean;
BEGIN
    PERFORM pgv_set('record_init', 'keep', 7, false);
    FOREACH transactional IN ARRAY ARRAY[false, true] LOOP
        rejected := false;
        BEGIN
            PERFORM pgv_insert('record_init', 'r', t, transactional)
            FROM dropped_record_key t;
        EXCEPTION WHEN invalid_parameter_value THEN
            rejected := true;
        END;
        IF NOT rejected OR pgv_exists('record_init', 'r') THEN
            RAISE EXCEPTION 'dropped key left a variable visible';
        END IF;
        rejected := false;
        BEGIN
            PERFORM pgv_insert('record_init', 'r', ROW(), transactional);
        EXCEPTION WHEN invalid_parameter_value THEN
            rejected := true;
        END;
        IF NOT rejected OR pgv_exists('record_init', 'r') THEN
            RAISE EXCEPTION 'empty record left a variable visible';
        END IF;
        PERFORM pgv_insert('record_init', 'r', ROW(1, 'valid'::text),
                           transactional);
        IF pgv_select('record_init', 'r', 1)::text IS DISTINCT FROM '(1,valid)' OR
           pgv_get('record_init', 'keep', NULL::integer) IS DISTINCT FROM 7 THEN
            RAISE EXCEPTION 'failed initialization damaged valid values';
        END IF;
        PERFORM pgv_remove('record_init', 'r');
    END LOOP;
END
$$;
DROP TABLE dropped_record_key;
CREATE TEMP TABLE dropped_record_attr(id integer, dead integer, payload text);
ALTER TABLE dropped_record_attr DROP COLUMN dead;
INSERT INTO dropped_record_attr VALUES (1, 'alive');
DO $$
DECLARE
    transactional boolean;
    rejected boolean;
BEGIN
    FOREACH transactional IN ARRAY ARRAY[false, true] LOOP
        rejected := false;
        BEGIN
            PERFORM pgv_insert('record_init', 'r_attr', t, transactional)
            FROM dropped_record_attr t;
        EXCEPTION WHEN invalid_parameter_value THEN
            rejected := true;
        END;
        IF NOT rejected OR pgv_exists('record_init', 'r_attr') THEN
            RAISE EXCEPTION 'dropped non-key attribute was accepted or left a variable visible';
        END IF;
    END LOOP;
END
$$;
DROP TABLE dropped_record_attr;
SELECT pgv_free();

-- Failed hash and comparison calls release unpublished tuples.
-- SQLSTATE and sequence counters verify the actual support function path.
CREATE TYPE pgv_error_key AS ENUM ('a', 'b');
-- Support functions can inspect state and mutate independent variables.
CREATE FUNCTION pgv_reenter(source text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF current_setting('pgv_test.reentry_source', true) IS DISTINCT FROM source THEN
        RETURN;
    END IF;
    CASE current_setting('pgv_test.reentry_action', true)
      WHEN 'variable' THEN PERFORM pgv_remove('callback_owner', 'r');
      WHEN 'package' THEN PERFORM pgv_remove('callback_owner');
      WHEN 'free' THEN PERFORM pgv_free();
      WHEN 'insert' THEN PERFORM pgv_insert('callback_owner', 'r',
                                           ROW('b'::pgv_error_key, 'nested'::text));
      WHEN 'update' THEN PERFORM pgv_update('callback_owner', 'r',
                                           ROW('a'::pgv_error_key, 'nested'::text));
      WHEN 'delete' THEN PERFORM pgv_delete('callback_owner', 'r', 'a'::pgv_error_key);
      WHEN 'independent' THEN
        PERFORM pgv_set('callback_other', 'v', 1, false);
        IF NOT pgv_exists('callback_owner', 'r') THEN
            RAISE EXCEPTION 'callback cannot inspect the parent collection';
        END IF;
      WHEN 'same_pkg_reg' THEN
        PERFORM pgv_set('recreate_cb', 'reg', 1, false);
      WHEN 'open_scan_first' THEN
        IF currval('pgv_cmp_calls') = coalesce(nullif(current_setting('pgv_test.cmp_base', true), ''), '0')::bigint + 1 THEN
            EXECUTE 'DECLARE pgv_del_scan_c1 CURSOR FOR SELECT pgv_select(''del_scan_pkg'', ''r'')';
            EXECUTE 'MOVE 1 IN pgv_del_scan_c1';
        END IF;
      WHEN 'open_scan_second' THEN
        IF currval('pgv_cmp_calls') >= coalesce(nullif(current_setting('pgv_test.cmp_base', true), ''), '0')::bigint + 2 THEN
            EXECUTE 'DECLARE pgv_del_scan_c2 CURSOR FOR SELECT pgv_select(''del_scan_pkg'', ''r'')';
            EXECUTE 'MOVE 1 IN pgv_del_scan_c2';
        END IF;
      ELSE NULL;
    END CASE;
END $$;
CREATE SEQUENCE pgv_hash_calls;
CREATE SEQUENCE pgv_cmp_calls;
CREATE FUNCTION pgv_error_hash(pgv_error_key) RETURNS integer
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
BEGIN
    PERFORM nextval('pgv_hash_calls');
    PERFORM pgv_reenter('hash');
    IF current_setting('pgv_test.error', true) = 'hash' THEN
        RAISE EXCEPTION USING ERRCODE = 'PZ061', MESSAGE = 'controlled hash failure';
    END IF;
    RETURN 0;
END
$$;
CREATE FUNCTION pgv_error_cmp(pgv_error_key, pgv_error_key) RETURNS integer
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
BEGIN
    PERFORM nextval('pgv_cmp_calls');
    PERFORM pgv_reenter('compare');
    IF current_setting('pgv_test.error', true) = 'compare' THEN
        RAISE EXCEPTION USING ERRCODE = 'PZ062', MESSAGE = 'controlled comparison failure';
    END IF;
    IF current_setting('pgv_test.cmp_flip', true) = 'after_first' AND
       currval('pgv_cmp_calls') > coalesce(nullif(current_setting('pgv_test.cmp_base', true), ''), '0')::bigint + 1 THEN
        RETURN 1;
    END IF;
    RETURN CASE WHEN $1 < $2 THEN -1 WHEN $1 > $2 THEN 1 ELSE 0 END;
END
$$;
CREATE OPERATOR CLASS pgv_error_hash_ops DEFAULT FOR TYPE pgv_error_key USING hash AS
    OPERATOR 1 = (anyenum, anyenum),
    FUNCTION 1 pgv_error_hash(pgv_error_key);
CREATE OPERATOR CLASS pgv_error_cmp_ops DEFAULT FOR TYPE pgv_error_key USING btree AS
    OPERATOR 1 < (anyenum, anyenum),
    OPERATOR 2 <= (anyenum, anyenum),
    OPERATOR 3 = (anyenum, anyenum),
    OPERATOR 4 >= (anyenum, anyenum),
    OPERATOR 5 > (anyenum, anyenum),
    FUNCTION 1 pgv_error_cmp(pgv_error_key, pgv_error_key);
DO $$
DECLARE
    action text;
    updating boolean;
    phase integer;
    i integer;
    failures integer;
    seen_state text;
    calls_before bigint;
    calls_after bigint;
    before_used bigint;
    after_used bigint;
BEGIN
    PERFORM pgv_insert('error_owner', 'r',
                       ROW('a'::pgv_error_key, repeat('x', 65536)), false);
    FOREACH action IN ARRAY ARRAY['hash', 'compare'] LOOP
        FOREACH updating IN ARRAY ARRAY[false, true] LOOP
            PERFORM set_config('pgv_test.error', action, true);
            SELECT last_value INTO calls_before FROM pgv_hash_calls;
            failures := 0;
            FOR phase IN 1..2 LOOP
                FOR i IN 1..50 LOOP
                    BEGIN
                        IF updating THEN
                            PERFORM pgv_update('error_owner', 'r',
                                               ROW('a'::pgv_error_key, repeat('y', 65536)));
                        ELSE
                            PERFORM pgv_insert('error_owner', 'r',
                                               ROW('b'::pgv_error_key, repeat('y', 65536)), false);
                        END IF;
                    EXCEPTION WHEN SQLSTATE 'PZ061' OR SQLSTATE 'PZ062' THEN
                        GET STACKED DIAGNOSTICS seen_state = RETURNED_SQLSTATE;
                        IF seen_state <> (CASE action WHEN 'hash' THEN 'PZ061' ELSE 'PZ062' END) THEN
                            RAISE EXCEPTION 'unexpected support function raised the error';
                        END IF;
                        failures := failures + 1;
                    END;
                END LOOP;
                IF to_regclass('pg_catalog.pg_backend_memory_contexts') IS NOT NULL THEN
                    EXECUTE $query$
                        SELECT coalesce(sum(used_bytes), 0)
                        FROM pg_catalog.pg_backend_memory_contexts
                        WHERE name = 'pg_variables: records'
                    $query$ INTO after_used;
                    IF phase = 1 THEN
                        before_used := after_used;
                    ELSIF after_used - before_used > 262144 THEN
                        RAISE EXCEPTION 'failed % % retained tuple storage: % bytes',
                                        action, updating, after_used - before_used;
                    END IF;
                END IF;
            END LOOP;
            SELECT last_value INTO calls_after FROM pgv_hash_calls;
            IF failures <> 100 OR calls_after - calls_before < 100 THEN
                RAISE EXCEPTION 'the intended support function did not execute';
            END IF;
            PERFORM set_config('pgv_test.error', 'none', true);
            IF (SELECT count(*) FROM pgv_select('error_owner', 'r')
                AS t(k pgv_error_key, v text)) <> 1 OR
               (SELECT v FROM pgv_select('error_owner', 'r', 'a'::pgv_error_key)
                AS t(k pgv_error_key, v text)) IS DISTINCT FROM repeat('x', 65536) THEN
                RAISE EXCEPTION 'failed operation changed the stored record';
            END IF;
        END LOOP;
    END LOOP;
    PERFORM pgv_free();
END
$$;
-- A callback failure while copying transactional state releases the current
-- unpublished tuple and preserves the parent collection.
DO $$
DECLARE
    action text;
    rejected boolean;
    seen_state text;
    before_used bigint;
    after_used bigint;
    allowed_growth bigint;
BEGIN
    FOREACH action IN ARRAY ARRAY['hash', 'compare'] LOOP
        PERFORM set_config('pgv_test.error', 'none', true);
        PERFORM pgv_insert('copy_error', 'r',
                           ROW('a'::pgv_error_key, repeat('x', 65536)), true);
        PERFORM pgv_insert('copy_error', 'r',
                           ROW('b'::pgv_error_key, repeat('x', 65536)), true);
        IF to_regclass('pg_catalog.pg_backend_memory_contexts') IS NOT NULL THEN
            EXECUTE $query$
                SELECT coalesce(sum(used_bytes), 0)
                FROM pg_catalog.pg_backend_memory_contexts
                WHERE name = 'pg_variables: records'
            $query$ INTO before_used;
        END IF;
        PERFORM set_config('pgv_test.error', action, true);
        rejected := false;
        BEGIN
            PERFORM pgv_update('copy_error', 'r',
                               ROW('a'::pgv_error_key, repeat('y', 65536)));
        EXCEPTION WHEN SQLSTATE 'PZ061' OR SQLSTATE 'PZ062' THEN
            GET STACKED DIAGNOSTICS seen_state = RETURNED_SQLSTATE;
            IF seen_state <> (CASE action WHEN 'hash' THEN 'PZ061' ELSE 'PZ062' END) THEN
                RAISE EXCEPTION 'unexpected support function failed during copy';
            END IF;
            rejected := true;
        END;
        PERFORM set_config('pgv_test.error', 'none', true);
        IF NOT rejected OR
           (SELECT count(*) FROM pgv_select('copy_error', 'r')
            AS t(k pgv_error_key, v text) WHERE v = repeat('x', 65536)) <> 2 THEN
            RAISE EXCEPTION 'failed copy changed the parent collection';
        END IF;
        IF before_used IS NOT NULL THEN
            EXECUTE $query$
                SELECT coalesce(sum(used_bytes), 0)
                FROM pg_catalog.pg_backend_memory_contexts
                WHERE name = 'pg_variables: records'
            $query$ INTO after_used;
            -- The entire unpublished collection is released on either error.
            allowed_growth := 32768;
            IF after_used - before_used > allowed_growth THEN
                RAISE EXCEPTION 'failed copy retained its unpublished tuple';
            END IF;
        END IF;
        PERFORM pgv_free();
    END LOOP;
END
$$;
-- Repeated partial copies must release the entire unpublished state.
DO $$
DECLARE
    before_used bigint;
    after_used bigint;
    before_contexts bigint;
    after_contexts bigint;
    i integer;
BEGIN
    PERFORM pgv_set('copy_leak', 'keep', 1, false);
    PERFORM set_config('pgv_test.error', 'none', true);
    PERFORM pgv_insert('copy_leak', 'r',
                       ROW('a'::pgv_error_key, repeat('x', 65536)), true);
    PERFORM pgv_insert('copy_leak', 'r',
                       ROW('b'::pgv_error_key, repeat('x', 65536)), true);
    IF to_regclass('pg_catalog.pg_backend_memory_contexts') IS NOT NULL THEN
        EXECUTE $q$ SELECT coalesce(sum(used_bytes), 0), count(*)
            FROM pg_catalog.pg_backend_memory_contexts
            WHERE name = 'pg_variables: records' $q$
            INTO before_used, before_contexts;
    END IF;
    PERFORM set_config('pgv_test.error', 'compare', true);
    FOR i IN 1..100 LOOP
        BEGIN
            PERFORM pgv_update('copy_leak', 'r',
                               ROW('a'::pgv_error_key, repeat('y', 65536)));
            RAISE EXCEPTION 'comparison failure did not execute';
        EXCEPTION WHEN SQLSTATE 'PZ062' THEN NULL;
        END;
    END LOOP;
    PERFORM set_config('pgv_test.error', 'none', true);
    IF before_used IS NOT NULL THEN
        EXECUTE $q$ SELECT coalesce(sum(used_bytes), 0), count(*)
            FROM pg_catalog.pg_backend_memory_contexts
            WHERE name = 'pg_variables: records' $q$
            INTO after_used, after_contexts;
        IF after_contexts <> before_contexts OR after_used - before_used > 32768 THEN
            RAISE EXCEPTION 'partial copies retained % contexts and % bytes',
                            after_contexts - before_contexts, after_used - before_used;
        END IF;
    END IF;
    IF (SELECT count(*) FROM pgv_select('copy_leak', 'r')
        AS t(k pgv_error_key, v text) WHERE v = repeat('x', 65536)) <> 2 THEN
        RAISE EXCEPTION 'failed copies changed parent rows';
    END IF;
END
$$;
SELECT pgv_remove('copy_leak');
-- Destructive reentry is rejected before it frees or changes an active hash.
DO $$
DECLARE
    source text;
    action text;
    operation text;
    rejected boolean;
BEGIN
    PERFORM pgv_insert('callback_owner', 'r', ROW('a'::pgv_error_key, 'parent'::text));
    FOREACH source IN ARRAY ARRAY['hash', 'compare'] LOOP
        PERFORM set_config('pgv_test.reentry_source', source, true);
        FOREACH action IN ARRAY ARRAY['variable', 'package', 'free', 'insert', 'update', 'delete'] LOOP
            PERFORM set_config('pgv_test.reentry_action', action, true);
            FOREACH operation IN ARRAY ARRAY['insert', 'update', 'delete', 'key', 'keys'] LOOP
                rejected := false;
                BEGIN
                    CASE operation
                      WHEN 'insert' THEN PERFORM pgv_insert('callback_owner', 'r',
                                                           ROW('b'::pgv_error_key, 'outer'::text));
                      WHEN 'update' THEN PERFORM pgv_update('callback_owner', 'r',
                                                           ROW('a'::pgv_error_key, 'outer'::text));
                      WHEN 'delete' THEN PERFORM pgv_delete('callback_owner', 'r', 'a'::pgv_error_key);
                      WHEN 'key' THEN PERFORM pgv_select('callback_owner', 'r', 'a'::pgv_error_key);
                      WHEN 'keys' THEN PERFORM pgv_select('callback_owner', 'r', ARRAY['a'::pgv_error_key]);
                    END CASE;
                EXCEPTION WHEN object_in_use THEN rejected := true;
                END;
                IF NOT rejected THEN
                    RAISE EXCEPTION 'unsafe % reentry from % during % was accepted', action, source, operation;
                END IF;
            END LOOP;
        END LOOP;
        PERFORM set_config('pgv_test.reentry_action', 'independent', true);
        IF pgv_select('callback_owner', 'r', 'a'::pgv_error_key)::text
           IS DISTINCT FROM '(a,parent)' OR
           pgv_get('callback_other', 'v', NULL::integer) IS DISTINCT FROM 1 THEN
            RAISE EXCEPTION 'callback damaged the original row or blocked independent work';
        END IF;
    END LOOP;
    PERFORM set_config('pgv_test.reentry_source', 'none', true);
    PERFORM pgv_free();
END $$;
-- Package recreation records zero-copy tombstones without invoking hash
-- callbacks on removed collections, and aborted recreation with surviving
-- regular side effects in the same package keeps removed collections hidden
-- until the package removal itself rolls back.
BEGIN;
SELECT pgv_insert('recreate_cb', 'r', ROW('a'::pgv_error_key, 'old'::text), true);
SAVEPOINT removal;
SELECT pgv_remove('recreate_cb');
SAVEPOINT recreate_ok;
SET LOCAL pgv_test.reentry_source = 'hash';
SET LOCAL pgv_test.reentry_action = 'same_pkg_reg';
SET LOCAL pgv_test.error = 'hash';
SELECT pgv_set('recreate_cb', 'requested', 2, false);
DO $$
DECLARE
    rejected boolean := false;
BEGIN
    IF pgv_get('recreate_cb', 'requested', NULL::integer, false) IS DISTINCT FROM 2 OR
       pgv_exists('recreate_cb', 'reg') OR
       pgv_exists('recreate_cb', 'r') OR
       (SELECT count(*) FROM pgv_list() WHERE package = 'recreate_cb') <> 1 THEN
        RAISE EXCEPTION 'recreation ran removed-record callback or exposed removed data';
    END IF;
    BEGIN
        PERFORM pgv_select('recreate_cb', 'r');
    EXCEPTION WHEN invalid_parameter_value THEN
        rejected := true;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'pgv_select accepted a removed collection after recreation';
    END IF;
END $$;
ROLLBACK;
SELECT pgv_free();
-- Even when no tombstone was created on the transactional collection before an
-- aborted subtransaction left regular side effects in the same package, the
-- exposed removal state keeps removed transactional data hidden until rolled back.
BEGIN;
SELECT pgv_insert('recreate_abort', 'r', ROW('a'::pgv_error_key, 'old'::text), true);
SAVEPOINT removal;
SELECT pgv_remove('recreate_abort');
SAVEPOINT recreate_fail;
DO $$
BEGIN
    PERFORM pgv_set('recreate_abort', 'reg', 1, false);
    RAISE EXCEPTION USING ERRCODE = 'PZ061', MESSAGE = 'aborted recreation';
EXCEPTION WHEN SQLSTATE 'PZ061' THEN
    NULL;
END $$;
ROLLBACK TO recreate_fail;
DO $$
DECLARE
    rejected boolean := false;
BEGIN
    IF pgv_get('recreate_abort', 'reg', NULL::integer, false) IS DISTINCT FROM 1 OR
       pgv_exists('recreate_abort', 'r') OR
       (SELECT count(*) FROM pgv_list() WHERE package = 'recreate_abort') <> 1 THEN
        RAISE EXCEPTION 'aborted recreation revived removed data or lost surviving regular values';
    END IF;
    BEGIN
        PERFORM pgv_select('recreate_abort', 'r');
    EXCEPTION WHEN invalid_parameter_value THEN
        rejected := true;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'pgv_select accepted a removed collection after aborted recreation';
    END IF;
END $$;
ROLLBACK TO removal;
DO $$ BEGIN
    IF NOT pgv_exists('recreate_abort', 'r') OR
       pgv_select('recreate_abort', 'r', 'a'::pgv_error_key)::text IS DISTINCT FROM '(a,old)' OR
       pgv_get('recreate_abort', 'reg', NULL::integer, false) IS DISTINCT FROM 1 OR
       (SELECT count(*) FROM pgv_list() WHERE package = 'recreate_abort') <> 2 THEN
        RAISE EXCEPTION 'rolling back package removal did not restore the transactional collection';
    END IF;
END $$;
COMMIT;
DO $$ BEGIN
    IF pgv_exists('recreate_abort', 'r') OR
       pgv_get('recreate_abort', 'reg', NULL::integer, false) IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'commit after rollback retained transactional collection or lost regular values';
    END IF;
END $$;
SELECT pgv_free();
-- A failure inside the first insert_record() call must also clean up the newly
-- created variable and package rather than leaving an empty typed collection.
DO $$
DECLARE
    transactional boolean;
    rejected boolean;
BEGIN
    FOREACH transactional IN ARRAY ARRAY[false, true] LOOP
        PERFORM set_config('pgv_test.error', 'hash', true);
        rejected := false;
        BEGIN
            PERFORM pgv_insert('first_insert_err', 'r',
                               ROW('a'::pgv_error_key, 'payload'::text),
                               transactional);
        EXCEPTION WHEN SQLSTATE 'PZ061' THEN
            rejected := true;
        END;
        PERFORM set_config('pgv_test.error', 'none', true);
        IF NOT rejected OR
           pgv_exists('first_insert_err', 'r') OR
           pgv_exists('first_insert_err') THEN
            RAISE EXCEPTION 'failed first insert left an empty collection visible (transactional=%)',
                            transactional;
        END IF;
        PERFORM pgv_insert('first_insert_err', 'r', ROW(42, 'retyped'::text),
                           transactional);
        IF pgv_select('first_insert_err', 'r', 42)::text IS DISTINCT FROM '(42,retyped)' THEN
            RAISE EXCEPTION 'failed first insert locked in a stale tuple descriptor';
        END IF;
        PERFORM pgv_free();
    END LOOP;
END $$;
-- pgv_delete checks open scans after HASH_FIND and removes the matched bucket
-- entry without calling the user comparison function a second time.
DO $$
DECLARE
    base_calls bigint;
    after_calls bigint;
    rejected boolean := false;
    c2_open boolean;
BEGIN
    PERFORM set_config('pgv_test.error', 'none', true);
    PERFORM set_config('pgv_test.reentry_source', 'none', true);
    PERFORM pgv_insert('del_scan_pkg', 'r', ROW('a'::pgv_error_key, 'one'::text), false);
    PERFORM pgv_insert('del_scan_pkg', 'r', ROW('b'::pgv_error_key, 'two'::text), false);

    -- Removing one of two colliding bucket entries must unlink only the matched
    -- entry while leaving its bucket neighbor intact.
    IF NOT pgv_delete('del_scan_pkg', 'r', 'b'::pgv_error_key) THEN
        RAISE EXCEPTION 'expected pgv_delete to remove colliding key b';
    END IF;
    IF pgv_select('del_scan_pkg', 'r', 'b'::pgv_error_key) IS NOT NULL OR
       pgv_select('del_scan_pkg', 'r', 'a'::pgv_error_key)::text IS DISTINCT FROM '(a,one)' THEN
        RAISE EXCEPTION 'address-matched HASH_REMOVE unlinked the wrong colliding entry';
    END IF;

    -- A full scan opened during HASH_FIND is caught by check_record_delete_allowed().
    SELECT last_value INTO base_calls FROM pgv_cmp_calls;
    PERFORM set_config('pgv_test.cmp_base', base_calls::text, true);
    PERFORM set_config('pgv_test.reentry_source', 'compare', true);
    PERFORM set_config('pgv_test.reentry_action', 'open_scan_first', true);
    BEGIN
        PERFORM pgv_delete('del_scan_pkg', 'r', 'a'::pgv_error_key);
    EXCEPTION WHEN object_in_use THEN
        rejected := true;
    END;
    PERFORM set_config('pgv_test.reentry_source', 'none', true);
    IF NOT rejected OR
       pgv_select('del_scan_pkg', 'r', 'a'::pgv_error_key)::text IS DISTINCT FROM '(a,one)' THEN
        RAISE EXCEPTION 'scan opened during HASH_FIND did not abort deletion cleanly';
    END IF;

    -- HASH_REMOVE must not invoke the comparison callback a second time, so a
    -- second-call scan hook never fires and an unstable comparator cannot leave
    -- a freed tuple inside a live bucket entry.
    SELECT last_value INTO base_calls FROM pgv_cmp_calls;
    PERFORM set_config('pgv_test.cmp_base', base_calls::text, true);
    PERFORM set_config('pgv_test.reentry_source', 'compare', true);
    PERFORM set_config('pgv_test.reentry_action', 'open_scan_second', true);
    PERFORM set_config('pgv_test.cmp_flip', 'after_first', true);
    IF NOT pgv_delete('del_scan_pkg', 'r', 'a'::pgv_error_key) THEN
        RAISE EXCEPTION 'expected pgv_delete to remove key a';
    END IF;
    SELECT last_value INTO after_calls FROM pgv_cmp_calls;
    SELECT EXISTS (SELECT 1 FROM pg_cursors WHERE name = 'pgv_del_scan_c2') INTO c2_open;
    PERFORM set_config('pgv_test.reentry_source', 'none', true);
    PERFORM set_config('pgv_test.cmp_flip', 'none', true);
    IF c2_open OR after_calls - base_calls <> 1 THEN
        RAISE EXCEPTION 'HASH_REMOVE invoked user comparison a second time (calls=%, cursor=%)',
                        after_calls - base_calls, c2_open;
    END IF;
    IF (SELECT count(*) FROM pgv_select('del_scan_pkg', 'r') AS t(k pgv_error_key, v text)) <> 0 THEN
        RAISE EXCEPTION 'deleted entry remained in collection';
    END IF;
    PERFORM pgv_free();
END $$;
DROP OPERATOR CLASS pgv_error_hash_ops USING hash;
DROP OPERATOR CLASS pgv_error_cmp_ops USING btree;
DROP OPERATOR FAMILY pgv_error_hash_ops USING hash;
DROP OPERATOR FAMILY pgv_error_cmp_ops USING btree;
DROP FUNCTION pgv_error_hash(pgv_error_key);
DROP FUNCTION pgv_error_cmp(pgv_error_key, pgv_error_key);
DROP SEQUENCE pgv_hash_calls, pgv_cmp_calls;
DROP FUNCTION pgv_reenter(text);
DROP TYPE pgv_error_key;

-- Short heap tuples carrying fast-default missing attributes (ALTER TABLE ADD
-- COLUMN ... DEFAULT) must expand their missing defaults on insert and update.
CREATE TEMP TABLE missing_default_src(id integer);
INSERT INTO missing_default_src VALUES (1), (2), (3);
ALTER TABLE missing_default_src ADD COLUMN n integer DEFAULT 7;
CREATE FUNCTION pgv_capture_old_missing() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_ARGV[0] = 'insert' THEN
        PERFORM pgv_insert('missing_def', 'r', OLD, false);
    ELSE
        PERFORM pgv_update('missing_def', 'r', OLD);
    END IF;
    RETURN OLD;
END $$;
CREATE TRIGGER tr_capture_old BEFORE DELETE ON missing_default_src
    FOR EACH ROW EXECUTE PROCEDURE pgv_capture_old_missing('insert');
DELETE FROM missing_default_src WHERE id IN (1, 2);
DROP TRIGGER tr_capture_old ON missing_default_src;
SELECT pgv_insert('missing_def', 'r', ROW(3, 99), false);
CREATE TRIGGER tr_capture_old BEFORE DELETE ON missing_default_src
    FOR EACH ROW EXECUTE PROCEDURE pgv_capture_old_missing('update');
DELETE FROM missing_default_src WHERE id = 3;
DO $$
BEGIN
    IF (SELECT array_agg(ROW(id, n)::text ORDER BY id)
        FROM pgv_select('missing_def', 'r') AS t(id integer, n integer))
       IS DISTINCT FROM ARRAY['(1,7)', '(2,7)', '(3,7)'] THEN
        RAISE EXCEPTION 'fast-default missing attribute was lost on record copy';
    END IF;
END $$;
DROP TABLE missing_default_src;
DROP FUNCTION pgv_capture_old_missing();
SELECT pgv_free();

-- Zero-attribute physical tuples after ALTER TABLE ADD COLUMN without DEFAULT
-- must treat the omitted key attribute as NULL without out-of-bounds reads.
CREATE TEMP TABLE zero_att_src();
INSERT INTO zero_att_src DEFAULT VALUES;
ALTER TABLE zero_att_src ADD COLUMN k text;
CREATE FUNCTION pgv_cap_zero() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_ARGV[0] = 'insert' THEN
        PERFORM pgv_insert('zero_def', 'r', OLD, false);
    ELSE
        PERFORM pgv_update('zero_def', 'r', OLD);
    END IF;
    RETURN OLD;
END $$;
CREATE TRIGGER tr_cap_zero BEFORE DELETE ON zero_att_src
    FOR EACH ROW EXECUTE PROCEDURE pgv_cap_zero('insert');
DELETE FROM zero_att_src;
DROP TRIGGER tr_cap_zero ON zero_att_src;
INSERT INTO zero_att_src DEFAULT VALUES;
DROP TABLE zero_att_src;
CREATE TEMP TABLE zero_att_src();
INSERT INTO zero_att_src DEFAULT VALUES;
ALTER TABLE zero_att_src ADD COLUMN k text;
CREATE TRIGGER tr_cap_zero BEFORE DELETE ON zero_att_src
    FOR EACH ROW EXECUTE PROCEDURE pgv_cap_zero('update');
DELETE FROM zero_att_src;
DO $$
BEGIN
    IF (SELECT count(*) FROM pgv_select('zero_def', 'r') AS t(k text) WHERE k IS NULL) <> 1 THEN
        RAISE EXCEPTION 'zero-attribute short tuple did not decode NULL key';
    END IF;
END $$;
DROP TABLE zero_att_src;
DROP FUNCTION pgv_cap_zero();
SELECT pgv_free();
