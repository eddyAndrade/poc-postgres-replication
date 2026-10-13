#!/bin/bash
set -e

echo "========================================"
echo "  Configurando arquivos do PostgreSQL"
echo "========================================"

# Garante diretório de archive
mkdir -p /var/lib/postgresql/data/archive

echo ">>> Aplicando configurações de replicação em postgresql.conf..."
cat >> "$PGDATA/postgresql.conf" <<'EOF'

# ============================================================
# Streaming Replication Configuration (injected by init script)
# ============================================================
wal_level = replica
wal_log_hints = on
max_wal_senders = 10
max_replication_slots = 10
wal_keep_size = 256MB
hot_standby = on
hot_standby_feedback = on
archive_mode = on
archive_command = 'test ! -f /var/lib/postgresql/data/archive/%f && cp %p /var/lib/postgresql/data/archive/%f || true'
archive_timeout = 600
synchronous_commit = remote_apply
synchronous_standby_names = 'FIRST 1 ("postgres-replica1", "postgres-replica2")'
EOF

echo ">>> Aplicando regras de autenticação em pg_hba.conf..."
cat >> "$PGDATA/pg_hba.conf" <<'EOF'

# Docker replication network
host    replication     all             172.16.0.0/12           scram-sha-256
host    all             all             172.16.0.0/12           scram-sha-256
EOF

echo ">>> Configurações aplicadas com sucesso."
