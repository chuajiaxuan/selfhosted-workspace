-- init.sql — PostgreSQL first-boot provisioning for the workspace stack.
--
-- HOW IT RUNS
--   Mounted at /docker-entrypoint-initdb.d/10-init.sql. The official postgres image
--   executes it exactly once: the first time the container starts on an EMPTY data
--   directory. It never runs again. To re-run it, stop the stack and wipe
--   ${DATA_ROOT}/postgres (this destroys all data).
--
--   psql runs this as the superuser over the local socket while the apps are still
--   blocked by the healthcheck, so the databases exist before anything connects.
--
-- SECRETS
--   Passwords are read from the container environment (docker-compose.yml passes them
--   through from .env) via psql's backtick expansion. This file contains none.

\set ON_ERROR_STOP on

\set outline_pw `printf %s "$OUTLINE_DB_PASSWORD"`
\set gitea_pw   `printf %s "$GITEA_DB_PASSWORD"`
\set vikunja_pw `printf %s "$VIKUNJA_DB_PASSWORD"`

-- One role per application: isolation, least privilege, independently rotatable.
CREATE ROLE outline LOGIN PASSWORD :'outline_pw';
CREATE ROLE gitea   LOGIN PASSWORD :'gitea_pw';
CREATE ROLE vikunja LOGIN PASSWORD :'vikunja_pw';

-- OWNER matters: since PG15 the public schema is owned by the database owner, so each
-- app role can create its tables without any extra GRANTs.
CREATE DATABASE outline OWNER outline;
CREATE DATABASE gitea   OWNER gitea;
CREATE DATABASE vikunja OWNER vikunja;

-- Only the owning role may connect to its database.
REVOKE CONNECT ON DATABASE outline, gitea, vikunja FROM PUBLIC;

-- Outline's migrations expect these extensions. Provision them as superuser now so
-- the outline role never needs CREATE EXTENSION rights.
\connect outline
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Gitea and Vikunja need no extensions; their migrations run on first app start.
