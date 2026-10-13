#!/bin/bash
set -e

echo "========================================"
echo "  Configurando Replicação no Primário"
echo "========================================"

# Cria usuário dedicado para replicação
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${REPLICATION_USER}') THEN
            CREATE USER ${REPLICATION_USER} WITH REPLICATION LOGIN PASSWORD '${REPLICATION_PASSWORD}';
        ELSE
            ALTER USER ${REPLICATION_USER} WITH PASSWORD '${REPLICATION_PASSWORD}';
        END IF;
    END
    \$\$;
EOSQL

echo ">>> Usuário de replicação '${REPLICATION_USER}' configurado."

# Cria slots de replicação persistentes para cada réplica
# Isso evita que o primário remova WALs antes que as réplicas os consumam
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_replication_slots WHERE slot_name = 'replica1_slot') THEN
            PERFORM pg_create_physical_replication_slot('replica1_slot', true);
        END IF;
        IF NOT EXISTS (SELECT FROM pg_replication_slots WHERE slot_name = 'replica2_slot') THEN
            PERFORM pg_create_physical_replication_slot('replica2_slot', true);
        END IF;
    END
    \$\$;
EOSQL

echo ">>> Slots de replicação 'replica1_slot' e 'replica2_slot' criados/verificados."
echo ">>> Primário pronto para aceitar conexões de replicação."
