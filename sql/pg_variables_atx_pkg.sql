--
-- PGPRO-7614: function pgv_free() inside autonomous transaction
--
SELECT pgv_free();
--
--
-- Functions pgv_free() + pgv_get() inside autonomous transaction; package
-- with regular variable; autonomous transaction with commit.
--
BEGIN;
	SELECT pgv_set('vars', 'int1', 1);
	BEGIN AUTONOMOUS;
		SELECT pgv_get('vars', 'int1', null::int);
		SELECT pgv_free();
-- ERROR:  unrecognized package "vars"
		SELECT pgv_get('vars', 'int1', null::int);
	COMMIT;
-- ERROR:  unrecognized package "vars"
	SELECT pgv_get('vars', 'int1', null::int);
ROLLBACK;
--
--
-- Function pgv_free() inside autonomous transaction; package with
-- regular variable; autonomous transaction with commit.
--
BEGIN;
	SELECT pgv_set('vars', 'int1', 1);
	BEGIN AUTONOMOUS;
		SELECT pgv_free();
	COMMIT;
-- ERROR:  unrecognized package "vars"
	SELECT pgv_get('vars', 'int1', null::int);
ROLLBACK;
--
--
-- Function pgv_free() inside autonomous transaction; package with
-- regular variable; autonomous transaction with rollback.
--
BEGIN;
	SELECT pgv_set('vars', 'int1', 1);
	BEGIN AUTONOMOUS;
		SELECT pgv_free();
	ROLLBACK;
-- ERROR:  unrecognized package "vars"
	SELECT pgv_get('vars', 'int1', null::int);
ROLLBACK;
--
--
-- Function pgv_free() inside autonomous transaction; package with
-- transactional variable; autonomous transaction with rollback.
--
BEGIN;
	SELECT pgv_set('vars', 'int1', 1, true);
	BEGIN AUTONOMOUS;
		SELECT pgv_free();
	ROLLBACK;
	SELECT pgv_get('vars', 'int1', null::int);
ROLLBACK;
--
--
-- Function pgv_free() inside autonomous transaction; package with
-- transactional variable; autonomous transaction with commit.
--
BEGIN;
	SELECT pgv_set('vars', 'int1', 1, true);
	BEGIN AUTONOMOUS;
		SELECT pgv_free();
	COMMIT;
-- ERROR:  unrecognized package "vars"
	SELECT pgv_get('vars', 'int1', null::int);
ROLLBACK;
--
--
-- Function pgv_free() inside recursive autonomous transactions.
--
BEGIN;
	BEGIN AUTONOMOUS;
		SELECT pgv_set('vars', 'int1', 1);
		BEGIN AUTONOMOUS;
			BEGIN AUTONOMOUS;
				SELECT pgv_free();
			COMMIT;
-- ERROR:  unrecognized package "vars"
			SELECT pgv_get('vars', 'int1', null::int);
		COMMIT;
-- ERROR:  unrecognized package "vars"
		SELECT pgv_get('vars', 'int1', null::int);
	COMMIT;
ROLLBACK;
--
--
-- Function pgv_free() inside recursive autonomous transactions;
-- recreating the package after deletion with using regular
-- variable.
--
BEGIN;
	SELECT pgv_set('vars', 'int1', 1);
	BEGIN AUTONOMOUS;
		BEGIN AUTONOMOUS;
			SELECT pgv_get('vars', 'int1', null::int);
			BEGIN AUTONOMOUS;
				SELECT pgv_free();
			COMMIT;
-- ERROR:  unrecognized package "vars"
			SELECT pgv_get('vars', 'int1', null::int);
		COMMIT;
		SELECT pgv_set('vars', 'int1', 2);
	COMMIT;
	SELECT pgv_get('vars', 'int1', null::int);
ROLLBACK;
--
--
-- Function pgv_free() inside recursive autonomous transactions;
-- recreating the package after deletion with using transactional
-- variable.
--
BEGIN;
	SELECT pgv_set('vars', 'int1', 1);
	BEGIN AUTONOMOUS;
		BEGIN AUTONOMOUS;
			SELECT pgv_get('vars', 'int1', null::int);
			BEGIN AUTONOMOUS;
				SELECT pgv_free();
			COMMIT;
-- ERROR:  unrecognized package "vars"
			SELECT pgv_get('vars', 'int1', null::int);
		COMMIT;
		SELECT pgv_set('vars', 'int1', 2, true);
		SELECT pgv_list();
	COMMIT;
-- ERROR:  unrecognized package "vars"
	SELECT pgv_get('vars', 'int1', null::int);
ROLLBACK;
--
--
-- Test for case: do not free hash_seq_search scans of parent transaction
-- at end of the autonomous transaction.
--
BEGIN;
	SELECT pgv_insert('test', 'x', row (1::int, 2::int), false);
	SELECT pgv_insert('test', 'x', row (3::int, 4::int), false);
	DECLARE r1_cur CURSOR FOR SELECT pgv_select('test', 'x');
-- (1,2)
	FETCH 1 IN r1_cur;
	BEGIN AUTONOMOUS;
	ROLLBACK;
-- (3,4)
	FETCH 1 IN r1_cur;
	SELECT pgv_remove('test', 'x');
-- no rows: the scan ended with the variable
	FETCH 1 IN r1_cur;
ROLLBACK;
--
--
-- Test for case: pgv_free() should free hash_seq_search scans of all
-- (current ATX + parent) transactions.
--
BEGIN;
	SELECT pgv_insert('test', 'x', row (1::int, 2::int), false);
	DECLARE r1_cur CURSOR FOR SELECT pgv_select('test', 'x');
-- (1,2)
	FETCH 1 IN r1_cur;
	BEGIN AUTONOMOUS;
		SELECT pgv_free();
	ROLLBACK;
-- no rows: pgv_free() ended the scan
	FETCH 1 IN r1_cur;
ROLLBACK;
--
--
-- Test for case: pgv_set() created a regular variable; rollback
-- removes package state and creates a new state to make package valid.
-- Commit of next autonomous transaction should not replace this new
-- state (this is not allowed for autonomous transaction).
--
BEGIN;
	BEGIN AUTONOMOUS;
		SELECT pgv_set('vars', 'int1', 1);
	ROLLBACK;
	BEGIN AUTONOMOUS;
		SELECT pgv_set('vars', 'int1', 2);
	COMMIT;
ROLLBACK;
SELECT pgv_remove('vars', 'int1');
--
--
-- Test for case: pgv_set() created a regular variable and package with
-- (atxlevel=1, level=1). COMMIT changes this level to (atxlevel=1, level=0).
-- In the next autonomous transaction (atxlevel=1, level=1) we erroneously
-- detect that the package changed in upper transaction and remove the
-- package state (this is not allowed for autonomous transaction).
--
BEGIN;
	BEGIN AUTONOMOUS;
		SELECT pgv_set('vars', 'int1', 2);
	COMMIT;
	BEGIN AUTONOMOUS;
		SELECT pgv_free();
		SELECT pgv_set('vars', 'int1', 2, true);
	COMMIT;
ROLLBACK;
--
--
-- Test for case: pgv_set() created a regular variable and package with
-- (atxlevel=1, level=1). ROLLBACK changes this level to (atxlevel=0, level=0).
-- But ROLLBACK shouldn't change atxlevel in case rollback of sub-transaction.
--
BEGIN;
	BEGIN AUTONOMOUS;
		SAVEPOINT sp1;
		SELECT pgv_set('vars1', 'int1', 0);
		ROLLBACK TO sp1;
	COMMIT;
ROLLBACK;
SELECT pgv_remove('vars1', 'int1');

SELECT pgv_free();
--
--
-- PGPRO-7856
-- Test for case: we don't remove the package object without any variables at
-- the end of autonomous transaction but need to move the state of this object
-- to upper level.
--
BEGIN;
	BEGIN AUTONOMOUS;
		SAVEPOINT sp1;
		SELECT pgv_set('vars2', 'any1', 'variable exists'::text, true);
		SELECT pgv_free();
		RELEASE sp1;
	ROLLBACK;

	BEGIN AUTONOMOUS;
		SAVEPOINT sp2;
		SAVEPOINT sp3;
		SELECT pgv_free();
	COMMIT;
ROLLBACK;
--
--
-- Test for case: an autonomous transaction ends only its own scans. A scan
-- of the parent transaction (pgv_select, pgv_stats) continues after the
-- autonomous transaction commits or rolls back and runs to its end.
--
SELECT pgv_free();
DO $$
BEGIN
	FOR i IN 1..25 LOOP
		PERFORM pgv_insert('test', 'x', row (i, i * 10), false);
	END LOOP;
END $$;
CREATE FUNCTION pgv_atx_set(n int) RETURNS void AS $$
BEGIN AUTONOMOUS
	PERFORM pgv_set('vars', 'n', n);
END;
$$ LANGUAGE plpgsql;
CREATE FUNCTION pgv_atx_count(c refcursor) RETURNS int AS $$
DECLARE
	r			record;
	n			int := 0;
BEGIN
	LOOP
		FETCH c INTO r;
		EXIT WHEN NOT FOUND;
		n := n + 1;
	END LOOP;
	RETURN n;
END;
$$ LANGUAGE plpgsql;
-- NOTICE:  rows: 25, 25
DO $$
DECLARE
	r			record;
	n_block		int := 0;
	n_function	int := 0;
BEGIN
	FOR r IN SELECT pgv_select('test', 'x') LOOP
		n_block := n_block + 1;
		BEGIN AUTONOMOUS
			PERFORM pgv_set('vars', 'n', n_block);
		END;
	END LOOP;
	FOR r IN SELECT pgv_select('test', 'x') LOOP
		n_function := n_function + 1;
		PERFORM pgv_atx_set(n_function);
	END LOOP;
	RAISE NOTICE 'rows: %, %', n_block, n_function;
END $$;
BEGIN;
	DECLARE r1_cur CURSOR FOR SELECT pgv_select('test', 'x');
	MOVE 1 IN r1_cur;
	BEGIN AUTONOMOUS;
		SELECT pgv_set('vars', 'n', 1);
	COMMIT;
	BEGIN AUTONOMOUS;
	ROLLBACK;
-- 24
	SELECT pgv_atx_count('r1_cur');
-- no rows
	FETCH 1 IN r1_cur;
COMMIT;
-- Nested: a scan of an autonomous transaction survives the inner one.
BEGIN;
	BEGIN AUTONOMOUS;
		DECLARE r2_cur CURSOR FOR SELECT pgv_select('test', 'x');
		MOVE 1 IN r2_cur;
		BEGIN AUTONOMOUS;
			SELECT pgv_set('vars', 'n', 2);
		COMMIT;
-- 24
		SELECT pgv_atx_count('r2_cur');
	COMMIT;
COMMIT;
-- Packages scan: test, vars, vars2, vars3.
SELECT pgv_set('vars2', 'a', 1), pgv_set('vars3', 'a', 1);
BEGIN;
	DECLARE r3_cur CURSOR FOR SELECT pgv_stats();
	MOVE 1 IN r3_cur;
	BEGIN AUTONOMOUS;
		SELECT pgv_set('vars', 'n', 3);
	COMMIT;
-- 3
	SELECT pgv_atx_count('r3_cur');
COMMIT;
-- Scans of the parent and of the autonomous transaction are open together:
-- the unread scan of the autonomous one ends with it, the parent goes on.
BEGIN;
	DECLARE r5_cur CURSOR FOR SELECT pgv_select('test', 'x');
	MOVE 1 IN r5_cur;
	BEGIN AUTONOMOUS;
		DECLARE r6_cur CURSOR FOR SELECT pgv_select('test', 'x');
		MOVE 3 IN r6_cur;
	COMMIT;
	BEGIN AUTONOMOUS;
		DECLARE r7_cur CURSOR FOR SELECT pgv_select('test', 'x');
		MOVE 3 IN r7_cur;
	ROLLBACK;
-- 24
	SELECT pgv_atx_count('r5_cur');
COMMIT;
-- The autonomous transaction removes the variable the parent scans.
BEGIN;
	DECLARE r4_cur CURSOR FOR SELECT pgv_select('test', 'x');
	MOVE 1 IN r4_cur;
	BEGIN AUTONOMOUS;
		SELECT pgv_remove('test', 'x');
	COMMIT;
-- 0
	SELECT pgv_atx_count('r4_cur');
COMMIT;
DROP FUNCTION pgv_atx_set(int);
DROP FUNCTION pgv_atx_count(refcursor);
SELECT pgv_free();

SELECT pgv_free();
BEGIN;
BEGIN AUTONOMOUS;
SELECT pgv_set('atx_new', 'v', 1, true);
COMMIT;
SELECT pgv_exists('atx_new') AS package_exists, pgv_exists('atx_new', 'v') AS variable_exists;
COMMIT;
DO $$ BEGIN
 IF pgv_exists('atx_new') THEN RAISE EXCEPTION 'ATX left an empty package visible'; END IF;
END $$;

SELECT pgv_free();
BEGIN;
SELECT pgv_set('atx_recreate', 'old_tx', 10, true);
SELECT pgv_remove('atx_recreate');
BEGIN AUTONOMOUS;
SELECT pgv_set('atx_recreate', 'new_regular', 99, false);
COMMIT;
SELECT pgv_get('atx_recreate', 'old_tx', NULL::integer, false) AS value_after_atx;
COMMIT;
DO $$ BEGIN
 IF pgv_exists('atx_recreate', 'old_tx') OR
    pgv_get('atx_recreate', 'new_regular', NULL::integer, false) IS DISTINCT FROM 99 THEN
  RAISE EXCEPTION 'ATX recreation retained a removed value or lost regular data';
 END IF;
END $$;
SELECT pgv_free();

SELECT pgv_free();
-- Rolling back the parent's removal restores its original transactional data.
BEGIN;
SELECT pgv_set('atx_rollback', 'old_tx', 10, true);
SAVEPOINT before_removal;
SELECT pgv_remove('atx_rollback');
SAVEPOINT after_removal;
BEGIN AUTONOMOUS;
SELECT pgv_set('atx_rollback', 'regular', 99, false);
ROLLBACK;
DO $$ BEGIN
 IF pgv_exists('atx_rollback', 'old_tx') OR
    pgv_get('atx_rollback', 'old_tx', NULL::text, false) IS NOT NULL OR
    EXISTS (SELECT FROM pgv_list() WHERE package = 'atx_rollback' AND name = 'old_tx') THEN
  RAISE EXCEPTION 'ATX revived parent-removed data';
 END IF;
END $$;
ROLLBACK TO before_removal;
DO $$ BEGIN
 IF pgv_get('atx_rollback', 'old_tx', NULL::integer) IS DISTINCT FROM 10 OR
    pgv_get('atx_rollback', 'regular', NULL::integer) IS DISTINCT FROM 99 THEN
  RAISE EXCEPTION 'parent rollback did not restore its transactional data';
 END IF;
END $$;
COMMIT;
SELECT pgv_free();
-- Inner ATX cleanup restores the outer ATX, then outer cleanup removes it.
BEGIN;
BEGIN AUTONOMOUS;
SELECT pgv_set('nested_empty', 'outer_tx', 1, true);
BEGIN AUTONOMOUS;
SELECT pgv_set('nested_empty', 'inner_tx', 2, true);
COMMIT;
DO $$ BEGIN
 IF NOT pgv_exists('nested_empty', 'outer_tx') OR pgv_exists('nested_empty', 'inner_tx') THEN
  RAISE EXCEPTION 'inner ATX did not restore the outer state';
 END IF;
END $$;
COMMIT;
COMMIT;
DO $$ BEGIN
 IF pgv_exists('nested_empty') THEN RAISE EXCEPTION 'nested ATX left an empty package'; END IF;
END $$;
-- Removing new child packages preserves an already active parent stats scan.
CREATE OR REPLACE FUNCTION pgv_empty_atx(n integer) RETURNS void LANGUAGE plpgsql AS $$
BEGIN AUTONOMOUS
    PERFORM pgv_set('empty_atx_' || n, 'v', n, true);
END $$;
DO $$ BEGIN
 FOR i IN 1..10 LOOP PERFORM pgv_set('parent_stats_' || i, 'v', i, false); END LOOP;
END $$;
BEGIN;
DECLARE parent_stats_cursor CURSOR FOR SELECT pgv_stats();
MOVE 1 FROM parent_stats_cursor;
SELECT count(*) FROM (SELECT pgv_empty_atx(i) FROM generate_series(1, 100) i) s;
DO $$
DECLARE r record; n integer := 0; c refcursor := 'parent_stats_cursor';
BEGIN
 LOOP
  FETCH c INTO r;
  EXIT WHEN NOT FOUND;
  n := n + 1;
 END LOOP;
 IF n <> 9 OR (SELECT count(*) FROM pgv_stats()) <> 10 THEN
  RAISE EXCEPTION 'ATX cleanup changed the parent scan or retained empty packages: %', n;
 END IF;
END $$;
COMMIT;
DROP FUNCTION pgv_empty_atx(integer);
SELECT pgv_free();

-- Record callbacks may use autonomous transactions for independent work while
-- active-collection mutations raise object_in_use without corrupting parent state.
CREATE SCHEMA atx_cb_s;
CREATE TYPE atx_cb_s.k_enum AS ENUM ('a', 'b');
CREATE FUNCTION atx_cb_s.try_atx() RETURNS void LANGUAGE plpgsql AS $$
BEGIN AUTONOMOUS
    CASE current_setting('pgv_test.atx_cb_mode', true)
      WHEN 'independent' THEN
        PERFORM pgv_set('atx_cb_indep', 'reg_v', 42, false);
        PERFORM pgv_set('atx_cb_indep', 'tx_v', 99, true);
      WHEN 'mutate_active' THEN
        PERFORM pgv_set('rec_atx_cb', 'r', 1, false);
      WHEN 'remove_var' THEN
        PERFORM pgv_remove('rec_atx_cb', 'r');
      WHEN 'update_active' THEN
        PERFORM pgv_update('rec_atx_cb', 'r', ROW('a'::atx_cb_s.k_enum, 99));
      WHEN 'delete_active' THEN
        PERFORM pgv_delete('rec_atx_cb', 'r', 'a'::atx_cb_s.k_enum);
      WHEN 'remove_pkg' THEN
        PERFORM pgv_remove('rec_atx_cb');
      WHEN 'free_all' THEN
        PERFORM pgv_free();
      ELSE NULL;
    END CASE;
END $$;
CREATE FUNCTION atx_cb_s.k_cmp(atx_cb_s.k_enum, atx_cb_s.k_enum)
RETURNS integer LANGUAGE plpgsql IMMUTABLE STRICT AS $$
BEGIN
    PERFORM atx_cb_s.try_atx();
    RETURN CASE WHEN $1 < $2 THEN -1 WHEN $1 > $2 THEN 1 ELSE 0 END;
END $$;
CREATE FUNCTION atx_cb_s.k_hash(atx_cb_s.k_enum)
RETURNS integer LANGUAGE plpgsql IMMUTABLE STRICT AS $$
BEGIN
    PERFORM atx_cb_s.try_atx();
    RETURN 1;
END $$;
CREATE OPERATOR CLASS atx_cb_s.k_ops DEFAULT FOR TYPE atx_cb_s.k_enum USING hash AS
    OPERATOR 1 = (anyenum, anyenum),
    FUNCTION 1 atx_cb_s.k_hash(atx_cb_s.k_enum);
CREATE OPERATOR CLASS atx_cb_s.k_btree_ops DEFAULT FOR TYPE atx_cb_s.k_enum USING btree AS
    OPERATOR 1 < (anyenum, anyenum),
    OPERATOR 2 <= (anyenum, anyenum),
    OPERATOR 3 = (anyenum, anyenum),
    OPERATOR 4 >= (anyenum, anyenum),
    OPERATOR 5 > (anyenum, anyenum),
    FUNCTION 1 atx_cb_s.k_cmp(atx_cb_s.k_enum, atx_cb_s.k_enum);
BEGIN;
SELECT pgv_set('parent_keep', 'tx_val', 777, true);
SET LOCAL pgv_test.atx_cb_mode = 'independent';
SELECT pgv_insert('rec_atx_cb', 'r', ROW('a'::atx_cb_s.k_enum, 10), true);
DO $$
DECLARE
    m text;
BEGIN
    IF pgv_get('atx_cb_indep', 'reg_v', NULL::integer, false) IS DISTINCT FROM 42 OR
       pgv_exists('atx_cb_indep', 'tx_v') OR
       pgv_get('parent_keep', 'tx_val', NULL::integer, false) IS DISTINCT FROM 777 THEN
        RAISE EXCEPTION 'independent ATX inside callback corrupted state';
    END IF;
    FOREACH m IN ARRAY ARRAY['mutate_active', 'remove_var', 'update_active', 'delete_active', 'remove_pkg', 'free_all'] LOOP
        PERFORM set_config('pgv_test.atx_cb_mode', m, true);
        BEGIN
            PERFORM pgv_insert('rec_atx_cb', 'r', ROW('b'::atx_cb_s.k_enum, 20), true);
            RAISE EXCEPTION 'expected object_in_use for mode %', m;
        EXCEPTION WHEN object_in_use THEN
            NULL;
        END;
        IF pgv_get('parent_keep', 'tx_val', NULL::integer, false) IS DISTINCT FROM 777 OR
           (SELECT count(*) FROM (SELECT pgv_select('rec_atx_cb', 'r')) s) <> 1 THEN
            RAISE EXCEPTION 'failed ATX mode % damaged parent state', m;
        END IF;
    END LOOP;
END $$;
COMMIT;
DROP SCHEMA atx_cb_s CASCADE;
SELECT pgv_free();

-- First extension load inside nested autonomous transactions must still clean
-- up child transactional state on both COMMIT and ABORT without parent frames.
CREATE FUNCTION pgv_atx_lazy_d2(do_abort boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN AUTONOMOUS
    PERFORM pgv_set('lazy_d2_tx', 'v', 20, true);
    PERFORM pgv_set('lazy_d2_reg', 'v', 2, false);
    IF do_abort THEN
        RAISE EXCEPTION 'planned d2 abort';
    END IF;
END $$;
CREATE FUNCTION pgv_atx_lazy_d1(abort_d2 boolean, abort_d1 boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN AUTONOMOUS
    BEGIN
        PERFORM pgv_atx_lazy_d2(abort_d2);
    EXCEPTION WHEN raise_exception THEN
        NULL;
    END;
    IF pgv_exists('lazy_d2_tx') THEN
        RAISE EXCEPTION 'depth-2 transactional package escaped to depth-1';
    END IF;
    PERFORM pgv_set('lazy_d1_tx', 'v', 10, true);
    PERFORM pgv_set('lazy_d1_reg', 'v', 1, false);
    IF abort_d1 THEN
        RAISE EXCEPTION 'planned d1 abort';
    END IF;
END $$;
CREATE FUNCTION pgv_atx_lazy_direct_d1(tx_only boolean, do_abort boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN AUTONOMOUS
    PERFORM pgv_set('lazy_direct_tx', 'v', 11, true);
    IF NOT tx_only THEN
        PERFORM pgv_set('lazy_direct_reg', 'v', 111, false);
    END IF;
    IF do_abort THEN
        RAISE EXCEPTION 'planned direct d1 abort';
    END IF;
END $$;
\c -
BEGIN;
SELECT pgv_atx_lazy_direct_d1(true, false);
SELECT pgv_exists('lazy_direct_tx') AS direct_tx_only_visible,
       count(*) AS main_ctx_after_tx_only_lazy_commit
FROM pg_backend_memory_contexts WHERE name = 'pg_variables: main memory context';
COMMIT;
\c -
BEGIN;
SELECT pgv_atx_lazy_direct_d1(false, false);
SELECT pgv_exists('lazy_direct_tx') AS direct_d1_tx_visible,
       pgv_get('lazy_direct_reg', 'v', NULL::integer, false) AS direct_d1_reg
FROM (SELECT 1) s;
COMMIT;
\c -
BEGIN;
DO $$
BEGIN
    PERFORM pgv_atx_lazy_direct_d1(false, true);
EXCEPTION WHEN raise_exception THEN
    NULL;
END $$;
SELECT pgv_exists('lazy_direct_tx') AS direct_d1_tx_after_abort,
       pgv_get('lazy_direct_reg', 'v', NULL::integer, false) AS direct_d1_reg_after_abort
FROM (SELECT 1) s;
COMMIT;
\c -
BEGIN;
SELECT pgv_atx_lazy_d1(false, false);
SELECT pgv_exists('lazy_d1_tx') AS d1_tx_visible,
       pgv_exists('lazy_d2_tx') AS d2_tx_visible,
       pgv_get('lazy_d1_reg', 'v', NULL::integer, false) AS d1_reg,
       pgv_get('lazy_d2_reg', 'v', NULL::integer, false) AS d2_reg,
       count(*) AS stats_pkgs FROM pgv_stats();
COMMIT;
\c -
BEGIN;
DO $$
BEGIN
    PERFORM pgv_atx_lazy_d1(true, true);
EXCEPTION WHEN raise_exception THEN
    NULL;
END $$;
SELECT pgv_exists('lazy_d1_tx') AS d1_tx_after_abort,
       pgv_exists('lazy_d2_tx') AS d2_tx_after_abort,
       pgv_get('lazy_d1_reg', 'v', NULL::integer, false) AS d1_reg_after_abort,
       pgv_get('lazy_d2_reg', 'v', NULL::integer, false) AS d2_reg_after_abort,
       count(*) AS stats_pkgs_after_abort FROM pgv_stats();
COMMIT;
DROP FUNCTION pgv_atx_lazy_direct_d1(boolean, boolean);
DROP FUNCTION pgv_atx_lazy_d1(boolean, boolean);
DROP FUNCTION pgv_atx_lazy_d2(boolean);
SELECT pgv_free();

-- Parent transactional-only packages must stay invisible inside child ATX
-- without leaking parent trans_var_num into child package state.
BEGIN;
SELECT pgv_set('atx_iso_pkg', 'parent_tx', 10, true);
BEGIN AUTONOMOUS;
DO $$ BEGIN
    IF pgv_exists('atx_iso_pkg') THEN
        RAISE EXCEPTION 'parent transactional-only package leaked into ATX';
    END IF;
    PERFORM pgv_set('atx_iso_pkg', 'child_tx', 20, true);
    PERFORM pgv_remove('atx_iso_pkg', 'child_tx');
    IF pgv_exists('atx_iso_pkg') THEN
        RAISE EXCEPTION 'child package retained parent trans_var_num';
    END IF;
END $$;
COMMIT;
DO $$ BEGIN
    IF pgv_get('atx_iso_pkg', 'parent_tx', NULL::integer) IS DISTINCT FROM 10 THEN
        RAISE EXCEPTION 'child ATX isolation lost parent transactional value';
    END IF;
END $$;
COMMIT;
SELECT pgv_free();

-- Removing and recreating a package inside a committed child ATX must keep
-- parent transactional values removed across parent reads and savepoint rollbacks.
BEGIN;
SELECT pgv_set('atx_self_recreate', 'old_tx', 10, true);
SELECT pgv_set('atx_self_recreate', 'old_reg', 1, false);
SAVEPOINT parent_sp;
SELECT pgv_set('atx_self_recreate', 'old_tx', 20, true);
BEGIN AUTONOMOUS;
SELECT pgv_remove('atx_self_recreate');
SELECT pgv_set('atx_self_recreate', 'new_reg', 99, false);
COMMIT;
DO $$ BEGIN
    IF pgv_exists('atx_self_recreate', 'old_tx') OR
       pgv_get('atx_self_recreate', 'old_tx', NULL::integer, false) IS NOT NULL OR
       pgv_exists('atx_self_recreate', 'old_reg') OR
       pgv_get('atx_self_recreate', 'new_reg', NULL::integer, false) IS DISTINCT FROM 99 THEN
        RAISE EXCEPTION 'committed ATX removal+recreation revived parent transactional value';
    END IF;
END $$;
ROLLBACK TO parent_sp;
DO $$ BEGIN
    IF pgv_exists('atx_self_recreate', 'old_tx') OR
       pgv_get('atx_self_recreate', 'new_reg', NULL::integer, false) IS DISTINCT FROM 99 THEN
        RAISE EXCEPTION 'parent savepoint rollback undid committed ATX package removal';
    END IF;
END $$;
COMMIT;
SELECT pgv_free();

-- Committed ATX package removal without child recreation must still synchronize
-- parent removal state and trans_var_num for subsequent parent operations.
BEGIN;
SELECT pgv_set('atx_parent_after_rm', 'old_tx', 10, true);
BEGIN AUTONOMOUS;
SELECT pgv_free();
COMMIT;
SAVEPOINT sp_after_atx_rm;
SELECT pgv_set('atx_parent_after_rm', 'reg', 55, false);
ROLLBACK TO sp_after_atx_rm;
DO $$ BEGIN
    IF pgv_exists('atx_parent_after_rm', 'old_tx') OR
       pgv_get('atx_parent_after_rm', 'reg', NULL::integer, false) IS DISTINCT FROM 55 THEN
        RAISE EXCEPTION 'parent savepoint rollback after ATX removal revived old_tx';
    END IF;
END $$;
SELECT pgv_remove('atx_parent_after_rm', 'reg');
COMMIT;
DO $$ BEGIN
    IF pgv_exists('atx_parent_after_rm') OR
       (SELECT count(*) FROM pgv_stats() WHERE package = 'atx_parent_after_rm') <> 0 THEN
        RAISE EXCEPTION 'package stayed alive or in pgv_stats after ATX removal and regular cleanup';
    END IF;
END $$;
SELECT pgv_free();

-- A rolled-back savepoint around pgv_free() in a committed ATX, or removing only
-- a regular variable in ATX, must preserve parent transactional values, while a
-- committed level-0 regular package removed in ATX must disappear from pgv_stats().
BEGIN;
SELECT pgv_set('atx_keep_tx', 'old_tx', 42, true);
SELECT pgv_set('atx_keep_tx', 'old_reg', 7, false);
BEGIN AUTONOMOUS;
SAVEPOINT sp_undo_free;
SELECT pgv_free();
ROLLBACK TO sp_undo_free;
COMMIT;
DO $$ BEGIN
    IF pgv_get('atx_keep_tx', 'old_tx', NULL::integer, false) IS DISTINCT FROM 42 OR
       pgv_exists('atx_keep_tx', 'old_reg') THEN
        RAISE EXCEPTION 'rolled-back ATX pgv_free wiped parent transactional variable';
    END IF;
END $$;
SELECT pgv_set('atx_keep_tx', 'old_reg2', 8, false);
BEGIN AUTONOMOUS;
SELECT pgv_remove('atx_keep_tx', 'old_reg2');
COMMIT;
DO $$ BEGIN
    IF pgv_get('atx_keep_tx', 'old_tx', NULL::integer, false) IS DISTINCT FROM 42 THEN
        RAISE EXCEPTION 'removing only regular variable in ATX hid parent transactional variable';
    END IF;
END $$;
COMMIT;
SELECT pgv_set('atx_dead_reg_pkg', 'reg', 1, false);
BEGIN;
BEGIN AUTONOMOUS;
SELECT pgv_free();
COMMIT;
COMMIT;
DO $$ BEGIN
    IF (SELECT count(*) FROM pgv_stats() WHERE package = 'atx_dead_reg_pkg') <> 0 THEN
        RAISE EXCEPTION 'ATX pgv_free left dead level-0 package in pgv_stats';
    END IF;
END $$;
SELECT pgv_free();

-- Same-name regular and new-type transactional reuse in parent after committed
-- child ATX package removal.
BEGIN;
SELECT pgv_set('atx_same_name', 'x', 1, true);
SELECT pgv_set('atx_same_name', 'old_txt', 'abc'::text, true);
SELECT pgv_set('atx_same_name', 'seed', 1, false);
BEGIN AUTONOMOUS;
SELECT pgv_remove('atx_same_name');
SELECT pgv_set('atx_same_name', 'x', 2, false);
COMMIT;
SELECT pgv_get('atx_same_name', 'x', NULL::integer) AS x_from_child;
SELECT pgv_set('atx_same_name', 'x', 3, false);
SELECT pgv_set('atx_same_name', 'old_txt', 456, true);
DO $$ BEGIN
    IF pgv_get('atx_same_name', 'x', NULL::integer, false) IS DISTINCT FROM 3 OR
       pgv_get('atx_same_name', 'old_txt', NULL::integer, false) IS DISTINCT FROM 456 OR
       (SELECT count(*) FROM pgv_list() WHERE package = 'atx_same_name' AND name = 'x') <> 1 THEN
        RAISE EXCEPTION 'parent same-name reuse after ATX package removal failed';
    END IF;
END $$;
COMMIT;
SELECT pgv_free();

-- Child ATX must reject regular creation of a live parent transactional name
-- unless the package was removed, and an aborted ATX after removal+recreation
-- must not leave duplicate variable names in pgv_list().
BEGIN;
SELECT pgv_set('atx_opp_guard', 'seed', 0, false);
SELECT pgv_set('atx_opp_guard', 'x', 10, true);
SELECT pgv_set('atx_opp_guard', 'keep_tx', 20, true);
BEGIN AUTONOMOUS;
SELECT pgv_set('atx_opp_guard', 'x', 99, false);
ROLLBACK;
BEGIN AUTONOMOUS;
SELECT pgv_remove('atx_opp_guard');
SELECT pgv_set('atx_opp_guard', 'x', 77, false);
ROLLBACK;
DO $$ BEGIN
    IF pgv_get('atx_opp_guard', 'x', NULL::integer, false) IS DISTINCT FROM 77 OR
       pgv_get('atx_opp_guard', 'keep_tx', NULL::integer, false) IS DISTINCT FROM 20 OR
       (SELECT count(*) FROM pgv_list() WHERE package = 'atx_opp_guard' AND name = 'x') <> 1 THEN
        RAISE EXCEPTION 'aborted ATX left duplicate name or lost non-colliding transactional var';
    END IF;
END $$;
COMMIT;
SELECT pgv_free();

-- Multiple parent PackStates and nested committed ATX removal inside aborted ATX.
BEGIN;
SELECT pgv_set('atx_multi_ps', 'seed', 0, false);
SELECT pgv_set('atx_multi_ps', 'tx1', 1, true);
SAVEPOINT sp_new_tx;
SELECT pgv_set('atx_multi_ps', 'tx2', 2, true);
BEGIN AUTONOMOUS;
SELECT pgv_remove('atx_multi_ps');
SELECT pgv_set('atx_multi_ps', 'reg', 50, false);
COMMIT;
SELECT pgv_set('atx_multi_ps', 'tx3', 3, true);
ROLLBACK TO sp_new_tx;
DO $$ BEGIN
    IF pgv_exists('atx_multi_ps', 'tx1') OR
       pgv_exists('atx_multi_ps', 'tx2') OR
       pgv_exists('atx_multi_ps', 'tx3') OR
       pgv_get('atx_multi_ps', 'reg', NULL::integer, false) IS DISTINCT FROM 50 THEN
        RAISE EXCEPTION 'multi-PackState rollback after ATX removal failed';
    END IF;
END $$;
COMMIT;
SELECT pgv_free();

BEGIN;
SELECT pgv_set('atx_nested_rm', 'seed', 0, false);
SELECT pgv_set('atx_nested_rm', 'tx', 11, true);
BEGIN AUTONOMOUS;
BEGIN AUTONOMOUS;
SELECT pgv_remove('atx_nested_rm');
COMMIT;
ROLLBACK;
DO $$ BEGIN
    IF pgv_exists('atx_nested_rm', 'tx') OR pgv_exists('atx_nested_rm') THEN
        RAISE EXCEPTION 'committed inner ATX removal was lost when outer ATX rolled back';
    END IF;
END $$;
COMMIT;
SELECT pgv_free();

-- Level-0 regular packages emptied in child ATX must disappear from pgv_stats()
-- even when parent modified an unrelated package or child used pgv_remove(pkg, var).
SELECT pgv_set('atx_dead_l0_a', 'v', 1, false);
SELECT pgv_set('atx_dead_l0_b', 'v', 2, false);
BEGIN;
SELECT pgv_set('atx_unrelated_tx', 'tx', 10, true);
BEGIN AUTONOMOUS;
SELECT pgv_remove('atx_dead_l0_a');
SELECT pgv_remove('atx_dead_l0_b', 'v');
COMMIT;
DO $$ BEGIN
    IF (SELECT count(*) FROM pgv_stats() WHERE package IN ('atx_dead_l0_a', 'atx_dead_l0_b')) <> 0 THEN
        RAISE EXCEPTION 'emptied level-0 regular packages remained in pgv_stats';
    END IF;
END $$;
COMMIT;
DO $$ BEGIN
    IF (SELECT count(*) FROM pgv_stats() WHERE package IN ('atx_dead_l0_a', 'atx_dead_l0_b')) <> 0 THEN
        RAISE EXCEPTION 'emptied level-0 regular packages remained in pgv_stats after commit';
    END IF;
END $$;
SELECT pgv_free();
