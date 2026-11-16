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
SELECT pgv_free();

-- Failed hash and comparison calls release unpublished tuples.
-- SQLSTATE and sequence counters verify the actual support function path.
CREATE TYPE pgv_error_key AS ENUM ('a', 'b');
CREATE SEQUENCE pgv_hash_calls;
CREATE SEQUENCE pgv_cmp_calls;
CREATE FUNCTION pgv_error_hash(pgv_error_key) RETURNS integer
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
BEGIN
    PERFORM nextval('pgv_hash_calls');
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
    IF current_setting('pgv_test.error', true) = 'compare' THEN
        RAISE EXCEPTION USING ERRCODE = 'PZ062', MESSAGE = 'controlled comparison failure';
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
            -- Comparison starts after one row is copied. Partial state remains
            -- in the transactional context, but the failing tuple is released.
            allowed_growth := CASE action WHEN 'hash' THEN 32768 ELSE 98304 END;
            IF after_used - before_used > allowed_growth THEN
                RAISE EXCEPTION 'failed copy retained its unpublished tuple';
            END IF;
        END IF;
        PERFORM pgv_free();
    END LOOP;
END
$$;
DROP OPERATOR CLASS pgv_error_hash_ops USING hash;
DROP OPERATOR CLASS pgv_error_cmp_ops USING btree;
DROP OPERATOR FAMILY pgv_error_hash_ops USING hash;
DROP OPERATOR FAMILY pgv_error_cmp_ops USING btree;
DROP FUNCTION pgv_error_hash(pgv_error_key);
DROP FUNCTION pgv_error_cmp(pgv_error_key, pgv_error_key);
DROP SEQUENCE pgv_hash_calls, pgv_cmp_calls;
DROP TYPE pgv_error_key;
