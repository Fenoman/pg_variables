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
