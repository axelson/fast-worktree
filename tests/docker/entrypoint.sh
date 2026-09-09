#!/bin/sh
# Container entrypoint for the fast-worktree test image. Brings up PostgreSQL
# the way the suite expects (a local cluster reachable over the unix socket with
# the container user as a bare-libpq superuser — peer auth, no host/user/pass),
# then execs whatever command was requested. Mirrors the Postgres setup in
# .github/workflows/ci.yml so containerized and native CI behave the same.
set -e

start_postgres() {
    command -v pg_ctlcluster >/dev/null 2>&1 || return 0

    if ! service postgresql start >/dev/null 2>&1; then
        # Fallback: start the first installed cluster directly. Glob rather than
        # ls (the version dir is numeric, so ordering is fine either way).
        for d in /etc/postgresql/*/; do
            pg_ctlcluster "$(basename "$d")" main start >/dev/null 2>&1 || true
            break
        done
    fi

    # Wait for the socket before touching roles.
    i=0
    until pg_isready >/dev/null 2>&1; do
        i=$((i + 1))
        [ "$i" -ge 30 ] && break
        sleep 1
    done

    # Give the container's OS user a superuser role + matching database, so the
    # suite's bare createdb/dropdb/psql calls resolve with no extra arguments.
    dbuser="$(id -un)"
    su postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='$dbuser'\"" 2>/dev/null | grep -q 1 \
        || su postgres -c "psql -c \"CREATE ROLE \\\"$dbuser\\\" LOGIN SUPERUSER CREATEDB\"" >/dev/null 2>&1 \
        || true
    su postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='$dbuser'\"" 2>/dev/null | grep -q 1 \
        || su postgres -c "createdb \"$dbuser\"" >/dev/null 2>&1 \
        || true
}

start_postgres
exec "$@"
