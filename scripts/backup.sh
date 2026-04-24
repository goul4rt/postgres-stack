#!/bin/bash
set -euo pipefail

# ============================================================================
# backup.sh
# Gera um dump comprimido do Postgres e rotaciona backups antigos.
# ============================================================================

: "${POSTGRES_HOST:?POSTGRES_HOST is required}"
: "${POSTGRES_PORT:=5432}"
: "${POSTGRES_USER:?POSTGRES_USER is required}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
: "${POSTGRES_DB:?POSTGRES_DB is required}"
: "${BACKUP_RETENTION_DAYS:=7}"

BACKUP_DIR="${BACKUP_DIR:-/backups}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/backup_${POSTGRES_DB}_${TIMESTAMP}.sql.gz"

mkdir -p "${BACKUP_DIR}"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

log "=== Starting backup of '${POSTGRES_DB}' ==="

export PGPASSWORD="${POSTGRES_PASSWORD}"

# --format=custom seria mais flexível, mas plain+gzip é mais portável e fácil
# de inspecionar. Se precisar de restore seletivo, troca pra -Fc e ajusta o
# restore.sh pra usar pg_restore em vez de psql.
if pg_dump \
    --host="${POSTGRES_HOST}" \
    --port="${POSTGRES_PORT}" \
    --username="${POSTGRES_USER}" \
    --dbname="${POSTGRES_DB}" \
    --no-owner \
    --no-privileges \
    --clean \
    --if-exists \
    --verbose \
    2> >(sed 's/^/[pg_dump] /' >&2) \
    | gzip -9 > "${BACKUP_FILE}"; then

    SIZE=$(du -h "${BACKUP_FILE}" | cut -f1)
    log "✔ Backup OK: ${BACKUP_FILE} (${SIZE})"
else
    log "✗ Backup FAILED"
    rm -f "${BACKUP_FILE}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Rotação: remove backups mais antigos que BACKUP_RETENTION_DAYS
# ---------------------------------------------------------------------------
log "Rotating backups older than ${BACKUP_RETENTION_DAYS} days..."
REMOVED=$(find "${BACKUP_DIR}" \
    -maxdepth 1 \
    -name "backup_${POSTGRES_DB}_*.sql.gz" \
    -type f \
    -mtime "+${BACKUP_RETENTION_DAYS}" \
    -print -delete | wc -l)
log "Removed ${REMOVED} old backup(s)"

# ---------------------------------------------------------------------------
# Sumário
# ---------------------------------------------------------------------------
TOTAL=$(find "${BACKUP_DIR}" -maxdepth 1 -name "backup_${POSTGRES_DB}_*.sql.gz" -type f | wc -l)
TOTAL_SIZE=$(du -sh "${BACKUP_DIR}" | cut -f1)
log "Backup directory: ${TOTAL} file(s), ${TOTAL_SIZE} total"
log "=== Backup complete ==="
