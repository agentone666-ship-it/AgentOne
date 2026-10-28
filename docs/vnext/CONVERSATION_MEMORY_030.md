# Whole-conversation memory — 0.3.0

## STATUS

Implemented whole-discussion organization, continuous derived playback and bounded native transcription. Packaging and installed-app validation are tracked below. A minute-long storage chunk is not a conversation. Summarization belongs to the current user-authorized Codex task.

## DECISIONS

- Preserve the installed 0.2.11 recorder/recovery behavior by basing this work on codex/capture-input-recovery, including merged main. Do not overwrite the shared recovery checkout.
- Native recording continues under the existing recording and privacy preferences. Conversation grouping does not wait for a model before retaining audio.
- Group recognized speech across adjacent storage chunks with a three-minute pause allowance. No speaker identity or automatic proof of an in-person meeting is inferred. Audio gaps remain explicit.
- Show whole conversations first; retain original chunks as evidence. Export whole playback with the original time mapping rather than concatenating AAC padding.
- The user clarified that summarization belongs to this Codex task, not the product. Add no summary model configuration, summary queue or summary storage to the product. MCP exposes whole-scene source evidence for the host to read in an authorized task.
- Fix native ASR truncation with bounded overlapping recognition windows and timestamp-aware transcript reconciliation. Keep source audio unchanged; old results remain versioned evidence.

## CHANGES

- Add source-backed conversations and ordered membership to the existing additive v2 schema. Pending transcripts, source gaps and superseded groups remain explicit. Preserve complete boundary chunks even when old ASR retained only their tails.
- Default recall to discussion cards with continuous playback and a whole transcript. Original storage chunks remain available. Old Apple transcripts can be queued for versioned re-transcription.
- Export derived M4A using absolute source timestamps; verify source hashes before export, recheck source state afterward, validate readable media and retain only the latest derived export. Preserve missing time as silence. Deleting a source invalidates its discussion and removes derived playback.
- Decode each source sequentially, then recognize overlapping 24-second PCM windows with a 22-second stride. Reconcile rolling partial/final snapshots and overlap timestamps instead of accepting only a minute's final recognition snapshot.
- Expose read-only `list_conversations` and paginated `get_conversation_evidence` through the existing MCP/plugin. Require all evidence pages for whole-discussion interpretation. Ship no additional Agent runtime or summary service.

## TESTS

- Full Swift suite: 162 tests passed before the final boundary-retention regression; all 8 conversation/window tests passed afterward.
- Runtime retry: 58 tests passed; MCP: 24 tests passed; recall benchmark: 18/18 main, 12/12 holdout, 6/6 adversarial scenarios. The first runtime run encountered sidecar startup timeouts during very high machine load; rerunning passed without changing those tests.
- Native real AAC fixture -> whole conversation -> readable 2-second M4A -> paginated MCP evidence passed. Source transcript fixture text is synthetic and does not prove real speech quality.
- New export regression also checks nonzero decoded energy on both sides of the original source-file boundary. PCM crash recovery preserved 96,000 frames.
- Real-audio check from a temporary signed bundle was rejected by Speech authorization. No permission changes or cloud fallback were attempted. Installed-app ASR acceptance remains necessary before claiming the truncation is fixed on real recordings.

## HANDOFF

No personal audio or transcript is committed. No cloud audio transmission, permissions expansion or independent Agent runtime is introduced. The user explicitly excluded a product summarization feature.

Grouping currently uses recognized speech and a three-minute pause allowance. It does not identify people or topics; music/video voices may group together, and missing ASR can change boundaries. Existing incomplete recordings cannot be reconstructed by grouping. Historical no-speech classifications alone are not proof of silence.
