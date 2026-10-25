CREATE TABLE devices (id TEXT PRIMARY KEY, name TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE, role TEXT NOT NULL CHECK(role IN ('owner','member')), created_at INTEGER NOT NULL);
CREATE UNIQUE INDEX one_owner ON devices(role) WHERE role = 'owner';
CREATE TABLE request_limits (bucket TEXT PRIMARY KEY, hits INTEGER NOT NULL, expires_at INTEGER NOT NULL);
CREATE INDEX limit_expiry ON request_limits(expires_at);
CREATE TABLE pairs (id TEXT PRIMARY KEY, owner_id TEXT NOT NULL REFERENCES devices(id), claim_hash TEXT NOT NULL, expires_at INTEGER NOT NULL, status TEXT NOT NULL CHECK(status IN ('open','claimed','approved','completed','rejected','expired')), device_id TEXT, device_name TEXT, token_hash TEXT, ciphertext TEXT);
CREATE INDEX pair_expiry ON pairs(expires_at);
CREATE UNIQUE INDEX one_active_pair ON pairs(owner_id) WHERE status IN ('open','claimed','approved');
