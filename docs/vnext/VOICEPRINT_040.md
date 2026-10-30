# Owner voice tagging — 0.4.0

## Behavior

Settings offers explicit local component installation, a 30-second microphone enrollment, early completion/cancel, and profile removal. Enrollment needs at least 12 seconds of clear voice and consistent embeddings; it does not choose an identity from historical mixed recordings. A reading prompt is included. Successful enrollment keeps an embedding, not the separate temporary enrollment WAV. Ordinary recording remains governed by the existing capture preferences.

Sealed audio is independently decoded to mono 16 kHz PCM and compared locally, including sources whose ASR was empty. VAD selects voiced three-second windows with a 1.5-second stride. Consecutive strong similarities mark detected owner voice; low scores require sufficient speech before reporting not detected. Short, mixed, failed or borderline evidence remains uncertain. Scores are cosine similarities, not calibrated probabilities. Defaults require real-user calibration before any accuracy claim.

Conversation aggregation preserves pending/uncertain states and real recording gaps. A detected voice can occur in a replay or remote call; it is not proof of physical attendance. Nothing is automatically deleted or excluded from recording. Users may filter, keep, or explicitly confirm deletion of a conversation's source recordings. Shared source recordings can affect other conversations; the confirmation explains this. A changed conversation digest invalidates a pending deletion confirmation.

## Storage and privacy

Profiles live under Memory/Voiceprint/owner.json, with a private directory and file permissions. Model/runtime files live under the user's local Application Support/AgentOne/Voiceprint. Installation downloads dependencies and model weights; recognition has no upload/network path. Removing a profile removes its comparison labels; original recordings remain. Profile generation and source hashes invalidate old results. MCP exposes a conservative owner_voice status, never embeddings. No profile has been created for the real user during development.

## Model and runtime

The worker uses [sherpa-onnx speaker embedding APIs](https://k2-fsa.github.io/sherpa/onnx/speaker-identification/) and the released 3D-Speaker ERes2Net base Chinese 16 kHz ONNX model. Packages are pinned to sherpa-onnx 2.0.1 and numpy 2.2.6; Python 3.10+ is required for installation. Model hashes are recorded on explicit installation and checked during inference. Speaker model SHA-256 observed in local validation: `1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b`.

## Validation and limits

Native tests cover profile/source invalidation, pending and gap handling, manual retention/deletion, stale deletion refusal, and real PCM-to-WAV conversion. Python tests cover positive, negative, borderline and short evidence policy. MCP tests cover profile-scoped labels and no automatic deletion or embedding export. Packaging validates all three worker/setup/policy resources.

Actual local model inference used only synthetic speech fixtures: one registered synthetic voice spoken with different text scored 0.947 and was detected; another synthetic voice scored 0.425 and stayed uncertain rather than being marked as the owner. Silent audio produced uncertain with no matching spans. These are processing-chain checks, not measured accuracy for the real user, noisy mixtures or replay attacks. User enrollment and real positive/negative examples remain necessary. No human reference voice was inferred or registered automatically.

Development and acceptance use background commands, files, logs and tests. Do not automatically open windows or record a real enrollment to finish validation.
