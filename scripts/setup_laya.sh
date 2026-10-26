#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_dir="$HOME/Library/Application Support/AgentOne/Laya"
mkdir -p "$runtime_dir"
chmod 700 "$runtime_dir"
cp "$project_dir/tools/laya-decision/worker.py" "$runtime_dir/laya-worker.py"
cp "$project_dir/tools/laya-decision/pyproject.toml" "$project_dir/tools/laya-decision/uv.lock" "$runtime_dir/"
uv sync --project "$runtime_dir" --frozen --no-dev --python 3.12
# Only the multilingual checkpoint is loaded. Subsequent launches use this local cache.
HF_HOME="$runtime_dir/cache" USE_TF=0 "$runtime_dir/.venv/bin/python" "$project_dir/tools/laya-decision/worker.py" </dev/null
