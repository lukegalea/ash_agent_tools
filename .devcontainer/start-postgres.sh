#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

# Start PostgreSQL for the :db-tagged tests, the same shape as CI's
# postgres:16 service: localhost:5432, user postgres, trust auth, UTC.
# Idempotent: initialises the cluster once, does nothing if it is running.
# `SKIP_DB=1 mix test` runs the suite without it.
set -euo pipefail

export PGDATA="${PGDATA:-$HOME/.devenv/state/postgres}"

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  mkdir -p "$PGDATA"
  initdb --username=postgres --auth=trust --encoding=UTF8 --no-locale \
    --pgdata="$PGDATA" > "$PGDATA.initdb.log"
fi

if pg_ctl status > /dev/null 2>&1; then
  echo "start-postgres: already running ($PGDATA)"
  exit 0
fi

pg_ctl start --wait --log="$PGDATA/server.log" \
  -o "-c listen_addresses=localhost -c port=5432 -c unix_socket_directories=$PGDATA -c timezone=UTC"
