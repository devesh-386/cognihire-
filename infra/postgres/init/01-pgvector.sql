-- CH-0.3.1: enable the pgvector extension in the default database.
--
-- Runs automatically via Postgres's docker-entrypoint-initdb.d mechanism on
-- first-ever container start against an empty data directory. The
-- pgvector/pgvector image ships the extension binary; CREATE EXTENSION
-- registers it in this database. No tables are created here — schema
-- migrations belong to later tickets (e.g. CH-4.1.1's event store schema),
-- not to infrastructure scaffolding.
CREATE EXTENSION IF NOT EXISTS vector;
