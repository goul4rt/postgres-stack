#!/bin/bash
set -euo pipefail

# ============================================================================
# restore.sh
# Restaura um backup .sql.gz no banco configurado.
#
# Uso (a partir do manage.sh no host):
#   ./manage.sh restore backup_app_db_20260423_030000.sql.gz
#
# O script é chamado dentro do container de backup com o nome do arquivo
# como $1 (o arquivo precisa estar em /backups).
# ============================================================================

: "${POSTGRES_HOST:?POSTGRES_HOST is required}"
: "${POSTGRES_PORT:=5432}"
: "${POSTGRES_USER:?POSTGRES_USER is required}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
: "${POSTGRES_DB:?POSTGRES_DB is required}"

BACKUP_DIR="${BACKUP_DIR:-/backups}"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

if [ $# -lt 1 ]; then
    echo "Usage: $0 <backup_file.sql.gz>"
    echo ""
    echo "Available backups:"
    ls -lh "${BACKUP_DIR}"/backup_*.sql.gz 2>/dev/null || echo "  (none)"
    exit 1
fi

BACKUP_FILE="$1"

# Aceita path completo ou só o nome do arquivo
if [ ! -f "${BACKUP_FILE}" ]; then
    BACKUP_FILE="${BACKUP_DIR}/${BACKUP_FILE}"
fi

if [ ! -f "${BACKUP_FILE}" ]; then
    log "✗ Backup file not found: ${BACKUP_FILE}"
    exit 1
fi

log "=== Restoring '${POSTGRES_DB}' from ${BACKUP_FILE} ==="
log "⚠  This will DROP existing objects (pg_dump foi feito com --clean --if-exists)"

export PGPASSWORD="${POSTGRES_PASSWORD}"

if gunzip -c "${BACKUP_FILE}" | psql \
    --host="${POSTGRES_HOST}" \
    --port="${POSTGRES_PORT}" \
    --username="${POSTGRES_USER}" \
    --dbname="${POSTGRES_DB}" \
    --set ON_ERROR_STOP=on \
    --quiet; then
    log "✔ Restore OK"
else
    log "✗ Restore FAILED"
    exit 1
fi

log "=== Restore complete ==="
