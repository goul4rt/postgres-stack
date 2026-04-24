# postgres-stack

Setup production-ready de PostgreSQL em Docker, com backup automatizado, rotação e restore. Baseado na estrutura do [nasro-dadi/postgresql](https://github.com/nasro-dadi/postgresql) com algumas melhorias.

## O que tem aqui

- **PostgreSQL 18** (via imagem `pgvector/pgvector:pg18` — postgres oficial + extensão pgvector pronta)
- **pgvector habilitado** por default — se não usar, zero overhead; se precisar, já tá lá
- **PgBouncer** em transaction pooling — essencial pra Prisma/serverless/apps com muitas conexões curtas
- **Tuning calibrado pra 6GB RAM** (SSD, workload web/OLTP)
- **`shm_size: 2gb`** cobrindo `shared_buffers=1536MB` + overhead
- **Backup automatizado** em container separado com cron, retenção configurável
- **pg_dump na mesma versão do servidor** (o container de backup herda da imagem do Postgres)
- **Healthcheck** com `pg_isready` e `depends_on: service_healthy`
- **`manage.sh`** pra lifecycle, backups, restore, psql, console admin do PgBouncer

Sem UI web — gerenciamento via DBeaver no host.

## Arquitetura

```
┌─────────────────────────────────────────────┐
│  Seu app (Prisma, Node, etc)                │
└─────────────────┬───────────────────────────┘
                  │ DATABASE_URL → :6432 (pool)
                  │ DIRECT_URL   → :5432 (migrations)
                  ▼
┌─────────────────────────────────────────────┐
│  PgBouncer (6432) ─ transaction pooling     │
│  • até 1000 clientes simultâneos            │
│  • 25 conexões reais ao Postgres por pool   │
└─────────────────┬───────────────────────────┘
                  ▼
┌─────────────────────────────────────────────┐
│  PostgreSQL 18 + pgvector (5432)            │
│  • max_connections=100                       │
│  • shared_buffers=1.5GB, work_mem=20MB      │
└─────────────────┬───────────────────────────┘
                  ▼
┌─────────────────────────────────────────────┐
│  backup-scheduler — cron diário + rotação   │
│  → ./backups/*.sql.gz                        │
└─────────────────────────────────────────────┘
```

## Estrutura

```
postgres-stack/
├── docker-compose.yml
├── .env.example           # template — copiar pra .env
├── manage.sh              # wrapper de docker compose
├── docker/
│   └── backup/
│       ├── Dockerfile     # imagem do scheduler (postgres + dcron)
│       └── entrypoint.sh  # configura crontab e sobe crond
├── scripts/
│   ├── backup.sh          # pg_dump + gzip + rotação
│   └── restore.sh         # gunzip + psql
├── init/
│   └── 01-init.sql        # extensions e setup inicial
└── backups/               # onde os .sql.gz caem (bind mount)
```

## Quick start

```bash
# 1. Setup inicial (cria .env e dá chmod nos scripts)
./manage.sh setup

# 2. Edita .env — principalmente POSTGRES_PASSWORD
#    Dica: openssl rand -base64 24
vim .env

# 3. Sobe o stack
./manage.sh start

# 4. Confere
./manage.sh status
./manage.sh psql
```

## Integrando com Prisma

Prisma + PgBouncer em transaction mode tem **duas nuances críticas**:

1. Transaction mode desabilita prepared statements (o pool reutiliza conexões entre queries, e prepared statements são por-sessão). Você precisa avisar ao Prisma disso com a flag `pgbouncer=true` na URL.
2. **Migrations** e **Prisma Studio** precisam de uma conexão *direta* no Postgres — elas usam features de sessão (advisory locks, session-level state). É pra isso que existe o `directUrl`.

### `.env` do seu projeto Prisma

```bash
# Runtime do app — via pooler (transaction mode)
DATABASE_URL="postgresql://app:SUA_SENHA@localhost:6432/app_db?pgbouncer=true&connection_limit=5"

# Migrations, introspection, Prisma Studio — direto no Postgres
DIRECT_URL="postgresql://app:SUA_SENHA@localhost:5432/app_db"
```

### `schema.prisma`

```prisma
datasource db {
  provider  = "postgresql"
  url       = env("DATABASE_URL")
  directUrl = env("DIRECT_URL")  // usado por `prisma migrate`, `prisma db pull`, Studio
}
```

### Sobre `connection_limit` do Prisma

O Prisma tem **seu próprio pool interno** no lado do app. Com PgBouncer na frente, esse pool vira redundante:

- **Long-running Node.js (Express, Nest, etc):** `connection_limit=5` é um bom começo. Pode subir pra 10 se o app for muito concorrente.
- **Serverless / Lambdas / Edge functions:** `connection_limit=1` — cada instância é efêmera e single-threaded, não faz sentido manter pool local.
- **Workers pesados em paralelo:** calcule `limit × num_workers <= PGBOUNCER_DEFAULT_POOL_SIZE`.

### Limitações de transaction mode (Prisma já lida, mas vale saber)

- `SET` fora de transação não persiste
- `LISTEN`/`NOTIFY` não funciona de forma confiável
- `$transaction([...])` do Prisma funciona normalmente
- Interactive transactions (`$transaction(async (tx) => ...)`) funcionam mas seguram a conexão mais tempo — use com moderação

Se precisar dessas features, troque `PGBOUNCER_POOL_MODE=session` no `.env` (perde muito do benefício do pool, mas funciona).

## Conectar pelo DBeaver

**Sempre use a porta 5432** (direta) no DBeaver. PgBouncer em transaction mode interfere com várias features do DBeaver (autocomplete baseado em session, introspection, etc).

1. `New Database Connection` → **PostgreSQL**
2. Preenche com os valores do `.env`:
   - **Host:** `localhost`
   - **Port:** `5432` (**não** 6432 — DBeaver quer conexão direta)
   - **Database:** valor de `POSTGRES_DB`
   - **Username:** valor de `POSTGRES_USER`
   - **Password:** valor de `POSTGRES_PASSWORD`
3. Na aba **Driver properties**, se quiser suprimir warning de SSL em dev local, seta `sslmode=disable`.
4. Test Connection → Finish.

O `./manage.sh status` imprime as duas URLs (direta e via pooler) já montadas.

## Monitorando o PgBouncer

```bash
./manage.sh pgbouncer
```

Abre o console admin. Comandos úteis dentro dele:

```sql
SHOW POOLS;       -- estado de cada pool (ativas, ociosas, esperando)
SHOW STATS;       -- stats agregadas (queries, txs, bytes)
SHOW CLIENTS;     -- clientes conectados
SHOW SERVERS;     -- conexões reais ao postgres
SHOW CONFIG;      -- config atual
```

Métrica mais importante: em `SHOW POOLS`, a coluna `cl_waiting` deve ser **0** ou baixo. Se cresce, seu `DEFAULT_POOL_SIZE` tá pequeno ou há query lenta segurando conexão.

## Backups

O container `backup-scheduler` roda em paralelo ao Postgres com um cron embutido. Configurações no `.env`:

```bash
BACKUP_SCHEDULE=0 3 * * *        # todo dia às 03:00
BACKUP_RETENTION_DAYS=7           # mantém 7 dias
BACKUP_ON_START=false             # roda backup ao subir o container
```

Comandos:
```bash
./manage.sh backup                # dispara backup manual
./manage.sh backups               # lista arquivos
./manage.sh scheduler             # tail dos logs do cron
./manage.sh restore backup_app_db_20260423_030000.sql.gz
```

Os `.sql.gz` ficam em `./backups/` no host. Log contínuo em `./backups/backup.log`.

### Por que um container separado pro backup?

- Roda em paralelo sem poluir o container do Postgres com cron
- Se o backup der pau, não derruba o banco
- Pode ser reiniciado/reconstruído independente
- `docker logs postgres-backup` mostra o que o cron tá fazendo

## Tuning

Os valores default são pra um container com **~6GB RAM** dedicados, SSD, workload web/OLTP:

| Parâmetro | Valor | Regra |
|---|---|---|
| `shared_buffers` | 1536MB | ~25% da RAM |
| `effective_cache_size` | 4608MB | ~75% da RAM |
| `work_mem` | 20MB | `(RAM - shared_buffers) / (max_conn × 3)` |
| `maintenance_work_mem` | 512MB | — |
| `max_connections` | 100 | Limite pros pools do PgBouncer |
| `shm_size` | 2GB | `>= shared_buffers + overhead` |

**Pool sizing (PgBouncer):**

| Parâmetro | Valor | Regra |
|---|---|---|
| `MAX_CLIENT_CONN` | 1000 | Quantos clientes podem conectar |
| `DEFAULT_POOL_SIZE` | 25 | Conexões reais ao PG por (user,db) |
| `RESERVE_POOL_SIZE` | 5 | Extras temporários pra picos |

A matemática: `DEFAULT_POOL_SIZE × nº de pools + RESERVE × nº de pools <= PG_MAX_CONNECTIONS`. Com 1 pool (1 user, 1 db): `25 + 5 = 30` conexões usadas, sobram 70 pro que mais aparecer (outros users, conexões admin, DBeaver, Prisma migrations direto).

**Pra host maior ou menor:**
1. Rode [PGTune](https://pgtune.leopard.in.ua/) com seus specs e tipo de workload
2. Substitua os valores no `.env`
3. Se aumentar `PG_MAX_CONNECTIONS`, pode aumentar `PGBOUNCER_DEFAULT_POOL_SIZE` proporcionalmente
4. `./manage.sh restart`

Pra produção séria, considere extrair a config pra um `postgresql.conf` montado como volume — fica mais legível que 15 flags `-c` no `command`.

## Segurança

- **NUNCA** commite `.env` (já tá no `.gitignore`)
- Troque `POSTGRES_PASSWORD` antes de subir. Gera uma senha forte: `openssl rand -base64 24`
- Em produção, considere usar **Docker secrets** em vez de env vars (o entrypoint do postgres suporta `POSTGRES_PASSWORD_FILE`)
- A role default é superuser. Pra app, crie uma role separada com permissões limitadas (exemplo comentado em `init/01-init.sql`)
- Se o banco ficar exposto pra internet, configure `pg_hba.conf` com `scram-sha-256` e considere não expor a porta `5432` pro host (deixa só na network interna)

## Upgrade de versão

Postgres **não** faz upgrade automático de major version (18 → 19 não é drop-in). Processo:

```bash
./manage.sh backup                # backup da versão atual
./manage.sh down                  # para os containers

# Edita POSTGRES_IMAGE no .env pra nova versão
# Remove o volume pgdata
docker volume rm pgstack_pgdata

./manage.sh start                 # sobe já na nova versão (banco vazio)
./manage.sh restore backup_*.sql.gz
```

Minor versions (18.3 → 18.4) são seguras — só bumpar a tag.

## Troubleshooting

**Banco não sobe, container reinicia em loop:**
```bash
./manage.sh logs postgres
```
Causa comum: `.env` com variáveis obrigatórias não setadas ou volume corrompido de tentativa anterior. Em dev, `./manage.sh reset` resolve.

**Backup falha com "connection refused":**
O scheduler depende do healthcheck do postgres. Se o healthcheck tá falhando, veja os logs do postgres.

**pg_dump reclama de "version mismatch":**
Não deve acontecer nesse setup (o backup container herda da mesma imagem), mas se você trocar `POSTGRES_IMAGE` pra algo exótico (ex.: TimescaleDB), verifique se a imagem tem o `pg_dump` matching.

**Permissão negada em `./backups/`:**
O container roda como user `postgres` (UID 999 na imagem debian do pgvector; 70 no postgres:*-alpine). Se tiver problema de permissão no bind mount, ajuste:
```bash
sudo chown -R 999:999 backups/     # para pgvector/pgvector:pg18
# ou
sudo chown -R 70:70 backups/        # para postgres:18-alpine
```
