PRAGMA busy_timeout = 5000;
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT OR IGNORE INTO meta VALUES ('schema_version', '2');
CREATE TABLE IF NOT EXISTS segments (
  id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
  source TEXT NOT NULL CHECK(source IN ('mixed','system_audio','microphone')),
  started_ms INTEGER NOT NULL, ended_ms INTEGER NOT NULL,
  time_zone TEXT NOT NULL, first_pts REAL NOT NULL, host_anchor REAL NOT NULL,
  clock_mapping TEXT NOT NULL, sample_rate REAL NOT NULL, channels INTEGER NOT NULL,
  relative_path TEXT NOT NULL, sha256 TEXT,
  state TEXT NOT NULL CHECK(state IN ('recording','sealed','incomplete','deleted')),
  place TEXT, context_json TEXT NOT NULL DEFAULT '{}', created_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS segment_time ON segments(started_ms, ended_ms);
CREATE TABLE IF NOT EXISTS transcripts (
  segment_id TEXT NOT NULL REFERENCES segments(id), revision INTEGER NOT NULL,
  text TEXT NOT NULL, utterances_json TEXT NOT NULL, status TEXT NOT NULL,
  engine TEXT NOT NULL, created_ms INTEGER NOT NULL,
  PRIMARY KEY(segment_id, revision)
);
CREATE TABLE IF NOT EXISTS analyses (
  segment_id TEXT NOT NULL REFERENCES segments(id), revision INTEGER NOT NULL,
  transcript_revision INTEGER NOT NULL, payload_json TEXT NOT NULL, created_ms INTEGER NOT NULL,
  PRIMARY KEY(segment_id, revision)
);
CREATE TABLE IF NOT EXISTS jobs (
  id TEXT PRIMARY KEY, segment_id TEXT NOT NULL REFERENCES segments(id),
  stage TEXT NOT NULL CHECK(stage IN ('transcribe','analyze')),
  source_hash TEXT NOT NULL, input_revision INTEGER NOT NULL DEFAULT 0,
  state TEXT NOT NULL CHECK(state IN ('pending','leased','succeeded','cancelled')),
  lease_token TEXT, lease_owner TEXT, lease_until_ms INTEGER,
  attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT,
  created_ms INTEGER NOT NULL, updated_ms INTEGER NOT NULL, result_digest TEXT,
  UNIQUE(segment_id, stage, source_hash, input_revision)
);
CREATE INDEX IF NOT EXISTS job_pending ON jobs(state, stage, created_ms);
CREATE TABLE IF NOT EXISTS coverage (
  id TEXT PRIMARY KEY, started_ms INTEGER NOT NULL, ended_ms INTEGER,
  source TEXT NOT NULL, reason TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS corrections (
  id TEXT PRIMARY KEY, segment_id TEXT NOT NULL REFERENCES segments(id),
  kind TEXT NOT NULL, payload_json TEXT NOT NULL, created_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS capture_state (
  singleton INTEGER PRIMARY KEY CHECK(singleton=1), state TEXT NOT NULL,
  detail TEXT NOT NULL, heartbeat_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS memories (
  id TEXT PRIMARY KEY, kind TEXT NOT NULL, title TEXT NOT NULL, text TEXT NOT NULL,
  entities_json TEXT NOT NULL, epistemic_status TEXT NOT NULL,
  valid_from_ms INTEGER, valid_until_ms INTEGER, supersedes_json TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('active','superseded','invalidated')),
  input_digest TEXT UNIQUE NOT NULL, created_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS memory_evidence (
  memory_id TEXT NOT NULL REFERENCES memories(id), segment_id TEXT NOT NULL REFERENCES segments(id),
  source_hash TEXT NOT NULL, transcript_revision INTEGER NOT NULL,
  start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL, quote TEXT NOT NULL,
  PRIMARY KEY(memory_id,segment_id,start_ms,end_ms)
);
CREATE INDEX IF NOT EXISTS memory_source ON memory_evidence(segment_id);
-- Additive v1 extension: original Diary files remain immutable sources.
CREATE TABLE IF NOT EXISTS context_events (
 id TEXT PRIMARY KEY, started_ms INTEGER NOT NULL, ended_ms INTEGER NOT NULL,
 kind TEXT NOT NULL, application TEXT, title TEXT, url TEXT, text TEXT NOT NULL,
 place TEXT, provenance TEXT NOT NULL, source_ref TEXT NOT NULL, source_sha256 TEXT NOT NULL,
 hidden INTEGER NOT NULL DEFAULT 0, created_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS event_time ON context_events(started_ms,ended_ms);
CREATE TABLE IF NOT EXISTS event_import_state (source_ref TEXT PRIMARY KEY, sha256 TEXT NOT NULL, synced_ms INTEGER NOT NULL);

-- Logical discussions span immutable physical audio chunks. Additive schema v2 extension.
CREATE TABLE IF NOT EXISTS conversations (
 id TEXT PRIMARY KEY, started_ms INTEGER NOT NULL, ended_ms INTEGER NOT NULL,
 last_speech_ms INTEGER NOT NULL, state TEXT NOT NULL,
 input_digest TEXT NOT NULL, preview_text TEXT NOT NULL, transcript_text TEXT NOT NULL,
 segment_count INTEGER NOT NULL, pending_count INTEGER NOT NULL,
 missing_ms INTEGER NOT NULL, updated_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS conversation_segments (
 conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
 segment_id TEXT NOT NULL REFERENCES segments(id), source_hash TEXT NOT NULL,
 transcript_revision INTEGER NOT NULL, ordinal INTEGER NOT NULL,
 PRIMARY KEY(conversation_id,segment_id)
);

-- Optional owner voice verification; embeddings remain in a private local file.
CREATE TABLE IF NOT EXISTS voice_matches (
 segment_id TEXT NOT NULL REFERENCES segments(id), profile_id TEXT NOT NULL,
 source_hash TEXT NOT NULL, status TEXT NOT NULL, score REAL, intervals_json TEXT NOT NULL,
 created_ms INTEGER NOT NULL, PRIMARY KEY(segment_id,profile_id)
);
CREATE TABLE IF NOT EXISTS conversation_choices (
 conversation_id TEXT PRIMARY KEY REFERENCES conversations(id), choice TEXT NOT NULL, updated_ms INTEGER NOT NULL
);
