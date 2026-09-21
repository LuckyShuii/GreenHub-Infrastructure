-- Extensions only. Runs once, on an empty data directory.
--
-- The application schema is NOT here: it belongs to the backend repo and is applied by its
-- Alembic migrations at container start. A schema shipped through initdb.d could never be
-- replayed against a database that already holds data, so it would silently rot.
CREATE EXTENSION IF NOT EXISTS postgis;
