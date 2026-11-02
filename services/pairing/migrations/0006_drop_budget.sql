-- ADR 0004: no spending tracking. Back up the database before applying (tools/deploy.sh).
DROP TABLE IF EXISTS budget_attempts;
DROP TABLE IF EXISTS budget_quotes;
DROP TABLE IF EXISTS budget_settings;
