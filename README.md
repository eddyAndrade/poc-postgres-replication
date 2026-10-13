# PostgreSQL Streaming Replication com Docker Compose

Este projeto provisiona um cluster PostgreSQL com **1 primário (master)** e **2 réplicas em hot standby** utilizando Docker Compose, seguindo boas práticas de produção.

---

## Arquitetura

```
┌─────────────────────────────────────────────────────────────┐
│                  Docker Network (Bridge)                    │
│                     (postgres-replica)                      │
│                                                             │
│   ┌─────────────────┐                                       │
│   │ postgres-primary│  ← Escrita + Leitura                  │
│   └────────┬────────┘                                       │
│            │ Streaming Replication (WAL)                     │
│            ├──────────────────────┐                         │
│            │                      │                         │
│   ┌────────▼────────┐    ┌───────▼────────┐               │
│   │ postgres-replica1│    │postgres-replica2│               │
│   │   Hot Standby    │    │   Hot Standby    │               │
│   │   Só Leitura     │    │   Só Leitura     │               │
│   └──────────────────┘    └──────────────────┘               │
└─────────────────────────────────────────────────────────────┘
```

### Características

- **Streaming Replication**: As réplicas recebem WALs (Write-Ahead Logs) do primário em tempo real.
- **Hot Standby**: As réplicas aceitam consultas de leitura (`SELECT`) simultaneamente à replicação.
- **Replicação Síncrona**: Configurada com `synchronous_commit = remote_apply` e `FIRST 1`, garantindo que pelo menos uma réplica aplique a transação antes do primário confirmar ao cliente (máxima durabilidade sem sacrificar totalmente a performance).
- **Replication Slots**: Slots físicos persistentes (`replica1_slot`, `replica2_slot`) evitam que o primário remova arquivos WAL antes que as réplicas os consumam, prevenindo desync em caso de réplica lenta ou offline.
- **Inicialização Automática**: Réplicas utilizam `pg_basebackup` para clonar o primário automaticamente na primeira execução.
- **Health Checks**: Todos os containers possuem verificações de saúde (`pg_isready`).
- **Segurança**: Autenticação `scram-sha-256`, rede isolada, usuário dedicado para replicação.

---

## Estrutura do Projeto

```
.
├── .env.example                      # Variáveis de ambiente (template)
├── .gitignore                        # Ignora .env e dados locais
├── docker-compose.yml                # Orquestração dos serviços
├── README.md                         # Este arquivo
├── config/
│   └── replica/
│       └── postgresql.conf           # Configuração das réplicas
└── scripts/
    ├── primary/
    │   ├── 01-init-replication.sh    # Cria usuário e slots de replicação
    │   └── 99-configure-replication.sh # Configura postgresql.conf e pg_hba.conf
    └── replica/
        └── entrypoint.sh             # Entrypoint customizado (pg_basebackup)
```

---

## Pré-requisitos

- [Docker](https://docs.docker.com/get-docker/) 20.10+
- [Docker Compose](https://docs.docker.com/compose/install/) 2.20+ (suporte a `depends_on` com `condition`)

---

## Início Rápido

### 1. Clone ou copie o projeto

```bash
cd postgre-replica
```

### 2. Configure as variáveis de ambiente

```bash
cp .env.example .env
```

Edite o arquivo `.env` e altere as senhas padrão:

```dotenv
POSTGRES_PASSWORD=SuaSenhaSeguraAqui123!
REPLICATION_PASSWORD=SuaSenhaDeReplicacao456!
```

> ⚠️ **Nunca commite o arquivo `.env` no Git.** Ele já está listado no `.gitignore`.

### 3. Inicie o cluster

```bash
docker compose up -d
```

O Docker Compose irá:
1. Criar a rede `postgres-replica`.
2. Iniciar o `postgres-primary`, criar o banco, o usuário de replicação e os slots.
3. Aguardar o primário ficar saudável.
4. Iniciar `postgres-replica1` e `postgres-replica2`, executando `pg_basebackup` para clonar os dados.

### 4. Verifique o status

```bash
# Status dos containers
docker compose ps

# Logs do primário
docker compose logs -f postgres-primary

# Logs das réplicas
docker compose logs -f postgres-replica1
docker compose logs -f postgres-replica2
```

---

## Validação da Replicação

### Conecte-se ao primário

```bash
docker exec -i postgres-primary psql -U postgres -d app_database
```

Crie uma tabela de teste:

```sql
CREATE TABLE test_replication (id SERIAL PRIMARY KEY, message TEXT, created_at TIMESTAMP DEFAULT NOW());
INSERT INTO test_replication (message) VALUES ('Hello from Primary!');
```

### Conecte-se a uma réplica

```bash
docker exec -i postgres-replica1 psql -U postgres -d app_database
```

Verifique se os dados replicaram:

```sql
SELECT * FROM test_replication;
```

> A réplica está em hot standby, portanto comandos de escrita (`INSERT`, `UPDATE`, `DELETE`, `CREATE`) serão rejeitados. Isso é esperado.

### Verificar status da replicação no primário

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

Saída esperada (semelhante a):

```
  client_addr  |   state   | sent_lsn  | write_lsn | flush_lsn | replay_lsn | sync_state
---------------+-----------+-----------+-----------+-----------+------------+------------
 172.23.0.4    | streaming | 0/4000060 | 0/4000060 | 0/4000060 | 0/4000060  | sync
 172.23.0.3    | streaming | 0/4000060 | 0/4000060 | 0/4000060 | 0/4000060  | potential
```

- **`sync`**: Réplica síncrona atual (confirma transações).
- **`potential`**: Réplica assíncrona (pronta para virar síncrona se a outra falhar).
- **`streaming`**: WAL está sendo transmitido em tempo real.

### Verificar slots de replicação

```bash
docker exec -i postgres-primary psql -U postgres -c "
SELECT slot_name, plugin, slot_type, active, restart_lsn 
FROM pg_replication_slots;
"
```

---

## Portas e Acesso

| Serviço             | Host Port | Container Port |
|---------------------|-----------|----------------|
| postgres-primary    | 5432      | 5432           |
| postgres-replica1   | 5433      | 5432           |
| postgres-replica2   | 5434      | 5432           |

### Exemplo de conexão via psql (do host)

```bash
# Primário (leitura e escrita)
psql -h localhost -p 5432 -U postgres -d app_database

# Réplica 1 (somente leitura)
psql -h localhost -p 5433 -U postgres -d app_database

# Réplica 2 (somente leitura)
psql -h localhost -p 5434 -U postgres -d app_database
```

---

## Boas Práticas Aplicadas

1. **Senhas em `.env`**: Credenciais não estão hardcoded no `docker-compose.yml`.
2. **Usuário dedicado**: `replicator` possui apenas o privilégio `REPLICATION`, minimizando o impacto de credenciais vazadas.
3. **Rede isolada**: Bridge network dedicada (`postgres-replica`) isolando o tráfego do cluster.
4. **Autenticação forte**: `scram-sha-256` ao invés de `md5` ou `trust`.
5. **Replication Slots**: Garantem que o primário retenha WALs necessários para réplicas lentas ou temporariamente offline.
6. **Sincronização configurável**: `FIRST 1` permite que o primário continue operando mesmo se uma réplica cair, mantendo durabilidade com a réplica restante.
7. **Hot Standby Feedback**: `hot_standby_feedback = on` evita que o autovacuum do primário remova tuplas ainda necessárias para queries longas nas réplicas.
8. **Health Checks**: Garantem que réplicas só iniciem após o primário estar pronto.
9. **Volumes nomeados**: Dados persistem entre reinicializações dos containers (`primary_data`, `replica1_data`, `replica2_data`).
10. **Restart Policy**: `unless-stopped` garante que os serviços se recuperem automaticamente após falhas (exceto parada manual).

---

## Manutenção e Operações

### Reiniciar o cluster

```bash
docker compose restart
```

### Parar o cluster

```bash
docker compose down
```

> Os volumes persistem. Ao subir novamente (`docker compose up -d`), os dados serão mantidos.

### Destruir tudo (incluindo dados!)

```bash
docker compose down -v
```

> **Atenção:** Isso remove os volumes `primary_data`, `replica1_data` e `replica2_data`. Todos os dados serão perdidos.

### Forçar ressincronização de uma réplica

Se uma réplica ficar desincronizada ou corrompida:

```bash
# 1. Pare a réplica
docker compose stop postgres-replica1

# 2. Remova o volume
docker volume rm postgre-replica_replica1_data

# 3. Recrie e reinicie
docker compose up -d postgres-replica1
```

A réplica executará `pg_basebackup` novamente e se reconectará ao primário.

### Promover uma réplica para primário (Failover Manual)

Em caso de falha do primário, você pode promover uma réplica:

```bash
# Pare o primário (se ainda estiver rodando)
docker compose stop postgres-primary

# Promova a réplica 1
docker exec postgres-replica1 pg_ctl promote -D /var/lib/postgresql/data/pgdata
```

> **Nota:** Este setup não implementa failover automático. Para alta disponibilidade automática, considere ferramentas como [Patroni](https://github.com/zalando/patroni), [Repmgr](https://repmgr.org/) ou [PgBouncer](https://www.pgbouncer.org/) com um proxy de conexão.

---

## Troubleshooting

### Réplica não conecta ao primário

```bash
docker compose logs postgres-replica1
```

Verifique:
- Se o primário está saudável: `docker compose ps`
- Se as credenciais em `.env` são consistentes
- Se a rede Docker está funcionando: `docker network inspect postgre-replica_postgres-replica`

### `pg_basebackup` falha com "password authentication failed"

Certifique-se de que o `.env` foi criado **antes** do primeiro `docker compose up`. Se mudar as senhas após a criação dos volumes, destrua os volumes (`docker compose down -v`) e suba novamente.

### Réplica fica em `catchup` por muito tempo

Isso é normal se houver muita carga de escrita. O `wal_keep_size = 256MB` ajuda, mas em ambientes de alta carga, aumente este valor ou configure um archive de WAL em storage compartilhado.

---

## Referências

- [PostgreSQL Documentation - Streaming Replication](https://www.postgresql.org/docs/current/warm-standby.html#STREAMING-REPLICATION)
- [PostgreSQL Documentation - Synchronous Replication](https://www.postgresql.org/docs/current/synchronous-replication.html)
- [PostgreSQL Documentation - Replication Slots](https://www.postgresql.org/docs/current/warm-standby.html#STREAMING-REPLICATION-SLOTS)
- [Docker Hub - Official PostgreSQL Image](https://hub.docker.com/_/postgres)

---

## Licença

Este template é open-source. Adapte conforme as necessidades do seu projeto.
