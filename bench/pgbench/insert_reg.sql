-- Alternate two packages so each pgv_insert() is a package-cache miss.  The
-- matching deletes keep both variables alive but empty, avoiding record-hash
-- growth while every pgbench workload iteration repeats the same steady-state
-- path. Each statement is intentionally autocommitted, matching baseline_4x.
SELECT pgv_insert('bench_record_a', 'items',
                  ROW (1::int, 'value'::text), false);
SELECT pgv_delete('bench_record_a', 'items', 1::int);
SELECT pgv_insert('bench_record_b', 'items',
                  ROW (1::int, 'value'::text), false);
SELECT pgv_delete('bench_record_b', 'items', 1::int);
