-- ===========================================================================
-- 01-init.sql
-- Rodado APENAS na primeira inicialização (quando o volume pgdata está vazio).
-- Se o banco já existe, este arquivo é ignorado.
-- ===========================================================================

-- Extensões úteis
CREATE EXTENSION IF NOT EXISTS "pgcrypto";    -- gen_random_uuid(), crypt(), digest()
CREATE EXTENSION IF NOT EXISTS "citext";      -- case-insensitive text (ótimo pra email)
CREATE EXTENSION IF NOT EXISTS "pg_trgm";     -- trigram similarity (LIKE performático)

-- pgvector — embeddings e similarity search.
-- Se estiver usando `postgres:18-alpine` (sem pgvector), comente esta linha.
CREATE EXTENSION IF NOT EXISTS "vector";

-- uuid-ossp: só descomente se precisar de uuid_generate_v1/v3/v5.
-- Pra UUIDv4 use pgcrypto: gen_random_uuid()
-- Pra UUIDv7 (timestamp-ordered, melhor pra PKs): uuidv7() é nativo no PG18.
-- CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ===========================================================================
-- Exemplo: schema de aplicação com role separada do superuser
-- ===========================================================================
-- Crie uma role com permissão limitada para a app (em vez de usar o superuser).
-- Descomente e ajuste conforme sua necessidade.
--
-- DO $$
-- BEGIN
--     IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_rw') THEN
--         CREATE ROLE app_rw WITH LOGIN PASSWORD 'trocar_essa_senha';
--     END IF;
-- END$$;
--
-- GRANT CONNECT ON DATABASE current_database() TO app_rw;
-- GRANT USAGE, CREATE ON SCHEMA public TO app_rw;
-- ALTER DEFAULT PRIVILEGES IN SCHEMA public
--     GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;
-- ALTER DEFAULT PRIVILEGES IN SCHEMA public
--     GRANT USAGE, SELECT ON SEQUENCES TO app_rw;
