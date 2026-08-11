#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
runtime_dir="$project_dir/AgentOneLifeRuntime"

resolve_tsc() {
    if [[ -n "${AGENTONE_TSC_PATH:-}" && -f "$AGENTONE_TSC_PATH" ]]; then
        echo "$AGENTONE_TSC_PATH"
        return
    fi

    if [[ -x "$runtime_dir/node_modules/.bin/tsc" ]]; then
        echo "$runtime_dir/node_modules/.bin/tsc"
        return
    fi

    if [[ -f "$runtime_dir/node_modules/typescript/bin/tsc" ]]; then
        echo "$runtime_dir/node_modules/typescript/bin/tsc"
        return
    fi

    if command -v tsc >/dev/null 2>&1; then
        command -v tsc
        return
    fi

    echo "TypeScript compiler not found. Run npm ci in AgentOneLifeRuntime or set AGENTONE_TSC_PATH." >&2
    return 1
}

tsc_path="$(resolve_tsc)"

echo "[1/10] Compile the production Pi JSONL sidecar"
"$tsc_path" -p "$runtime_dir/tsconfig.json"

echo "[2/10] Compile and run TypeScript unit + black-box process tests"
"$tsc_path" -p "$runtime_dir/tsconfig.test.json"
node --test "$runtime_dir/dist-test/test/"*.test.js

echo "[3/10] Build Swift debug targets"
swift build --package-path "$project_dir"

echo "[4/10] Run the Context/Memory production harness"
swift run --package-path "$project_dir" AgentOneCoreHarness

echo "[5/10] Run the OpenAI-compatible model interface harness"
swift run --package-path "$project_dir" AgentOneModelRuntimeHarness

echo "[6/10] Run the production PiSidecarBridge integration harness"
swift run --package-path "$project_dir" AgentOnePiIntegrationHarness

echo "[7/10] Run the Kimi device OAuth interface + localhost process harness"
swift run --package-path "$project_dir" AgentOneOAuthHarness

echo "[8/10] Run the macOS credential-store interface harness"
swift run --package-path "$project_dir" AgentOneCredentialHarness

echo "[9/10] Build the signed Release ZIP with its embedded sidecar"
"$script_dir/build_app.sh" release >/dev/null

echo "[10/10] Run black-box protocol E2E against the packaged sidecar"
node "$script_dir/test_packaged_pi_runtime.mjs" "$project_dir/build/AgentOne.app.zip"

echo "AgentOne full interface-level E2E suite passed"
