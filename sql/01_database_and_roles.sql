-- ---------------------------------------------------------------------------
-- 01  Database and roles
-- ---------------------------------------------------------------------------
-- Run once, as a superuser, connected to the postgres maintenance database.
-- Everything after this file runs connected to pp_rdw.
--
-- The postgres database stays empty. It is the maintenance database, assumed
-- to exist by pgAdmin, pg_dumpall and anything invoked without -d, so it is
-- neither renamed nor used to hold objects.
-- ---------------------------------------------------------------------------

CREATE DATABASE pp_rdw;

-- Owns the schemas and their objects. Cannot log in: ownership is a property
-- to be inherited, not an account for anyone to connect as.
CREATE ROLE pp_owner NOLOGIN;

-- The extraction service account. NOINHERIT so it holds only what is granted
-- to it directly. CONNECTION LIMIT bounds a hung run's ability to accumulate
-- connections.
CREATE ROLE svc_py WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
                        NOINHERIT CONNECTION LIMIT 5
                        PASSWORD '<set a long random password>';

GRANT CONNECT ON DATABASE pp_rdw TO svc_py;

-- Objects are created as pp_owner, so it needs CREATE on the database, and
-- whoever runs the remaining scripts needs to be able to SET ROLE to it.
GRANT CREATE ON DATABASE pp_rdw TO pp_owner;
GRANT pp_owner TO CURRENT_USER;

-- Reminder: pg_hba.conf names the database, so it needs a matching line, and
-- specific rules must sit above general ones - first match wins, not best.
--   host    pp_rdw    svc_py    192.168.0.6/32    scram-sha-256
-- Then: sudo systemctl reload postgresql@18-main
-- Verify: SELECT * FROM pg_hba_file_rules ORDER BY line_number;
