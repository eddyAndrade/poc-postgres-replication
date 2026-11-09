# PostgreSQL Streaming Replication with Docker Compose

This project provisions a PostgreSQL cluster with **1 primary (master)** and **2 hot standby replicas** using Docker Compose, following production best practices.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                  Docker Network (Bridge)                    │
│                     (postgres-replica)                      │
│                                                             │
│   ┌─────────────────┐                                       │
│   │ postgres-primary│  ← Writes + Reads                     │
│   └────────┬────────┘                                       │
│            │ Streaming Replication (WAL)                     │
│            ├──────────────────────┐                         │
│            │                      │                         │
│   ┌────────▼────────┐    ┌───────▼────────┐               │
│   │ postgres-replica1│    │postgres-replica2│               │
│   │   Hot Standby    │    │   Hot Standby    │               │
│   │   Read Only      │    │   Read Only      │               │
│   └──────────────────┘    └──────────────────┘               │
└─────────────────────────────────────────────────────────────┘
```

### Features

- **Streaming Replication**: Replicas receive WAL (Write-Ahead Logs) from the primary in real time.
- **Hot Standby**: Replicas accept read queries (`SELECT`) concurrently with replication.
- **Synchronous Replication**: Configured with `synchronous_commit = remote_apply` and `FIRST 1`, ensuring at least one replica applies the transaction before the primary confirms to the client (maximum durability without entirely sacrificing performance).
- **Replication Slots**: Persistent physical slots (`replica1_slot`, `replica2_slot`) prevent the primary from removing WAL files before the replicas consume them, avoiding desync in case of a slow or offline replica.
- **Automatic Bootstrap**: Replicas use `pg_basebackup` to clone the primary automatically on first run.
- **Health Checks**: All containers have health checks (`pg_isready`).
- **Security**: `scram-sha-256` authentication, isolated network, dedicated replication user.

---

## Project Structure

```
.
├── .env.example                      # Environment variables (template)
├── .gitignore                        # Ignores .env and local data
├── docker-compose.yml                # Service orchestration
├── README.md                         # This file
├── config/
│   └── replica/
│       └── postgresql.conf           # Replica configuration
└── scripts/
    ├── primary/
    │   ├── 01-init-replication.sh    # Creates replication user and slots
    │   └── 99-configure-replication.sh # Configures postgresql.conf and pg_hba.conf
    └── replica/
        └── entrypoint.sh             # Custom entrypoint (pg_basebackup)
```

---

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) 20.10+
- [Docker Compose](https://docs.docker.com/compose/install/) 2.20+ (`depends_on` with `condition` support)

---

## Quick Start

### 1. Clone or copy the project

```bash
cd postgre-replica
```

### 2. Configure environment variables

```bash
cp .env.example .env
```

Edit the `.env` file and change the default passwords:

```dotenv
POSTGRES_PASSWORD=YourSecurePasswordHere123!
REPLICATION_PASSWORD=YourSecureReplicationPassword456!
```

> ⚠️ **Never commit the `.env` file to Git.** It is already listed in `.gitignore`.

### 3. Start the cluster

```bash
docker compose up -d
```

Docker Compose will:
1. Create the `postgres-replica` network.
2. Start `postgres-primary`, create the database, the replication user, and the slots.
3. Wait for the primary to become healthy.
4. Start `postgres-replica1` and `postgres-replica2`, running `pg_basebackup` to clone the data.

### 4. Check the status

```bash
# Container status
docker compose ps

# Primary logs
docker compose logs -f postgres-primary

# Replica logs
docker compose logs -f postgres-replica1
docker compose logs -f postgres-replica2
```

---

## Replication Validation

### Connect to the primary

```bash
docker exec -i postgres-primary psql -U postgres -d app_database
```

Create a test table:

```sql
CREATE TABLE test_replication (id SERIAL PRIMARY KEY, message TEXT, created_at TIMESTAMP DEFAULT NOW());
INSERT INTO test_replication (message) VALUES ('Hello from Primary!');
```

### Connect to a replica

```bash
docker exec -i postgres-replica1 psql -U postgres -d app_database
```

Verify the data was replicated:

```sql
SELECT * FROM test_replication;
```

> The replica is in hot standby, so write commands (`INSERT`, `UPDATE`, `DELETE`, `CREATE`) will be rejected. This is expected.

### Check replication status on the primary

```bash
docker exec -i postgres-primary psql -U postgres -c "
SELECT 
    client_addr,
    state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    sync_state
FROM pg_stat_replication;
"
```

Expected output (similar to):

```
  client_addr  |   state   | sent_lsn  | write_lsn | flush_lsn | replay_lsn | sync_state
---------------+-----------+-----------+-----------+-----------+------------+------------
 172.23.0.4    | streaming | 0/4000060 | 0/4000060 | 0/4000060 | 0/4000060  | sync
 172.23.0.3    | streaming | 0/4000060 | 0/4000060 | 0/4000060 | 0/4000060  | potential
```

- **`sync`**: Current synchronous replica (confirms transactions).
- **`potential`**: Asynchronous replica (ready to become synchronous if the other one fails).
- **`streaming`**: WAL is being streamed in real time.

### Check replication slots

```bash
docker exec -i postgres-primary psql -U postgres -c "
SELECT slot_name, plugin, slot_type, active, restart_lsn 
FROM pg_replication_slots;
"
```

---

## Ports and Access

| Service             | Host Port | Container Port |
|---------------------|-----------|----------------|
| postgres-primary    | 5432      | 5432           |
| postgres-replica1   | 5433      | 5432           |
| postgres-replica2   | 5434      | 5432           |

### Connection example via psql (from the host)

```bash
# Primary (read and write)
psql -h localhost -p 5432 -U postgres -d app_database

# Replica 1 (read only)
psql -h localhost -p 5433 -U postgres -d app_database

# Replica 2 (read only)
psql -h localhost -p 5434 -U postgres -d app_database
```

---

## Best Practices Applied

1. **Passwords in `.env`**: Credentials are not hardcoded in `docker-compose.yml`.
2. **Dedicated user**: `replicator` has only the `REPLICATION` privilege, minimizing the impact of leaked credentials.
3. **Isolated network**: Dedicated bridge network (`postgres-replica`) isolating cluster traffic.
4. **Strong authentication**: `scram-sha-256` instead of `md5` or `trust`.
5. **Replication Slots**: Ensure the primary retains WAL needed for slow or temporarily offline replicas.
6. **Configurable synchronization**: `FIRST 1` allows the primary to keep operating even if one replica goes down, maintaining durability with the remaining replica.
7. **Hot Standby Feedback**: `hot_standby_feedback = on` prevents the primary's autovacuum from removing tuples still needed by long-running queries on the replicas.
8. **Health Checks**: Ensure replicas only start after the primary is ready.
9. **Named volumes**: Data persists across container restarts (`primary_data`, `replica1_data`, `replica2_data`).
10. **Restart Policy**: `unless-stopped` ensures services automatically recover after failures (except manual stops).

---

## Maintenance and Operations

### Restart the cluster

```bash
docker compose restart
```

### Stop the cluster

```bash
docker compose down
```

> Volumes persist. When starting again (`docker compose up -d`), data will be preserved.

### Destroy everything (including data!)

```bash
docker compose down -v
```

> **Warning:** This removes the `primary_data`, `replica1_data`, and `replica2_data` volumes. All data will be lost.

### Force resync of a replica

If a replica becomes desynchronized or corrupted:

```bash
# 1. Stop the replica
docker compose stop postgres-replica1

# 2. Remove the volume
docker volume rm postgre-replica_replica1_data

# 3. Recreate and restart
docker compose up -d postgres-replica1
```

The replica will run `pg_basebackup` again and reconnect to the primary.

### Promote a replica to primary (Manual Failover)

In case of primary failure, you can promote a replica:

```bash
# Stop the primary (if still running)
docker compose stop postgres-primary

# Promote replica 1
docker exec postgres-replica1 pg_ctl promote -D /var/lib/postgresql/data/pgdata
```

> **Note:** This setup does not implement automatic failover. For automatic high availability, consider tools like [Patroni](https://github.com/zalando/patroni), [Repmgr](https://repmgr.org/), or [PgBouncer](https://www.pgbouncer.org/) with a connection proxy.

---

## Troubleshooting

### Replica does not connect to the primary

```bash
docker compose logs postgres-replica1
```

Check:
- Whether the primary is healthy: `docker compose ps`
- Whether the credentials in `.env` are consistent
- Whether the Docker network is working: `docker network inspect postgre-replica_postgres-replica`

### `pg_basebackup` fails with "password authentication failed"

Make sure `.env` was created **before** the first `docker compose up`. If you change passwords after the volumes are created, destroy the volumes (`docker compose down -v`) and start again.

### Replica stays in `catchup` for a long time

This is normal under heavy write load. `wal_keep_size = 256MB` helps, but in high-load environments, increase this value or set up a WAL archive on shared storage.

---

## References

- [PostgreSQL Documentation - Streaming Replication](https://www.postgresql.org/docs/current/warm-standby.html#STREAMING-REPLICATION)
- [PostgreSQL Documentation - Synchronous Replication](https://www.postgresql.org/docs/current/synchronous-replication.html)
- [PostgreSQL Documentation - Replication Slots](https://www.postgresql.org/docs/current/warm-standby.html#STREAMING-REPLICATION-SLOTS)
- [Docker Hub - Official PostgreSQL Image](https://hub.docker.com/_/postgres)

---

## License

This template is open-source. Adapt it to your project's needs.
