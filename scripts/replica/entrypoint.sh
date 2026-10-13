#!/bin/bash
set -e

echo "========================================"
echo "  Entrypoint da Réplica"
echo "  Hostname: $(hostname)"
echo "========================================"

# Verifica se o diretório de dados já foi inicializado
if [ -s "$PGDATA/PG_VERSION" ]; then
    echo ">>> Dados já existem em $PGDATA. Pulando sincronização inicial."
else
    echo ">>> Diretório de dados vazio. Iniciando sincronização com o primário..."

    echo ">>> Aguardando primário $REPLICATION_PRIMARY_HOST:$REPLICATION_PRIMARY_PORT estar acessível..."
    until PGPASSWORD="$REPLICATION_PASSWORD" pg_isready \
        -h "$REPLICATION_PRIMARY_HOST" \
        -p "$REPLICATION_PRIMARY_PORT" \
        -U "$REPLICATION_USER" > /dev/null 2>&1; do
        echo "    Primário indisponível. Aguardando 2 segundos..."
        sleep 2
    done
    echo ">>> Primário está acessível."

    echo ">>> Limpando e preparando diretório de dados..."
    rm -rf "$PGDATA"
    mkdir -p "$PGDATA"
    chmod 700 "$PGDATA"

    echo ">>> Executando pg_basebackup a partir do primário..."
    PGPASSWORD="$REPLICATION_PASSWORD" pg_basebackup \
        -h "$REPLICATION_PRIMARY_HOST" \
        -p "$REPLICATION_PRIMARY_PORT" \
        -U "$REPLICATION_USER" \
        -D "$PGDATA" \
        -Fp \
        -Xs \
        -P \
        -R \
        -v

    echo ">>> pg_basebackup concluído."

    # O -R cria o standby.signal e primary_conninfo em postgresql.auto.conf,
    # mas sem a senha. Precisamos adicionar a senha e o application_name.
    APP_NAME=$(hostname)
    echo ">>> Configurando primary_conninfo com application_name='$APP_NAME'..."
    cat >> "$PGDATA/postgresql.auto.conf" <<EOF
primary_conninfo = 'host=$REPLICATION_PRIMARY_HOST port=$REPLICATION_PRIMARY_PORT user=$REPLICATION_USER password=$REPLICATION_PASSWORD application_name=$APP_NAME sslmode=prefer'
EOF

    echo ">>> Garantindo standby.signal..."
    touch "$PGDATA/standby.signal"
fi

echo ">>> Iniciando PostgreSQL em modo standby..."
exec /usr/local/bin/docker-entrypoint.sh "$@"
