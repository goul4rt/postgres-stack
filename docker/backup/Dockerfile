# Reusa a mesma imagem do Postgres pra garantir que pg_dump seja exatamente a
# mesma versão do servidor. Evita o clássico "version mismatch" do pg_dump.
ARG POSTGRES_IMAGE=pgvector/pgvector:pg18
FROM ${POSTGRES_IMAGE}

# A imagem pgvector é debian-based, não alpine — dcron não existe lá,
# então instala cron padrão.
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    cron \
    tzdata \
    coreutils \
    findutils \
    gzip \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
