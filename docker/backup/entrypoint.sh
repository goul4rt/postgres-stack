#!/bin/bash
set -euo pipefail

# ============================================================================
# Entrypoint do container de backup.
# Monta o crontab a partir de $BACKUP_SCHEDULE e sobe dcron em foreground.
# ============================================================================

: "${POSTGRES_HOST:?POSTGRES_HOST is required}"
: "${POSTGRES_USER:?POSTGRES_USER is required}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
: "${POSTGRES_DB:?POSTGRES_DB is required}"
: "${BACKUP_SCHEDULE:=0 3 * * *}"
: "${BACKUP_RETENTION_DAYS:=7}"
: "${BACKUP_ON_START:=false}"

echo "[entrypoint] Backup scheduler starting"
echo "[entrypoint]   schedule:        ${BACKUP_SCHEDULE}"
echo "[entrypoint]   retention:       ${BACKUP_RETENTION_DAYS} days"
echo "[entrypoint]   backup on start: ${BACKUP_ON_START}"
echo "[entrypoint]   target host:     ${POSTGRES_HOST}:${POSTGRES_PORT:-5432}"
echo "[entrypoint]   target db:       ${POSTGRES_DB}"

# ---------------------------------------------------------------------------
# Exporta env vars para um arquivo que o cron-job consegue ler (cron não
# herda env do processo pai)
# ---------------------------------------------------------------------------
cat > /etc/backup.env <<EOF
export POSTGRES_HOST="${POSTGRES_HOST}"
export POSTGRES_PORT="${POSTGRES_PORT:-5432}"
export POSTGRES_USER="${POSTGRES_USER}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD}"
export POSTGRES_DB="${POSTGRES_DB}"
export BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS}"
export PATH="/usr/local/bin:/usr/bin:/bin"
EOF
chmod 600 /etc/backup.env

# ---------------------------------------------------------------------------
# Instala o crontab
# Redireciona stdout/stderr pro arquivo de log E pro stdout do container (fd 1)
# — assim `docker logs` mostra tudo em tempo real.
# ---------------------------------------------------------------------------
CRON_CMD='source /etc/backup.env && /scripts/backup.sh >> /backups/backup.log 2>&1'
echo "${BACKUP_SCHEDULE} ${CRON_CMD}" > /var/spool/cron/crontabs/root
chmod 600 /var/spool/cron/crontabs/root

mkdir -p /backups /var/spool/cron/crontabs
touch /backups/backup.log

# ---------------------------------------------------------------------------
# Backup inicial se configurado
# ---------------------------------------------------------------------------
if [ "${BACKUP_ON_START}" = "true" ]; then
    echo "[entrypoint] Running initial backup..."
    # shellcheck disable=SC1091
    source /etc/backup.env
    /scripts/backup.sh >> /backups/backup.log 2>&1 || echo "[entrypoint] Initial backup failed (see /backups/backup.log)"
fi

# ---------------------------------------------------------------------------
# Tail do log pro stdout em background + cron em foreground
# ---------------------------------------------------------------------------
tail -F /backups/backup.log &
exec cron -f
