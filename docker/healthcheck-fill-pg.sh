#!/bin/sh

set -eu

kill -0 1

case "${HISTORY_SCHEMA:-}" in
    ""|[0-9]*|*[!a-z0-9_]*)
        exit 1
        ;;
esac

case "${HISTORY_STALE_SECONDS:-90}" in
    *[!0-9]*|"")
        exit 1
        ;;
esac

export PGPASSWORD="$(cat "${PGPASSWORD_FILE:?}")"
current_head="$(psql -X -v ON_ERROR_STOP=1 -Atqc \
    "SELECT head FROM \"${HISTORY_SCHEMA}\".fill_status LIMIT 1")"

case "$current_head" in
    *[!0-9]*|"")
        exit 1
        ;;
esac

now="$(date +%s)"
state_file=/tmp/fill-pg-health-state

if [ ! -f "$state_file" ]; then
    echo "$current_head $now" > "$state_file"
    exit 0
fi

read -r previous_head last_progress < "$state_file"
if [ "$current_head" != "$previous_head" ]; then
    echo "$current_head $now" > "$state_file"
    exit 0
fi

if [ $((now - last_progress)) -gt "${HISTORY_STALE_SECONDS:-90}" ]; then
    echo "fill-pg head has not advanced from ${current_head} for more than ${HISTORY_STALE_SECONDS:-90} seconds" >&2
    exit 1
fi
