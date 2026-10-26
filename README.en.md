<p align="center">
  <img src="docs/brand/hero.png" alt="Thenvia 留境 — Context carried forward." width="820" />
</p>

<div align="center">

**Give your agent the context of what happened.**

Local-first personal context memory for your AI agent.

[![CI](https://github.com/agentone666-ship-it/Thenvia/actions/workflows/ci.yml/badge.svg)](https://github.com/agentone666-ship-it/Thenvia/actions/workflows/ci.yml)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-101715)
![Development preview](https://img.shields.io/badge/status-development_preview-98D8C0?labelColor=101715)

[Try the preview](#try-the-preview) · [Connect your agent](#connect-your-agent) · [简体中文](README.md)

</div>

> “Find the conversation about that requirement this morning, and help me take the next step.”

Thenvia, formerly AgentOne, keeps permitted audio and desktop activity locally so your agent can retrieve what happened, check the source, and continue the work. A native macOS notch panel keeps capture status and controls close at hand.

> **Development preview:** the new app lives on [`codex/audio-memory-mvp`](https://github.com/agentone666-ship-it/Thenvia/tree/codex/audio-memory-mvp), tracked in [PR #2](https://github.com/agentone666-ship-it/Thenvia/pull/2). The app on `main` is still the previous implementation. Setup below checks out the preview branch. Existing `AgentOne` app, configuration and data identifiers remain compatible.

## Capture context. Check the source. Continue the work.

- **Capture:** mix system audio and microphone input into one segmented recording, with timestamps, desktop events and optional system location.
- **Recall:** let your agent search clues, inspect transcripts and surrounding context, and verify the original audio.
- **Continue:** prepare grounded task handoffs or update long-term memory with source references. Your existing agent handles authorized actions.

<p align="center">
  <img src="docs/images/island-record.png" alt="Native notch capture controls with synthetic demo data" width="48%" />
  <img src="docs/images/island-recall.png" alt="Audio recall with transcript and source playback, synthetic demo data" width="48%" />
</p>

These previews render native UI with synthetic data. They contain no private recordings or location. A screenshot does not demonstrate a completed agent workflow.

## Try the preview

Requires **macOS 15+, Swift 6.1+**, and **Node.js 22.19+** for the plugin/MCP server. Build from source; there is no formal release yet.

```bash
git clone --branch codex/audio-memory-mvp https://github.com/agentone666-ship-it/Thenvia.git
cd Thenvia
swift run AgentOne
```

1. Grant system-audio and microphone permissions, then check input status in the notch panel. Version 0.2.9 preserves mixed audio continuously by default; Laya annotates and splits it without gating preservation. Smart triggering remains optional and may miss conversations.
2. Enable on-device transcription in Settings and record a short permitted test statement.
3. Wait for the segment to seal and transcription to finish. Search a phrase in Recall, play the source, and confirm it matches.

Segments are approximately 60 seconds. Listening, pauses and interruptions can leave coverage gaps. Local model setup and packaging instructions are in the [Chinese setup guide](docs/GETTING_STARTED.md); commands are provided in full.

## Connect your agent

In **Settings → Connect Agent**, export a local plugin containing memory tools and the recall workflow, or copy the configuration into a host supporting local stdio MCP. You can also run:

```bash
node scripts/print_mcp_config.mjs
```

Ask your agent: “Find my recent test statement and show its quote and recording source.”

The exported plugin does not include your recording database. A service self-check is separate from an actual host connection. Installing a plugin cannot make a closed host run background analysis. [Plugin and MCP reference](https://github.com/agentone666-ship-it/Thenvia/blob/codex/audio-memory-mvp/plugins/agentone-memory/README.md)

## Your data and controls

Recordings, indexes and memory stay on your device by default; no Thenvia cloud account is required. Pause capture, control lock-screen behavior, enable local transcription, and separately permit raw-audio access.

System location is optional and permission-based. Unavailable fixes stay unknown; a coordinate does not identify a desk, room or speaker. Your connected agent may send the information it reads to a cloud model. [Privacy and data handling](https://github.com/agentone666-ship-it/Thenvia/blob/codex/audio-memory-mvp/docs/PRIVACY.md)

## Project status

The preview includes mixed capture, audio-activity gating, event import, optional local transcription, plugin export and source verification, with scoped checks. All-day reliability, real-conversation retrieval quality, and a complete retrieval-to-action workflow in a specific host still need validation.

Retrieval currently uses lexical matching and host-supplied query expansion. Reliable speaker identification is not implemented. Memory updates retain references and replacement relationships for later review.

[Roadmap](docs/ROADMAP.md) · [Implementation status](https://github.com/agentone666-ship-it/Thenvia/blob/codex/audio-memory-mvp/docs/vnext/STATUS_CAPTURE_MEMORY.md) · [Recall benchmark](https://github.com/agentone666-ship-it/Thenvia/blob/codex/audio-memory-mvp/benchmarks/recall/README.md)

## Get involved

[Share feedback](https://github.com/agentone666-ship-it/Thenvia/issues/new?template=experience.yml) · [Report a bug](https://github.com/agentone666-ship-it/Thenvia/issues/new?template=bug_report.yml) · [Suggest a scenario](https://github.com/agentone666-ship-it/Thenvia/issues/new?template=feature_request.yml)

Use synthetic examples or redacted descriptions. Do not upload private audio, transcripts, locations, or work material.

[Contributing](CONTRIBUTING.md) · [CI/CD](docs/CI_CD.md) · [Brand assets](docs/BRAND.md) · [Security](SECURITY.md)

No open-source license has been granted for this repository.
