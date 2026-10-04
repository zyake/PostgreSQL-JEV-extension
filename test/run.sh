#!/bin/sh
# Test an installed extension without touching an existing database/service.
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
pg_config=${PG_CONFIG:-pg_config}
pg_bin=$("$pg_config" --bindir)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/jev-test.XXXXXX")
started=false
cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ "$started" = true ]; then
        "$pg_bin/pg_ctl" -D "$test_dir/data" -m immediate -w stop >/dev/null 2>&1 || true
    fi
    if [ "$status" -ne 0 ] || [ "${JEV_KEEP_TEST_DATA:-0}" = 1 ]; then
        printf 'Test files retained in %s\n' "$test_dir"
        [ ! -f "$test_dir/initdb.log" ] || [ -f "$test_dir/server.log" ] || tail -60 "$test_dir/initdb.log"
        [ ! -f "$test_dir/server.log" ] || tail -60 "$test_dir/server.log"
    else
        rm -rf -- "$test_dir"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# Never inherit a user's cluster settings or psql startup file.
unset PGHOST PGPORT PGDATABASE PGUSER PGSERVICE PGSERVICEFILE PGOPTIONS PGDATA
mkdir "$test_dir/socket"
"$pg_bin/initdb" -D "$test_dir/data" -A trust -U jev_test --no-locale -E UTF8 >"$test_dir/initdb.log" 2>&1
cat >>"$test_dir/data/postgresql.conf" <<EOF
listen_addresses = ''
unix_socket_directories = '$test_dir/socket'
port = 65432
fsync = off
max_parallel_workers_per_gather = 0
EOF
started=true
"$pg_bin/pg_ctl" -D "$test_dir/data" -l "$test_dir/server.log" -w start >/dev/null
export PGHOST="$test_dir/socket" PGPORT=65432 PGUSER=jev_test PGDATABASE=postgres
"$pg_bin/psql" -X -v ON_ERROR_STOP=1 -f "$task_root/test/sql/upgrade.sql"
"$pg_bin/psql" -X -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION jev;'
if [ "$#" -eq 0 ]; then
    set -- kernel planner batching cache cascade relation reduction join_tree costing auto_batch switches
fi
for suite do
    printf '\nRunning %s assertions\n' "$suite"
    "$pg_bin/psql" -X -v ON_ERROR_STOP=1 -f "$task_root/test/sql/$suite.sql"
done
if [ "${JEV_TEST_SQL_PROVIDER:-0}" = 1 ]; then
    # Optional: requires plpython3u; starts only fake local HTTP services.
    python3 -m unittest discover -s "$task_root/test" -p 'provider*.py'
fi
"$pg_bin/psql" -X -v ON_ERROR_STOP=1 -c 'DROP EXTENSION jev CASCADE; CREATE EXTENSION jev; DROP EXTENSION jev;'
printf '\nAll JEV tests passed (%s).\n' "$("$pg_config" --version)"
