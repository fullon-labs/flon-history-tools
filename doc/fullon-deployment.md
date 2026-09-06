# FullOn flon-history-tools Deployment

This guide deploys `fill-pg` from flon-history-tools 0.8.1 with PostgreSQL. The provided Compose stack expects an existing FullOn `funod` State History Plugin (SHiP) endpoint; it does not run a blockchain node.

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

## 2. Configure fill-pg

`fill-pg` uses the standard PostgreSQL/libpq environment variables. For a native process, configure them before starting:

```bash
export PGHOST=postgres
export PGPORT=5432
export PGDATABASE=flon_history
export PGUSER=flon_history
export PGPASSWORD='replace-with-the-real-password'
export PGCONNECT_TIMEOUT=5
```

In Compose, `PGPASSWORD` is intentionally replaced by `PGPASSWORD_FILE` and a Docker secret. Do not commit a plaintext password to `.env` or `config.ini`.

The native `fill-pg` configuration for a testnet deployment is:

```ini
fill-connect-to = funod-testnet:19555
fill-max-messages-in-flight = 1024
fill-ack-batch-size = 256
pg-schema = flon_testnet
```

`fill-connect-to` must point to the `funod` SHiP port. It must not point to the HTTP RPC port. The hostname `funod-testnet` works only when it is resolvable and reachable from the `fill-pg` container, such as when both services share a Docker network. When `funod` runs directly on the Docker host, use `host.docker.internal:19555` instead.

The Compose environment variables map to the native options as follows:

| Compose variable | Native `fill-pg` option | Default/example |
| ---------------- | ----------------------- | --------------- |
| `SHIP_ENDPOINT` | `fill-connect-to` | `funod-testnet:19555` |
| `FILL_MAX_MESSAGES_IN_FLIGHT` | `fill-max-messages-in-flight` | `1024` |
| `FILL_ACK_BATCH_SIZE` | `fill-ack-batch-size` | `256` |
| `HISTORY_SCHEMA` | `pg-schema` | `flon_testnet` |

For a native deployment, start in this order:

1. Start PostgreSQL and verify that the target database and user exist.
2. Start `funod` and verify that its SHiP port is reachable.
3. Start `fill-pg` with `--fpg-create` only when the schema does not exist.
4. On every routine restart, start without `--fpg-create`.

First start for a new schema:

```bash
fill-pg \
  --fpg-create \
  --fill-connect-to=funod-testnet:19555 \
  --fill-max-messages-in-flight=1024 \
  --fill-ack-batch-size=256 \
  --pg-schema=flon_testnet
```

Routine restart for an existing schema:

```bash
fill-pg \
  --fill-connect-to=funod-testnet:19555 \
  --fill-max-messages-in-flight=1024 \
  --fill-ack-batch-size=256 \
  --pg-schema=flon_testnet
```

The provided Compose startup wrapper performs the new-schema check automatically. It never passes `--fpg-drop`.

### Optional fill-pg arguments

| Argument | Purpose | Production guidance |
| -------- | ------- | ------------------- |
| `--fpg-create` | Create the configured schema and tables | First start only |
| `--fpg-drop` | Drop the entire configured schema | Destructive; never include in a routine startup command |
| `--fill-trim` | Delete history before the irreversible range as filling proceeds | Keep disabled for flonscan and full-history services |
| `--fill-skip-to N` | Start at block `N` | Initial partial-history setup only; creates an intentional history gap |
| `--fill-stop N` | Stop requesting data before block `N` | Controlled backfill or diagnostics only |
| `--fill-trx` | Filter transaction traces | Omit to include all transactions; filters can make flonscan history incomplete |
| `--fill-table` | Exclude selected state-history tables | Omit unless every downstream data requirement is understood |

For a complete flonscan database, do not set `--fill-trim`, `--fill-skip-to`, `--fill-trx`, or `--fill-table` unless the resulting data loss is deliberate.

## 3. Prepare deployment files

Clone the repository and initialize its build dependencies:

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

## 4. Start the stack

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

Routine lifecycle commands:

```bash
# Restart only the filler; PostgreSQL remains online
docker compose --env-file .env restart fill-pg

# Stop and resume the filler without recreating the database
docker compose --env-file .env stop fill-pg
docker compose --env-file .env start fill-pg

# Stop the stack while preserving the named PostgreSQL volume
docker compose --env-file .env down
```

Do not add `--volumes` to `docker compose down` unless deletion of the PostgreSQL data volume has been explicitly confirmed.

## 5. SHiP flow-control settings

The defaults are suitable for normal operation with FullOn Core 0.8.1:

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

## 6. Full history and trimmed history

For flonscan or any service that needs complete historical transactions, keep:

```dotenv
FILL_TRIM=false
```

Set `FILL_TRIM=true` only when retaining history before the irreversible block is unnecessary. Changing this option to `true` can delete older rows and should be treated as a data-retention decision.

The Compose stack never passes `--fpg-drop`. To rebuild intentionally, take a database backup first and perform the destructive operation manually against the exact schema.

## 7. Mainnet and testnet on one host

Use separate environment files, secrets, Compose project names, and PostgreSQL volumes:

```dotenv
# .env.mainnet
# Replace this example with the actual mainnet SHiP endpoint.
SHIP_ENDPOINT=funod-mainnet:8080
HISTORY_SCHEMA=flon_mainnet
POSTGRES_PASSWORD_FILE=./secrets/mainnet_postgres_password
FILL_MAX_MESSAGES_IN_FLIGHT=1024
FILL_ACK_BATCH_SIZE=256
FILL_TRIM=false
```

```dotenv
# .env.testnet
SHIP_ENDPOINT=host.docker.internal:19555
HISTORY_SCHEMA=flon_testnet
POSTGRES_PASSWORD_FILE=./secrets/testnet_postgres_password
FILL_MAX_MESSAGES_IN_FLIGHT=1024
FILL_ACK_BATCH_SIZE=256
FILL_TRIM=false
```

Create both secret files before starting. Then use distinct Compose project names:

```bash
docker compose -p flon-history-mainnet --env-file .env.mainnet up -d --build
docker compose -p flon-history-testnet --env-file .env.testnet up -d --build
```

Do not run multiple `fill-pg` writers against the same schema.

## 8. Upgrade to 0.8.1

The SHiP flow-control update does not change the PostgreSQL schema. An existing 0.5.0 or 0.8.0-alpha database can resume with 0.8.1 without dropping or rebuilding the schema.

Recommended upgrade workflow:

1. Record the current `fill_status` row and take a PostgreSQL backup.
2. Stop the old `fill-pg` process while leaving PostgreSQL and `funod` running.
3. Pull or build flon-history-tools 0.8.1.
4. Set the in-flight window to at most 4096; the recommended values are 1024 and 256.
5. Start 0.8.1 against the same database and schema without `--fpg-create` and without `--fpg-drop`.
6. Confirm that `fill_status.head` continues from its previous value and catches up with the node.

Example backup before upgrading a Compose testnet deployment:

```bash
docker compose --env-file .env exec -T postgres \
  pg_dump -U flon_history -d flon_history -n flon_testnet \
  > flon_testnet_before_0.8.1.sql
```

If rollback is required, stop the new filler and restart the previous binary against the unchanged schema. Do not run old and new writers simultaneously.

## 9. Health and synchronization checks

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

## 10. Persistence, backup, and security

- PostgreSQL data is stored in the named volume `history-postgres-data` scoped by the Compose project name.
- The PostgreSQL port is not published to the host.
- The database password is mounted as a Docker secret and is not stored in `.env`.
- `.env` files and `secrets/` are excluded from Git and the Docker build context.
- Back up PostgreSQL before upgrades, retention changes, or manual schema operations.
- Keep the SHiP port and PostgreSQL network private.

Changing `POSTGRES_USER`, `POSTGRES_DB`, or the password after the PostgreSQL volume has already been initialized does not recreate the database account. Apply credential changes inside PostgreSQL or initialize a new volume deliberately.

## 11. Troubleshooting

| Symptom | Likely cause | Check or action |
| ------- | ------------ | --------------- |
| `max_messages_in_flight exceeds the server limit` | Old client or a configured window above 4096 | Use flon-history-tools 0.8.1 and set the window to 4096 or less |
| Connection refused on `fill-connect-to` | RPC port used instead of SHiP, wrong bind address, DNS, or firewall | Verify `state-history-endpoint`, container DNS, and private-network reachability |
| Schema already exists during startup | `--fpg-create` was used on a routine restart | Remove `--fpg-create`; the Compose wrapper handles this automatically |
| Schema exists but is not a valid fill-pg schema | Wrong `HISTORY_SCHEMA` or an unrelated/incomplete schema | Select the correct schema; do not drop it automatically |
| Database starts at a recent block and older history is absent | Node was started from a snapshot or old SHiP files were pruned | Restore full SHiP logs or replay from block log to regenerate the required range |
| Container is running but unhealthy | `fill_status.head` is stale, PostgreSQL failed, or the source node stopped advancing | Check filler logs, query `fill_status`, and compare it with `/v1/chain/get_info` |
| PostgreSQL authentication fails after editing `.env` | Existing volume retains the original database credentials | Update the PostgreSQL role explicitly or deliberately initialize a new volume |

## 12. Production checklist

Before declaring the service ready, verify all of the following:

- `funod` 0.8.1 has `trace-history` enabled; enable `chain-state-history` when state-table history is required.
- `SHIP_ENDPOINT` resolves from inside the filler container and points to SHiP, not RPC.
- Mainnet and testnet use different Compose project names, secrets, volumes, and schemas.
- PostgreSQL data and password files are backed up and not committed to Git.
- `FILL_ACK_BATCH_SIZE` is not greater than `FILL_MAX_MESSAGES_IN_FLIGHT`, and the in-flight value is at most 4096.
- `FILL_TRIM=false` for flonscan and other complete-history consumers.
- Routine startup contains neither `--fpg-create` nor `--fpg-drop` when running natively.
- `fill_status.head` and `fill_status.irreversible` advance and remain acceptably close to the node values.
- Monitoring allows for the possible 12-second idle block interval and alerts on sustained 60–90 second stalls.
