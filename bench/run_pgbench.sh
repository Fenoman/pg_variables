#!/usr/bin/env bash
#
# Per-workload-iteration throughput benchmark for the pg_variables hot paths.
#
# Unlike bench/sql/hot_paths.sql (which loops inside a single statement and so
# never exercises the per-commit changesStack/discard machinery), each pgbench
# script is repeated as one pgbench transaction. Individual SQL statements use
# autocommit unless the script contains an explicit BEGIN/COMMIT, as tx_block.sql
# does. Every scenario is run REPEATS times and the median tps is reported next
# to a statement-count-matched baseline so the extension's share is clear.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PGB_DIR="${SCRIPT_DIR}/pgbench"
RESULTS_DIR="${RESULTS_DIR:-${SCRIPT_DIR}/results}"
DBNAME="${DBNAME:-pgvbench}"
PSQL="${PSQL:-psql}"
PGBENCH="${PGBENCH:-pgbench}"

TXNS="${TXNS:-200000}"      # transactions per run (pgbench -t)
CLIENTS="${CLIENTS:-1}"     # keep single-client for stable per-op numbers
REPEATS="${REPEATS:-5}"     # runs per scenario; the median is reported

# Scenarios: "label:script". baseline first so it is easy to subtract.
# pg_variables state is backend-local, so every script must be self-contained
# within pgbench's own connection (a variable set from psql is invisible here).
SCENARIOS=(
	"baseline:baseline.sql"
	"set_reg:set_reg.sql"
	"baseline_4x:baseline_4x.sql"
	"insert_reg:insert_reg.sql"
	"set_tx:set_tx.sql"
	"tx_block:tx_block.sql"
)

mkdir -p "${RESULTS_DIR}"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="${RESULTS_DIR}/pgbench_${STAMP}.out"

# Provenance: pin the numbers to a build so before/after comparisons are honest.
GIT_REV="$(git -C "${SCRIPT_DIR}/.." rev-parse --short HEAD 2>/dev/null || echo unknown)"
GIT_DIRTY=""
git -C "${SCRIPT_DIR}/.." diff --quiet 2>/dev/null || GIT_DIRTY=" (dirty)"
PG_VERSION="$(${PSQL} -X -tAq -d "${DBNAME}" -c 'SHOW server_version' 2>/dev/null || echo unknown)"

{
	echo "# pg_variables pgbench results"
	echo "# date:       ${STAMP}"
	echo "# git:        ${GIT_REV}${GIT_DIRTY}"
	echo "# postgres:   ${PG_VERSION}"
	echo "# dbname:     ${DBNAME}"
	echo "# txns/run:   ${TXNS}  clients: ${CLIENTS}  repeats: ${REPEATS}"
	echo "#"
	echo "# scenario   median_tps   runs_tps"
} | tee "${OUT}" >&2

# Only the extension itself (a catalog object) needs to pre-exist; variables are
# backend-local and are created by the scripts inside pgbench's own connection.
# shellcheck disable=SC2086
${PSQL} -X -q -d "${DBNAME}" -c 'CREATE EXTENSION IF NOT EXISTS pg_variables' >/dev/null

median()
{
	# median of stdin numbers (one per line); LC_ALL=C keeps a '.' decimal.
	LC_ALL=C sort -n | LC_ALL=C awk '{ a[NR] = $1 } END {
		if (NR == 0) { print "0"; exit }
		if (NR % 2) printf "%.1f\n", a[(NR + 1) / 2];
		else printf "%.1f\n", (a[NR / 2] + a[NR / 2 + 1]) / 2 }'
}

for entry in "${SCENARIOS[@]}"; do
	label="${entry%%:*}"
	script="${PGB_DIR}/${entry##*:}"
	runs=()
	for _ in $(seq 1 "${REPEATS}"); do
		# -n: no VACUUM (pgbench_* tables are not used); -M prepared for stable timing.
		# The `|| true` keeps a single failed run from aborting the whole sweep.
		# shellcheck disable=SC2086
		tps="$({ ${PGBENCH} -n -M prepared -c "${CLIENTS}" -j "${CLIENTS}" \
			-t "${TXNS}" -f "${script}" -d "${DBNAME}" 2>/dev/null || true; } \
			| awk '/tps =/ { print $3; exit }')"
		runs+=("${tps:-0}")
	done
	med="$(printf '%s\n' "${runs[@]}" | median)"
	printf '%-11s %11s   %s\n' "${label}" "${med}" "${runs[*]}" | tee -a "${OUT}"
done

# shellcheck disable=SC2086
${PSQL} -X -q -d "${DBNAME}" -c 'SELECT pgv_free();' >/dev/null 2>&1 || true
echo "pgbench output written to ${OUT}" >&2
