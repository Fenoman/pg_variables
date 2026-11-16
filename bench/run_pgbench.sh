#!/usr/bin/env bash
# Each script is one workload iteration. Explicit transaction boundaries in the
# script determine how many commits it measures. Compare equal-shape iterations
# using latency, with repeated samples to show their spread.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PGB_DIR="${SCRIPT_DIR}/pgbench"
RESULTS_DIR="${RESULTS_DIR:-${SCRIPT_DIR}/results}"
DBNAME="${DBNAME:-pgvbench}"
PSQL="${PSQL:-psql}"
PGBENCH="${PGBENCH:-pgbench}"
TXNS="${TXNS:-200000}"
CLIENTS="${CLIENTS:-1}"
REPEATS="${REPEATS:-5}"
for name in TXNS CLIENTS REPEATS; do
	[[ "${!name}" =~ ^[1-9][0-9]*$ ]] || { echo "$name must be a positive integer" >&2; exit 2; }
done

SCENARIOS=(
	"baseline:baseline.sql"
	"set_reg:set_reg.sql"
	"set_tx:set_tx.sql"
	"baseline_4x:baseline_4x.sql"
	"insert_reg:insert_reg.sql"
	"baseline_tx_block:baseline_tx_block.sql"
	"tx_block:tx_block.sql"
)

mkdir -p "${RESULTS_DIR}"
OUT="$(mktemp "${RESULTS_DIR}/pgbench_$(date +%Y%m%d_%H%M%S)_XXXXXX.out")"
RAW_DIR="${OUT%.out}.raw"
mkdir "$RAW_DIR"
trap 'rc=$?; printf "%s\n" "$rc" > "$RAW_DIR/exit-code"' EXIT

GIT_REV="$(git -C "${SCRIPT_DIR}/.." rev-parse HEAD 2>/dev/null || echo unknown)"
if git -C "${SCRIPT_DIR}/.." status --porcelain --untracked-files=all > "$RAW_DIR/git-status" 2> "$RAW_DIR/git-error"; then
	[[ ! -s "$RAW_DIR/git-status" ]] || GIT_REV="${GIT_REV} (dirty)"
else
	GIT_REV="${GIT_REV} (status unavailable)"
fi
sha256sum "$SCRIPT_DIR/run_pgbench.sh" "$PGB_DIR"/*.sql > "$RAW_DIR/workloads.sha256"
{
	echo "# pg_variables pgbench results"
	echo "# date:       $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	echo "# git:        ${GIT_REV}"
	echo "# dbname:     ${DBNAME}"
	echo "# txns/run:   ${TXNS}  clients: ${CLIENTS}  repeats: ${REPEATS}"
	echo "# raw logs:   ${RAW_DIR}"
} | tee "$OUT"

# PSQL and PGBENCH may contain a command prefix such as sudo -u postgres.
# shellcheck disable=SC2086
if ${PSQL} -X -v ON_ERROR_STOP=1 -q -d "$DBNAME" \
	-c 'CREATE EXTENSION IF NOT EXISTS pg_variables' \
	-c "SELECT version(), extversion FROM pg_extension WHERE extname = 'pg_variables'" \
	> "$RAW_DIR/setup.out" 2> "$RAW_DIR/setup.stderr"; then setup_rc=0; else setup_rc=$?; fi
printf '%s\n' "$setup_rc" > "$RAW_DIR/setup.rc"
cat "$RAW_DIR/setup.out" "$RAW_DIR/setup.stderr" | tee -a "$OUT"
[[ "$setup_rc" == 0 ]] || exit "$setup_rc"

run_sample()
{
	local entry="$1" repeat="$2" transactions="$3" label script prefix rc
	label="${entry%%:*}"
	script="$PGB_DIR/${entry##*:}"
	prefix="$RAW_DIR/${label}.${repeat}"
	# shellcheck disable=SC2086
	if ${PGBENCH} -n -M prepared -c "$CLIENTS" -j "$CLIENTS" \
		-t "$transactions" -f "$script" -d "$DBNAME" > "$prefix.out" 2> "$prefix.stderr"; then rc=0; else rc=$?; fi
	printf '%s\n' "$rc" > "$prefix.rc"
	if [[ "$rc" != 0 ]]; then
		cat "$prefix.stderr" >&2
		echo "Failed pgbench sample: $label/$repeat (rc=$rc). See $prefix.out" >&2
		return "$rc"
	fi
	# A zero exit code does not prove that all requested transactions succeeded.
	if ! awk -v expected="$((transactions * CLIENTS))" '
		/^number of transactions actually processed:/ {
			split($NF, counts, "/"); complete = (counts[1] == expected && counts[2] == expected)
		}
		/^number of failed transactions:/ { errors += $5 }
		/^latency average =/ { latency = $4; latency_lines++ }
		/^tps =/ { tps = $3; tps_lines++ }
		END {
			if (!complete || errors || latency_lines != 1 || tps_lines < 1 ||
				latency !~ /^[0-9]+([.][0-9]+)?$/ || tps !~ /^[0-9]+([.][0-9]+)?$/ ||
				latency <= 0 || tps <= 0) exit 1
			printf "%.6f %.6f\n", latency, tps
		}' "$prefix.out" > "$prefix.metrics"; then
		cat "$prefix.out" "$prefix.stderr" >&2
		echo "Incomplete or invalid pgbench sample: $label/$repeat" >&2
		return 1
	fi
	if [[ "$repeat" != warmup ]]; then
		cat "$prefix.metrics" >> "$RAW_DIR/$label.metrics"
	fi
}

warmup_txns=$((TXNS < 1000 ? TXNS : 1000))
for entry in "${SCENARIOS[@]}"; do run_sample "$entry" warmup "$warmup_txns"; done
# Reverse the sweep on even repeats to reduce systematic order bias.
for ((repeat = 1; repeat <= REPEATS; repeat++)); do
	for ((index = 0; index < ${#SCENARIOS[@]}; index++)); do
		if ((repeat % 2)); then position=$index; else position=$((${#SCENARIOS[@]} - index - 1)); fi
		run_sample "${SCENARIOS[$position]}" "$repeat" "$TXNS"
	done
done

printf '# scenario median_ms min_ms max_ms iqr_ms\n' | tee -a "$OUT"
for entry in "${SCENARIOS[@]}"; do
	label="${entry%%:*}"
	sort -n "$RAW_DIR/$label.metrics" | awk -v label="$label" -v repeats="$REPEATS" '
		function quantile(p, position, lower) {
			position = 1 + (NR - 1) * p; lower = int(position)
			return a[lower] + (position - lower) * (a[lower + 1] - a[lower])
		}
		{ a[NR] = $1 }
		END {
			if (NR != repeats) exit 1
			printf "%-18s %.6f %.6f %.6f %.6f\n", label, quantile(0.5), a[1], a[NR], quantile(0.75) - quantile(0.25)
		}' | tee -a "$OUT"
done
echo "Complete pgbench output: $OUT" >&2
