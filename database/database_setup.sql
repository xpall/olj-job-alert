-- OLJAlerts Database Setup Script

-- === Initial Setup ===

-- Create user
CREATE USER job_alert_client WITH PASSWORD 'job_alert_client_password' LOGIN;

-- Create database
CREATE DATABASE oljalerts OWNER job_alert_client;

-- Connect to database
\c oljalerts

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE oljalerts TO job_alert_client;
GRANT ALL ON SCHEMA public TO job_alert_client;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO job_alert_client;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO job_alert_client;

-- Create tables
CREATE TABLE job_postings (
  id               SERIAL PRIMARY KEY,
  job_id           BIGINT NOT NULL UNIQUE,
  job_title        TEXT,
  job_description  TEXT,
  job_skills       TEXT,
  type_of_work     TEXT,
  compensation     TEXT,
  hours_per_week   TEXT,
  job_date         DATE,
  created_at       TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE user_subscriptions (
  id          SERIAL PRIMARY KEY,
  chat_id     BIGINT NOT NULL,
  keyword     TEXT NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(chat_id, keyword)
);

-- Create indexes
CREATE INDEX idx_job_postings_job_id ON job_postings(job_id);
CREATE INDEX idx_job_postings_created_at ON job_postings(created_at DESC);
CREATE INDEX idx_user_subscriptions_chat_id_keyword ON user_subscriptions(chat_id, keyword);


-- === Permission Fix (if tables owned by postgres) ===

-- Transfer ownership
ALTER TABLE job_postings OWNER TO job_alert_client;
ALTER TABLE user_subscriptions OWNER TO job_alert_client;

-- Grant all on existing tables and sequences
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO job_alert_client;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO job_alert_client;


-- === Verification ===

-- Check tables and ownership
SELECT tablename, tableowner 
FROM pg_tables 
WHERE schemaname = 'public' 
AND tablename IN ('job_postings', 'user_subscriptions');

\dt
\du


-- === Connection String for n8n ===
-- postgresql://job_alert_client:job_alert_client_password@localhost:5432/oljalerts
