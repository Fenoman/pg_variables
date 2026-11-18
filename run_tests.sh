#!/usr/bin/env bash

# Copyright (c) 2018-2022, Postgres Professional
# Supported levels: standard, scan-build, hardcore, nightmare.

set -euo pipefail
umask 077

LEVEL="${LEVEL:-standard}"
case "$LEVEL" in
	standard|scan-build|hardcore|nightmare) ;;
	*) echo "Unknown test level: $LEVEL" >&2; exit 2 ;;
esac

: "${PGDATA:?PGDATA must name an empty disposable data directory}"
if [[ -L "$PGDATA" || ( -e "$PGDATA" && ! -d "$PGDATA" ) ]] ||
	[[ -d "$PGDATA" && -n "$(find "$PGDATA" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
	echo "Refusing to initialize nonempty or unsafe PGDATA: $PGDATA" >&2
	exit 2
fi

SOURCE_DIR="$PWD"
mkdir -p "${TEST_RESULTS_DIR:-${TMPDIR:-/tmp}}"
RUN_DIR="$(mktemp -d "${TEST_RESULTS_DIR:-${TMPDIR:-/tmp}}/pgv_${LEVEL}.XXXXXX")"
RUN_DIR="$(cd "$RUN_DIR" && pwd)"
echo "Test logs: $RUN_DIR"
cluster_start_attempted=0
installcheck_started=0
server_pid=""
socket_dir=""

run_logged()
{
	local label="$1" rc
	shift
	printf '%q ' "$@" >> "$RUN_DIR/commands.log"
	printf '\n' >> "$RUN_DIR/commands.log"
	if "$@" > "$RUN_DIR/$label.log" 2>&1; then rc=0; else rc=$?; fi
	printf '%s rc=%s\n' "$label" "$rc" >> "$RUN_DIR/commands.log"
	cat "$RUN_DIR/$label.log"
	return "$rc"
}

finish()
{
	local rc=$? stop_rc=0 status_rc=3 log
	trap - EXIT
	set +e
	if [[ "$cluster_start_attempted" == 1 ]]; then
		pg_ctl -D "$PGDATA" status > "$RUN_DIR/status.log" 2>&1
		status_rc=$?
		stop_rc=$status_rc
		if [[ "$status_rc" == 0 ]]; then
			run_logged stop pg_ctl -D "$PGDATA" -m fast -w stop
			stop_rc=$?
		elif [[ "$stop_rc" == 3 ]]; then
			stop_rc=0
		fi
		if [[ -n "$server_pid" ]]; then
			# A failed startup may leave the owned Valgrind process without a pidfile.
			if [[ "$stop_rc" != 0 || "$status_rc" != 0 ]]; then
				kill -TERM "$server_pid" 2>/dev/null
			fi
			if ! wait "$server_pid"; then rc=1; fi
		fi
		if [[ "$stop_rc" != 0 ]]; then rc=1; fi
	fi
	if [[ -n "$socket_dir" && "$stop_rc" == 0 ]]; then
		rmdir "$socket_dir" || rc=1
	fi
	if [[ "$LEVEL" == nightmare && "$cluster_start_attempted" == 1 ]]; then
		shopt -s nullglob
		local logs=("$RUN_DIR"/valgrind-*.log)
		if [[ "${#logs[@]}" == 0 ]]; then
			echo "No Valgrind reports were produced" >&2
			rc=1
		fi
		for log in "${logs[@]}"; do
			if ! grep -q 'ERROR SUMMARY:' "$log" ||
				grep -Eq 'ERROR SUMMARY: [1-9]' "$log"; then
				cat "$log"
				rc=1
			fi
		done
	fi
	if [[ "$installcheck_started" == 1 ]]; then
		for log in regression.out regression.diffs; do
			if [[ -f "$SOURCE_DIR/$log" ]]; then cp "$SOURCE_DIR/$log" "$RUN_DIR/" || rc=1; fi
		done
		if [[ "$rc" != 0 && -f "$SOURCE_DIR/regression.diffs" ]]; then
			cat "$SOURCE_DIR/regression.diffs"
		fi
		if [[ -d "$SOURCE_DIR/results" ]]; then
			mkdir -p "$RUN_DIR/regression-results" || rc=1
			for log in "$SOURCE_DIR"/results/*.out; do
				if [[ -f "$log" ]]; then cp "$log" "$RUN_DIR/regression-results/" || rc=1; fi
			done
		fi
	fi
	printf '%s\n' "$rc" > "$RUN_DIR/exit-code" || rc=1
	echo "Test exit code: $rc. Logs: $RUN_DIR"
	exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

{
	date -u '+%Y-%m-%dT%H:%M:%SZ'
	printf 'level=%s\nsource=%s\n' "$LEVEL" "$SOURCE_DIR"
	if git rev-parse HEAD; then
		git status --short --untracked-files=all
		git diff HEAD --binary > "$RUN_DIR/source.patch"
	fi
} > "$RUN_DIR/source.log" 2>&1

if [[ "$LEVEL" == hardcore || "$LEVEL" == nightmare ]]; then
	: "${PG_VERSION:?PG_VERSION is required for a source build}"
	: "${PG_SHA256:?PG_SHA256 is required for a source build}"
	CUSTOM_PG_BIN="$RUN_DIR/pg_bin"
	CUSTOM_PG_SRC="$RUN_DIR/postgresql"
	run_logged download curl -fSL "https://ftp.postgresql.org/pub/source/v$PG_VERSION/postgresql-$PG_VERSION.tar.bz2" -o "$RUN_DIR/postgresql.tar.bz2"
	printf '%s  %s\n' "$PG_SHA256" "$RUN_DIR/postgresql.tar.bz2" | sha256sum -c -
	mkdir "$CUSTOM_PG_SRC"
	run_logged extract tar --extract --file "$RUN_DIR/postgresql.tar.bz2" --directory "$CUSTOM_PG_SRC" --strip-components 1
	cd "$CUSTOM_PG_SRC"
	sed -i.bak 's@/\* #define USE_VALGRIND \*/@#define USE_VALGRIND@' src/include/pg_config_manual.h
	run_logged configure ./configure CFLAGS='-O0 -ggdb3 -fno-omit-frame-pointer' --enable-cassert --enable-debug --prefix="$CUSTOM_PG_BIN" --quiet
	run_logged postgres-build make -s -j"$(nproc)"
	run_logged postgres-install make -s install
	export PATH="$CUSTOM_PG_BIN/bin:$PATH"
	export LD_LIBRARY_PATH="$CUSTOM_PG_BIN/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	cd "$SOURCE_DIR"
fi

run_logged pg-config pg_config
run_logged clean make USE_PGXS=1 clean
if [[ "$LEVEL" != standard ]]; then
	run_logged scan-build scan-build --status-bugs make USE_PGXS=1
	run_logged scan-clean make USE_PGXS=1 clean
fi
run_logged build make USE_PGXS=1 PG_CPPFLAGS=-coverage SHLIB_LINK=-coverage
run_logged install make USE_PGXS=1 PG_CPPFLAGS=-coverage SHLIB_LINK=-coverage install
run_logged initdb initdb --locale=C --encoding=UTF8 -D "$PGDATA"

export PGPORT="${PGPORT:-55435}"
socket_dir="$(mktemp -d "${TMPDIR:-/tmp}/pgv-socket.XXXXXX")"
export PGHOST="$socket_dir"
unset PGHOSTADDR PGSERVICE PGSERVICEFILE
printf 'PGDATA=%s\nPGHOST=%s\nPGPORT=%s\n' "$PGDATA" "$PGHOST" "$PGPORT" > "$RUN_DIR/cluster.log"
printf "port = %s\nlisten_addresses = ''\nunix_socket_directories = '%s'\n" "$PGPORT" "${PGHOST//\'/\'\'}" >> "$PGDATA/postgresql.conf"

cluster_start_attempted=1
if [[ "$LEVEL" == nightmare ]]; then
	valgrind --tool=memcheck --leak-check=no \
		--error-exitcode=1 --time-stamp=yes --track-origins=yes \
		--gen-suppressions=all --suppressions="$CUSTOM_PG_SRC/src/tools/valgrind.supp" \
		--suppressions="$SOURCE_DIR/valgrind.supp" --log-file="$RUN_DIR/valgrind-%p.log" \
		postgres -D "$PGDATA" > "$RUN_DIR/postgres.log" 2>&1 &
	server_pid=$!
	ready=0
	for ((attempt = 0; attempt < 120; attempt++)); do
		if pg_isready -q; then ready=1; break; fi
		kill -0 "$server_pid"
		sleep 1
	done
	[[ "$ready" == 1 ]] || { echo "PostgreSQL startup timed out" >&2; exit 1; }
else
	run_logged start pg_ctl -D "$PGDATA" start -l "$RUN_DIR/postgres.log" -w
fi

export PG_REGRESS_DIFF_OPTS="-w -U3"
rm -f "$SOURCE_DIR/regression.diffs" "$SOURCE_DIR/regression.out"
installcheck_started=1
run_logged installcheck make USE_PGXS=1 installcheck
run_logged gcov gcov pg_variables.c pg_variables_record.c
