#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
archive_path="${1:-$project_dir/build/AgentOne.app.zip}"
smoke_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentone-pi-smoke.XXXXXX")"
responses_path="$smoke_dir/responses.jsonl"

cleanup() {
    rm -rf "$smoke_dir"
}
trap cleanup EXIT

if [[ ! -f "$archive_path" ]]; then
    echo "Packaged app archive not found: $archive_path" >&2
    exit 1
fi

ditto -x -k "$archive_path" "$smoke_dir"
app_path="$smoke_dir/AgentOne.app"
sidecar_path="$app_path/Contents/Resources/AgentOneLifeRuntime/agentone-life-runtime"

plutil -lint "$app_path/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict "$app_path"

printf '%s\n%s\n%s\n' \
  '{"version":1,"id":"10000000-0000-0000-0000-000000000001","type":"health"}' \
  '{"version":1,"id":"10000000-0000-0000-0000-000000000002","type":"wake","payload":{"reason":"drift_reminder_level_2","sanitizedContext":{"capturedAt":"2026-07-21T08:00:00.000Z","applicationName":"Safari","bundleIdentifier":"com.apple.Safari","windowTitle":"Unrelated video","contentSummary":"Watching a video unrelated to the paper","semanticTags":["video","scrolling"],"isSensitive":false,"activeIntent":{"id":"20000000-0000-0000-0000-000000000001","title":"完成论文引言","summary":"整理并写完论文引言"},"driftDurationSeconds":70},"recentMemory":[{"id":"30000000-0000-0000-0000-000000000001","timestamp":"2026-07-21T07:55:00.000Z","kind":"activity","summary":"正在修改论文引言","tags":["user","activity"]}],"budget":{"maxTokens":2400,"maxTurns":3,"maxDurationMs":8000,"allowedTools":["get_current_context","read_recent_diary","append_inner_journal","show_return_card","consume_energy_budget"],"surpriseRisk":"none"}}}' \
  '{"version":1,"id":"10000000-0000-0000-0000-000000000003","type":"shutdown"}' \
  | "$sidecar_path" > "$responses_path"

SMOKE_RESPONSES="$responses_path" node --input-type=module <<'NODE'
import fs from "node:fs";

const responses = fs.readFileSync(process.env.SMOKE_RESPONSES, "utf8")
  .trim()
  .split("\n")
  .map((line) => JSON.parse(line));

const health = responses.find((response) => response.id === "10000000-0000-0000-0000-000000000001");
if (health?.type !== "ready" || health.payload?.runtime !== "pi-agent-core") {
  throw new Error("Pi health handshake did not return the expected ready payload.");
}

const wake = responses.find((response) =>
  response.id === "10000000-0000-0000-0000-000000000002" && response.type === "result"
);
if (!wake) throw new Error("Pi wake did not produce a final result.");

const actionTypes = wake.payload.actions.map((action) => action.type);
for (const required of ["inner_journal", "return_card", "energy_consumed"]) {
  if (!actionTypes.includes(required)) {
    throw new Error(`Pi wake omitted required safe action: ${required}`);
  }
}
if (actionTypes.filter((type) => type === "return_card").length !== 1) {
  throw new Error("Pi wake must propose exactly one return card.");
}
if (actionTypes.includes("curiosity_prompt")) {
  throw new Error("Reminder wake unexpectedly proposed a second curiosity prompt.");
}

const returnCard = wake.payload.actions.find((action) => action.type === "return_card");
if (returnCard.payload?.taskTitle !== "完成论文引言") {
  throw new Error("Return card did not preserve the active task title.");
}
if (wake.payload.usage?.stoppedByBudget !== false) {
  throw new Error("Pi wake exhausted its budget during the smoke scenario.");
}

console.log("AgentOne Pi wake smoke passed");
console.log(`actions: ${actionTypes.join(", ")}`);
console.log(`turns: ${wake.payload.usage.turns}, tool calls: ${wake.payload.usage.toolCalls}`);
NODE
