# FullOn flon-history-tools Deployment

This guide deploys `fill-pg` from flon-history-tools 0.8.0-alpha with PostgreSQL. The provided Compose stack expects an existing FullOn `funod` State History Plugin (SHiP) endpoint; it does not run a blockchain node.

## 1. Configure funod

Enable State History on the node that supplies data to `fill-pg`:

```ini
plugin = eosio::state_history_plugin
trace-history = true
chain-state-history = true
state-history-endpoint = 0.0.0.0:19555
state-history-max-connections = 20
```

`state-history-endpoint` is a WebSocket SHiP endpoint. It is not the HTTP RPC endpoint. Keep this port on a trusted private network; SHiP does not provide application-level authentication.

When `funod` runs on the Docker host, the container can use `host.docker.internal:19555`. On Linux, the Compose file maps that name to the host gateway. The node must listen on an address reachable from the Docker bridge; a service bound only to host loopback may not be reachable.

For complete transaction history, the node must retain trace history from the first block that `fill-pg` needs. Starting from a snapshot does not recreate SHiP data from earlier blocks. Do not prune the required SHiP log range.

## 2. Prepare deployment files

Clone the release and initialize its build dependencies:

```bash
git clone --recursive https://github.com/fullon-labs/flon-history-tools.git
cd flon-history-tools
cp .env.example .env
mkdir -p secrets
openssl rand -base64 32 > secrets/postgres_password
chmod 600 secrets/postgres_password
```

Edit `.env` before starting. At minimum, set:

```dotenv
SHIP_ENDPOINT=host.docker.internal:19555
HISTORY_SCHEMA=flon_testnet
POSTGRES_PASSWORD_FILE=./secrets/postgres_password
```

Use a dedicated database or schema for each chain. Never reconnect an existing schema to a different chain because the current `fill_status` table does not persist and validate the chain ID.

Recommended schema names:

| Network | `HISTORY_SCHEMA` |
| ------- | ---------------- |
| Mainnet | `flon_mainnet` |
| Testnet | `flon_testnet` |

## 3. Start the stack

Build the checked-out source and start PostgreSQL plus `fill-pg`:

```bash
docker compose --env-file .env config
docker compose --env-file .env up -d --build
docker compose --env-file .env ps
docker compose --env-file .env logs -f fill-pg
```

The startup wrapper waits for PostgreSQL and checks the configured schema:

- If the schema does not exist, it starts `fill-pg` once with `--fpg-create`.
- If a valid `fill_status` table exists, it resumes without `--fpg-create`.
- If the schema exists but is not a valid `fill-pg` schema, startup stops without deleting anything.

Routine restarts therefore do not recreate or drop the schema.

If a published image is available and a local build is not desired, set `HISTORY_TOOLS_IMAGE` to that immutable image tag or digest and run:

```bash
docker compose --env-file .env pull
docker compose --env-file .env up -d --no-build
```

## 4. SHiP flow-control settings

The defaults are suitable for normal operation with FullOn Core 0.8.0-alpha:

```dotenv
FILL_MAX_MESSAGES_IN_FLIGHT=1024
FILL_ACK_BATCH_SIZE=256
```

The required relationship is:

```text
1 <= FILL_ACK_BATCH_SIZE <= FILL_MAX_MESSAGES_IN_FLIGHT <= 4096
```

The limit counts messages, not bytes. For a slow PostgreSQL server or memory-constrained host, start with `256` and `64`. Increase the window only after observing database commit latency and container memory.

ACK credits are returned only after the corresponding SHiP result has been processed successfully. A database processing failure therefore cannot acknowledge data that was not committed.

## 5. Full history and trimmed history

For flonscan or any service that needs complete historical transactions, keep:

```dotenv
FILL_TRIM=false
```

Set `FILL_TRIM=true` only when retaining history before the irreversible block is unnecessary. Changing this option to `true` can delete older rows and should be treated as a data-retention decision.

The Compose stack never passes `--fpg-drop`. To rebuild intentionally, take a database backup first and perform the destructive operation manually against the exact schema.

## 6. Mainnet and testnet on one host

Use separate environment files, secrets, Compose project names, and PostgreSQL volumes:

```bash
docker compose -p flon-history-mainnet --env-file .env.mainnet up -d --build
docker compose -p flon-history-testnet --env-file .env.testnet up -d --build
```

Do not run multiple `fill-pg` writers against the same schema.

## 7. Health and synchronization checks

The container health check reads `fill_status.head`. It becomes unhealthy when the head does not advance for `HISTORY_STALE_SECONDS`, which defaults to 90 seconds. This is intentionally longer than FullOn's possible 12-second idle block interval.

Check the stored progress directly:

```bash
docker compose --env-file .env exec fill-pg sh -c '
  export PGPASSWORD="$(cat "$PGPASSWORD_FILE")"
  psql -X -U "$PGUSER" -d "$PGDATABASE" -h "$PGHOST" \
    -c "SELECT head, irreversible, head_id, irreversible_id FROM \"$HISTORY_SCHEMA\".fill_status"
'
```

Compare `head` and `irreversible` with `head_block_num` and `last_irreversible_block_num` from the node's `/v1/chain/get_info` RPC response.

Docker Compose reports an unhealthy container but does not automatically restart it solely because of health status. Connect the health state to monitoring/alerting. `restart: unless-stopped` still handles an actual process exit.

Network-level SHiP failures retry internally. A process can remain alive after some downstream processing failures, so monitoring only the container process is insufficient; alert on synchronization progress as well.

## 8. Persistence, backup, and security

- PostgreSQL data is stored in the named volume `history-postgres-data` scoped by the Compose project name.
- The PostgreSQL port is not published to the host.
- The database password is mounted as a Docker secret and is not stored in `.env`.
- `.env` files and `secrets/` are excluded from Git and the Docker build context.
- Back up PostgreSQL before upgrades, retention changes, or manual schema operations.
- Keep the SHiP port and PostgreSQL network private.

Changing `POSTGRES_USER`, `POSTGRES_DB`, or the password after the PostgreSQL volume has already been initialized does not recreate the database account. Apply credential changes inside PostgreSQL or initialize a new volume deliberately.
