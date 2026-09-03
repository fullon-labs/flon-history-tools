#!/bin/sh

set -eu

: "${PGHOST:?PGHOST is required}"
: "${PGDATABASE:?PGDATABASE is required}"
: "${PGUSER:?PGUSER is required}"
: "${PGPASSWORD_FILE:?PGPASSWORD_FILE is required}"
: "${SHIP_ENDPOINT:?SHIP_ENDPOINT is required}"
: "${HISTORY_SCHEMA:?HISTORY_SCHEMA is required}"

case "$HISTORY_SCHEMA" in
    ""|[0-9]*|*[!a-z0-9_]*)
        echo "HISTORY_SCHEMA must start with a lowercase letter or underscore and contain only lowercase letters, digits, and underscores" >&2
        exit 2
        ;;
esac

case "${FILL_MAX_MESSAGES_IN_FLIGHT:-1024}" in
    *[!0-9]*|"")
        echo "FILL_MAX_MESSAGES_IN_FLIGHT must be an integer" >&2
        exit 2
        ;;
esac

case "${FILL_ACK_BATCH_SIZE:-256}" in
    *[!0-9]*|"")
        echo "FILL_ACK_BATCH_SIZE must be an integer" >&2
        exit 2
        ;;
esac

export PGPASSWORD="$(cat "$PGPASSWORD_FILE")"

until pg_isready -q -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE"; do
    echo "waiting for PostgreSQL at ${PGHOST}:${PGPORT:-5432}" >&2
    sleep 2
done

schema_exists="$(psql -X -v ON_ERROR_STOP=1 -Atqc \
    "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = '${HISTORY_SCHEMA}') THEN 1 ELSE 0 END")"

set -- fill-pg \
    "--fill-connect-to=${SHIP_ENDPOINT}" \
    "--pg-schema=${HISTORY_SCHEMA}" \
    "--fill-max-messages-in-flight=${FILL_MAX_MESSAGES_IN_FLIGHT:-1024}" \
    "--fill-ack-batch-size=${FILL_ACK_BATCH_SIZE:-256}"

if [ "$schema_exists" = "0" ]; then
    echo "initializing PostgreSQL schema ${HISTORY_SCHEMA}" >&2
    set -- "$@" --fpg-create
else
    fill_status_exists="$(psql -X -v ON_ERROR_STOP=1 -Atqc \
        "SELECT CASE WHEN EXISTS (
             SELECT 1
             FROM pg_class c
             JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = '${HISTORY_SCHEMA}' AND c.relname = 'fill_status'
         ) THEN 1 ELSE 0 END")"
    if [ "$fill_status_exists" != "1" ]; then
        echo "schema ${HISTORY_SCHEMA} exists but is not a valid fill-pg schema" >&2
        exit 2
    fi
    echo "resuming PostgreSQL schema ${HISTORY_SCHEMA}" >&2
fi

case "${FILL_TRIM:-false}" in
    true)
        set -- "$@" --fill-trim
        ;;
    false)
        ;;
    *)
        echo "FILL_TRIM must be true or false" >&2
        exit 2
        ;;
esac

exec "$@"
