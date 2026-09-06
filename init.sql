-- init.sql makes the roles and the databases for the workspace stack.
--
-- HOW POSTGRESQL RUNS THIS FILE
--   The compose file puts this file at /docker-entrypoint-initdb.d/10-init.sql.
--   The postgres image runs the file one time only. It runs the file at the first start,
--   when the data directory is empty. After that, it does not run the file again.
--   WARNING: To run this file again, stop the stack and delete ${DATA_ROOT}/postgres.
--   This procedure deletes all of your data.
--
--   The program psql runs this file as the superuser through the local socket. At that
--   time the healthcheck holds the applications. Thus the databases are ready before an
--   application connects.
--
-- SECRET VALUES
--   This file has no passwords. The passwords come from the container environment.
--   The compose file reads them from .env. The psql backtick command puts them here.

\set ON_ERROR_STOP on

\set outline_pw `printf %s "$OUTLINE_DB_PASSWORD"`
\set gitea_pw   `printf %s "$GITEA_DB_PASSWORD"`
\set vikunja_pw `printf %s "$VIKUNJA_DB_PASSWORD"`

-- Make one role for each application. Each application has only its own data.
-- You can change one password and the other applications continue to operate.
CREATE ROLE outline LOGIN PASSWORD :'outline_pw';
CREATE ROLE gitea   LOGIN PASSWORD :'gitea_pw';
CREATE ROLE vikunja LOGIN PASSWORD :'vikunja_pw';

-- The OWNER value is important. From PostgreSQL 15, the owner of the database also owns
-- the public schema. Thus each role can make its tables. No GRANT command is necessary.
CREATE DATABASE outline OWNER outline;
CREATE DATABASE gitea   OWNER gitea;
CREATE DATABASE vikunja OWNER vikunja;

-- Only the owner can connect to its database.
REVOKE CONNECT ON DATABASE outline, gitea, vikunja FROM PUBLIC;

-- The Outline migrations need these two extensions. The superuser makes them now.
-- Thus the outline role does not need the CREATE EXTENSION permission.
\connect outline
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Gitea and Vikunja do not need an extension. They run their migrations at the first start.
