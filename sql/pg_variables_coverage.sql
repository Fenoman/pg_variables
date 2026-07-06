SELECT pgv_free();

-- Coverage for transaction-boundary paths of the discard semantics that were
-- previously untested: WITH HOLD cursors, COMMIT AND CHAIN, and a COMMIT inside
-- a PL/pgSQL procedure.

-- WITH HOLD cursor over pgv_select(): the set-returning function is
-- materialised at commit, so the cursor keeps returning its rows afterwards.
SELECT pgv_insert('cov', 'r', ROW (1::int, 'a'::text), false);
SELECT pgv_insert('cov', 'r', ROW (2::int, 'b'::text), false);
BEGIN;
DECLARE ch CURSOR WITH HOLD FOR
    SELECT id, val FROM pgv_select('cov', 'r') AS t(id int, val text) ORDER BY id;
COMMIT;
FETCH ALL FROM ch;
CLOSE ch;
SELECT pgv_free();

-- COMMIT AND CHAIN ends the transaction (discarding transactional variables)
-- and immediately starts a new one; the regular variable survives.
BEGIN;
SELECT pgv_set('cov2', 'reg', 5);
SELECT pgv_set('cov2', 'tx', 1, true);
COMMIT AND CHAIN;
SELECT pgv_exists('cov2', 'tx') AS tx_after_chain;
SELECT pgv_get('cov2', 'reg', NULL::int) AS reg_after_chain;
COMMIT;
SELECT pgv_free();

-- A COMMIT inside a PL/pgSQL procedure discards the transactional variable set
-- before it, while the regular variable persists.
CREATE PROCEDURE pgv_cov_proc() LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pgv_set('cov3', 'tx', 7, true);
    PERFORM pgv_set('cov3', 'reg', 8, false);
    COMMIT;
END;
$$;
CALL pgv_cov_proc();
SELECT pgv_exists('cov3', 'tx') AS tx_after_proc;
SELECT pgv_get('cov3', 'reg', NULL::int) AS reg_after_proc;
DROP PROCEDURE pgv_cov_proc();
SELECT pgv_free();
