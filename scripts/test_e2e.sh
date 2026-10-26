#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
# Compatibility entrypoint; package validation now targets capture + MCP.
exec bash "$script_dir/ci.sh" all
