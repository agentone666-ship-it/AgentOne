#!/bin/zsh
set -eu

# Keep Codex Desktop's local sidebar catalog aligned with the provider-agnostic
# thread database. Authentication and API-provider configuration are untouched.
CODEX_DATA_DIR="${CODEX_HOME:-$HOME/.codex}"
THREAD_DB="$CODEX_DATA_DIR/state_5.sqlite"
CATALOG_DB="$CODEX_DATA_DIR/sqlite/codex-dev.db"
LOCK_DIR="$CODEX_DATA_DIR/.session-catalog-sync.lock"

[[ -f "$THREAD_DB" && -f "$CATALOG_DB" ]] || exit 0
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

CHANGES="$(sqlite3 "$CATALOG_DB" <<SQL
.timeout 10000
ATTACH DATABASE '$THREAD_DB' AS thread_state;
SELECT
  (SELECT count(*)
   FROM thread_state.threads AS t
   LEFT JOIN local_thread_catalog AS c
     ON c.host_id = 'local' AND c.thread_id = t.id
   WHERE t.archived = 0 AND t.rollout_path <> ''
     AND (
       c.thread_id IS NULL
       OR c.display_title <> CASE
         WHEN trim(t.title) <> '' THEN t.title
         WHEN trim(t.first_user_message) <> '' THEN t.first_user_message
         ELSE 'Untitled task'
       END
       OR c.source_updated_at <> COALESCE(t.updated_at_ms / 1000.0, t.updated_at)
       OR c.cwd <> t.cwd
       OR c.model_provider <> t.model_provider
       OR c.missing_candidate <> 0
     ))
  +
  (SELECT count(*)
   FROM local_thread_catalog AS c
   JOIN thread_state.threads AS t ON t.id = c.thread_id
   WHERE c.host_id = 'local' AND t.archived <> 0);
DETACH DATABASE thread_state;
SQL
)"
[[ "${CHANGES:-0}" -eq 0 ]] && exit 0

sqlite3 "$CATALOG_DB" <<SQL
.timeout 10000
ATTACH DATABASE '$THREAD_DB' AS thread_state;
BEGIN IMMEDIATE;

INSERT INTO local_thread_catalog (
  host_id,
  thread_id,
  display_title,
  source_created_at,
  source_updated_at,
  cwd,
  source_kind,
  source_detail,
  model_provider,
  git_branch,
  observation_sequence,
  missing_candidate
)
SELECT
  'local',
  t.id,
  CASE
    WHEN trim(t.title) <> '' THEN t.title
    WHEN trim(t.first_user_message) <> '' THEN t.first_user_message
    ELSE 'Untitled task'
  END,
  COALESCE(t.created_at_ms / 1000.0, t.created_at),
  COALESCE(t.updated_at_ms / 1000.0, t.updated_at),
  t.cwd,
  CASE WHEN trim(t.source) <> '' THEN t.source ELSE 'user' END,
  NULL,
  t.model_provider,
  t.git_branch,
  COALESCE((SELECT max(observation_sequence) FROM local_thread_catalog), 0)
    + row_number() OVER (ORDER BY t.updated_at, t.id),
  0
FROM thread_state.threads AS t
WHERE t.archived = 0
  AND t.rollout_path <> ''
ON CONFLICT(host_id, thread_id) DO UPDATE SET
  display_title = excluded.display_title,
  source_created_at = excluded.source_created_at,
  source_updated_at = excluded.source_updated_at,
  cwd = excluded.cwd,
  source_kind = excluded.source_kind,
  model_provider = excluded.model_provider,
  git_branch = excluded.git_branch,
  missing_candidate = 0;

DELETE FROM local_thread_catalog
WHERE host_id = 'local'
  AND thread_id IN (
    SELECT id FROM thread_state.threads WHERE archived <> 0
  );

UPDATE local_thread_catalog_metadata
SET catalog_revision = catalog_revision + 1
WHERE id = 1;

INSERT INTO local_thread_catalog_sync_state (
  host_id, watermark_updated_at, initial_build_complete,
  observation_sequence, last_full_reconciled_at
)
VALUES (
  'local',
  (SELECT max(COALESCE(updated_at_ms / 1000.0, updated_at)) FROM thread_state.threads),
  1,
  (SELECT COALESCE(max(observation_sequence), 0) FROM local_thread_catalog),
  unixepoch()
)
ON CONFLICT(host_id) DO UPDATE SET
  watermark_updated_at = excluded.watermark_updated_at,
  initial_build_complete = 1,
  observation_sequence = excluded.observation_sequence,
  last_full_reconciled_at = excluded.last_full_reconciled_at;

COMMIT;
DETACH DATABASE thread_state;
SQL
