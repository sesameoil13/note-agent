CREATE TABLE budget_settings (id INTEGER PRIMARY KEY CHECK(id=1), limit_cny INTEGER NOT NULL CHECK(limit_cny BETWEEN 1 AND 30000000));
INSERT INTO budget_settings VALUES (1,30000000);
CREATE TABLE budget_quotes (id TEXT PRIMARY KEY, payload TEXT NOT NULL, expires_at INTEGER NOT NULL);
CREATE TABLE budget_attempts (
 id TEXT PRIMARY KEY, operation_id TEXT NOT NULL, device_id TEXT NOT NULL REFERENCES devices(id),
 month TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('reserved','sent','uncertain','settled','released')),
 reserve_cny INTEGER NOT NULL, actual_cny INTEGER, usd_nanos INTEGER, generation_id TEXT,
 quote_id TEXT NOT NULL REFERENCES budget_quotes(id), created_at INTEGER NOT NULL, disputed INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX budget_month ON budget_attempts(month,state);
CREATE INDEX budget_holds ON budget_attempts(state);
CREATE UNIQUE INDEX budget_generation ON budget_attempts(generation_id) WHERE generation_id IS NOT NULL;
