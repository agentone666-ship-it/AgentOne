#!/usr/bin/env bash
# Shared local/Actions gates. Install with npm ci first.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

runtime() {
    npm --prefix AgentOneLifeRuntime test
    node plugins/personal-context-memory/test.mjs
    node --test plugins/agentone-memory/test.mjs
}

swift_tests() {
    swift build
    swift test
}

integration() {
    npm --prefix AgentOneLifeRuntime run build
    swift build
    for harness in AgentOneCoreHarness AgentOneModelRuntimeHarness AgentOnePiIntegrationHarness AgentOneOAuthHarness AgentOneCredentialHarness; do
        swift run --skip-build "$harness"
    done
    fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentone-audio-ci.XXXXXX")"
    swift run --skip-build AgentOneAudioHarness --home "$fixture_dir"
    node scripts/test_capture_interop.mjs "$fixture_dir"
}

package() {
    ./scripts/build_app.sh release
    node scripts/test_packaged_capture.mjs build/AgentOne.app.zip
    (cd build && shasum -a 256 AgentOne.app.zip > SHA256SUMS)
}

case "${1:-all}" in
    runtime) runtime ;;
    swift) swift_tests ;;
    integration) integration ;;
    package) package ;;
    all) runtime; swift_tests; integration; package ;;
    *) echo "Usage: $0 [runtime|swift|integration|package|all]" >&2; exit 2 ;;
esac
