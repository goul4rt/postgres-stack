#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# manage.sh — wrapper de docker compose pra operações comuns
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# cores
if [ -t 1 ]; then
    RED=$(printf '\033[31m')
    GRN=$(printf '\033[32m')
    YLW=$(printf '\033[33m')
    BLU=$(printf '\033[34m')
    DIM=$(printf '\033[2m')
    RST=$(printf '\033[0m')
else
    RED="" GRN="" YLW="" BLU="" DIM="" RST=""
fi

info()    { echo "${BLU}▸${RST} $*"; }
success() { echo "${GRN}✔${RST} $*"; }
warn()    { echo "${YLW}⚠${RST} $*"; }
error()   { echo "${RED}✗${RST} $*" >&2; }

# ---------------------------------------------------------------------------
# Verificações
# ---------------------------------------------------------------------------
require_env() {
    if [ ! -f .env ]; then
        error ".env não encontrado. Rode: ./manage.sh setup"
        exit 1
    fi
    ensure_docker
}

# Detecta se é `docker compose` (v2) ou `docker-compose` (v1).
# Lazy — só checa quando um comando que precisa é rodado.
DC=""
ensure_docker() {
    [ -n "${DC}" ] && return 0
    if docker compose version >/dev/null 2>&1; then
        DC="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        DC="docker-compose"
    else
        error "docker compose não encontrado. Instale Docker Desktop ou docker-compose-plugin."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Comandos
# ---------------------------------------------------------------------------

cmd_setup() {
    info "Configuração inicial..."

    if [ -f .env ]; then
        warn ".env já existe — não sobrescrevendo."
    else
        cp .env.example .env
        success ".env criado a partir de .env.example"
        warn "Edite .env e troque POSTGRES_PASSWORD antes de subir em produção!"
    fi

    chmod +x manage.sh scripts/*.sh docker/backup/entrypoint.sh 2>/dev/null || true
    mkdir -p backups

    success "Pronto. Próximos passos:"
    echo "  1. Edite .env (senhas, tuning)"
    echo "  2. ./manage.sh start"
}

cmd_start() {
    require_env
    info "Subindo stack..."
    $DC up -d --build
    success "Stack no ar"
    cmd_status
}

cmd_stop() {
    require_env
    info "Parando stack..."
    $DC stop
    success "Stack parada"
}

cmd_restart() {
    require_env
    info "Reiniciando stack..."
    $DC restart
    success "Stack reiniciada"
}

cmd_down() {
    require_env
    info "Removendo containers (volumes preservados)..."
    $DC down
    success "Containers removidos"
}

cmd_status() {
    require_env
    echo ""
    $DC ps
    echo ""

    # shellcheck disable=SC1091
    set -a; source .env; set +a

    echo "${DIM}Conexão direta (migrations, Prisma Studio, DBeaver):${RST}"
    echo "  Host:     localhost"
    echo "  Port:     ${POSTGRES_PORT:-5432}"
    echo "  Database: ${POSTGRES_DB}"
    echo "  User:     ${POSTGRES_USER}"
    echo "  JDBC:     jdbc:postgresql://localhost:${POSTGRES_PORT:-5432}/${POSTGRES_DB}"
    echo "  psql:     psql -h localhost -p ${POSTGRES_PORT:-5432} -U ${POSTGRES_USER} -d ${POSTGRES_DB}"
    echo ""
    echo "${DIM}Conexão via PgBouncer (app runtime — Prisma DATABASE_URL):${RST}"
    echo "  Host:     localhost"
    echo "  Port:     ${PGBOUNCER_PORT:-6432}"
    echo "  Database: ${POSTGRES_DB}"
    echo "  User:     ${POSTGRES_USER}"
    echo "  JDBC:     jdbc:postgresql://localhost:${PGBOUNCER_PORT:-6432}/${POSTGRES_DB}"
    echo "  Prisma:   postgresql://${POSTGRES_USER}:***@localhost:${PGBOUNCER_PORT:-6432}/${POSTGRES_DB}?pgbouncer=true"
    echo ""
}

cmd_logs() {
    require_env
    local service="${1:-postgres}"
    $DC logs -f --tail=100 "${service}"
}

cmd_psql() {
    require_env
    # shellcheck disable=SC1091
    set -a; source .env; set +a
    $DC exec postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}"
}

cmd_pgbouncer() {
    require_env
    # shellcheck disable=SC1091
    set -a; source .env; set +a
    info "Conectando no console admin do PgBouncer..."
    info "Comandos úteis: SHOW POOLS; SHOW STATS; SHOW CLIENTS; SHOW SERVERS;"
    $DC exec postgres psql \
        -h pgbouncer -p 5432 \
        -U "${POSTGRES_USER}" \
        -d pgbouncer
}

cmd_backup() {
    require_env
    info "Disparando backup manual..."
    $DC exec -T backup-scheduler bash -c 'source /etc/backup.env && /scripts/backup.sh'
    success "Backup concluído"
    cmd_backups
}

cmd_backups() {
    echo ""
    echo "${DIM}Backups em ./backups/:${RST}"
    if ls -lh backups/backup_*.sql.gz 2>/dev/null; then :; else
        warn "Nenhum backup encontrado ainda."
    fi
    echo ""
}

cmd_restore() {
    require_env
    if [ $# -lt 1 ]; then
        error "Uso: ./manage.sh restore <arquivo.sql.gz>"
        cmd_backups
        exit 1
    fi
    local file="$1"

    warn "Isso vai sobrescrever o banco atual com o conteúdo de ${file}"
    read -r -p "Continuar? (yes/no): " confirm
    if [ "${confirm}" != "yes" ]; then
        info "Cancelado."
        exit 0
    fi

    $DC exec -T backup-scheduler bash -c "source /etc/backup.env && /scripts/restore.sh '${file}'"
    success "Restore concluído"
}

cmd_scheduler_logs() {
    require_env
    info "Logs do scheduler (Ctrl+C pra sair)..."
    $DC logs -f --tail=100 backup-scheduler
}

cmd_reset() {
    require_env
    warn "Isso vai APAGAR todos os dados (volumes de pgdata + pgadmin)."
    read -r -p "Digite 'APAGAR TUDO' para confirmar: " confirm
    if [ "${confirm}" != "APAGAR TUDO" ]; then
        info "Cancelado."
        exit 0
    fi

    $DC down -v
    success "Stack destruída e volumes removidos"
}

cmd_help() {
    cat <<EOF
${BLU}postgres-stack${RST} — docker-compose wrapper

${DIM}Lifecycle:${RST}
  setup               Copia .env.example → .env e dá permissões nos scripts
  start               Sobe postgres + backup-scheduler
  stop                Para containers (preserva dados)
  restart             Reinicia containers
  down                Remove containers (preserva volumes)
  reset               DESTRÓI tudo incluindo volumes — uso em dev só

${DIM}Observabilidade:${RST}
  status              Mostra containers + info de conexão
  logs [serviço]      Tail de logs (default: postgres)
  scheduler           Logs do backup-scheduler

${DIM}Operações:${RST}
  psql                Abre psql interativo no banco
  pgbouncer           Console admin do PgBouncer (SHOW POOLS, etc)
  backup              Dispara backup manual (além do agendado)
  backups             Lista backups disponíveis
  restore <arquivo>   Restaura backup

Exemplos:
  ./manage.sh setup
  ./manage.sh start
  ./manage.sh backup
  ./manage.sh restore backup_app_db_20260423_030000.sql.gz
EOF
}

# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------
case "${1:-help}" in
    setup)         cmd_setup ;;
    start)         cmd_start ;;
    stop)          cmd_stop ;;
    restart)       cmd_restart ;;
    down)          cmd_down ;;
    status)        cmd_status ;;
    logs)          shift; cmd_logs "$@" ;;
    psql)          cmd_psql ;;
    pgbouncer)     cmd_pgbouncer ;;
    backup)        cmd_backup ;;
    backups)       cmd_backups ;;
    restore)       shift; cmd_restore "$@" ;;
    scheduler)     cmd_scheduler_logs ;;
    reset)         cmd_reset ;;
    help|-h|--help) cmd_help ;;
    *)
        error "Comando desconhecido: $1"
        echo ""
        cmd_help
        exit 1
        ;;
esac
