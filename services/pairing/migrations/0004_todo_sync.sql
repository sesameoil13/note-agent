CREATE TABLE todo_states (action_key TEXT PRIMARY KEY, note_id TEXT NOT NULL, action_id TEXT NOT NULL, payload TEXT NOT NULL, version INTEGER NOT NULL, seq INTEGER NOT NULL);
CREATE UNIQUE INDEX todo_state_seq ON todo_states(seq);
CREATE TABLE todo_ops (id TEXT PRIMARY KEY, action_key TEXT NOT NULL, device_id TEXT NOT NULL REFERENCES devices(id), received_at INTEGER NOT NULL);
