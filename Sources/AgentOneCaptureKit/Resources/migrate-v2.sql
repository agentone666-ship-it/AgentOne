PRAGMA foreign_keys = OFF;
BEGIN IMMEDIATE;
CREATE TABLE segments_v2 (
  id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
  source TEXT NOT NULL CHECK(source IN ('mixed','system_audio','microphone')),
  started_ms INTEGER NOT NULL, ended_ms INTEGER NOT NULL,
  time_zone TEXT NOT NULL, first_pts REAL NOT NULL, host_anchor REAL NOT NULL,
  clock_mapping TEXT NOT NULL, sample_rate REAL NOT NULL, channels INTEGER NOT NULL,
  relative_path TEXT NOT NULL, sha256 TEXT,
  state TEXT NOT NULL CHECK(state IN ('recording','sealed','incomplete','deleted')),
  place TEXT, context_json TEXT NOT NULL DEFAULT '{}', created_ms INTEGER NOT NULL
);

INSERT INTO segments_v2 SELECT * FROM segments;
DROP TABLE segments;
ALTER TABLE segments_v2 RENAME TO segments;
CREATE INDEX segment_time ON segments(started_ms, ended_ms);
-- Abort before commit if any existing evidence relationship is inconsistent.
CREATE TEMP TABLE mixed_migration_guard (bad_fk_count INTEGER CHECK(bad_fk_count=0));
INSERT INTO mixed_migration_guard SELECT COUNT(*) FROM pragma_foreign_key_check;
DROP TABLE mixed_migration_guard;
UPDATE meta SET value='2' WHERE key='schema_version';
COMMIT;
PRAGMA foreign_keys = ON;
