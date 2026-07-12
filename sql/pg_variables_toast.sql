SELECT pgv_free();

-- A by-reference scalar value may reach pgv_set as an on-disk TOAST pointer
-- (e.g. selected straight from a table column). The value must be inlined when
-- stored, so it survives deletion of the source row that owns the TOAST chunks.
CREATE TABLE pgv_toast_src (id int, v text);
ALTER TABLE pgv_toast_src ALTER COLUMN v SET STORAGE EXTERNAL;
INSERT INTO pgv_toast_src VALUES (1, repeat('abcdefgh', 20000));

-- The value arrives as an external TOAST pointer straight from the table.
SELECT pgv_set('toast_pkg', 'scalar', v) FROM pgv_toast_src WHERE id = 1;

-- Destroy the source so the out-of-line TOAST chunks are reclaimed.
DELETE FROM pgv_toast_src;
VACUUM pgv_toast_src;

-- Must still return the stored value intact, not "missing chunk number".
SELECT length(pgv_get('toast_pkg', 'scalar', NULL::text)) AS scalar_len;
SELECT pgv_get('toast_pkg', 'scalar', NULL::text) = repeat('abcdefgh', 20000)
       AS scalar_matches;

SELECT pgv_free();

-- An inline-compressed varlena is already self-contained. It may bypass
-- detoast_external_attr(), but the package must still own a durable copy.
CREATE TABLE pgv_compressed_src (id int, v text);
ALTER TABLE pgv_compressed_src ALTER COLUMN v SET STORAGE MAIN;
INSERT INTO pgv_compressed_src VALUES (1, repeat('abcd', 2000));
SELECT pgv_set('toast_pkg', 'compressed', v)
FROM pgv_compressed_src WHERE id = 1;
DROP TABLE pgv_compressed_src;
SELECT length(pgv_get('toast_pkg', 'compressed', NULL::text))
       AS compressed_len;
SELECT pgv_get('toast_pkg', 'compressed', NULL::text) = repeat('abcd', 2000)
       AS compressed_matches;
SELECT pgv_free();

-- Record variables already inline external TOAST pointers via
-- toast_flatten_tuple_to_datum(); verify that behaviour is preserved.
CREATE TABLE pgv_toast_rec (id int, v text);
ALTER TABLE pgv_toast_rec ALTER COLUMN v SET STORAGE EXTERNAL;
INSERT INTO pgv_toast_rec VALUES (1, repeat('xy', 60000));

SELECT pgv_insert('toast_rec_pkg', 'r', t) FROM pgv_toast_rec t WHERE id = 1;

DELETE FROM pgv_toast_rec;
VACUUM pgv_toast_rec;

SELECT id, length(v) AS v_len
  FROM pgv_select('toast_rec_pkg', 'r') AS x(id int, v text);

SELECT pgv_free();

DROP TABLE pgv_toast_src;
DROP TABLE pgv_toast_rec;
