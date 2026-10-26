# PR #2 capture mode transition fix

## STATUS

Review thread: https://github.com/agentone666-ship-it/Thenvia/pull/2#discussion_r4373697599

Fixed in the PR branch. Validation results and remote merge status are recorded in the PR after checks complete.

## DECISIONS

The current product defaults to continuous preservation (0.2.9), with intelligent triggering still available. Enabling automatic recording must apply the selected strategy to an existing manual session. Selecting intelligent mode must create a fresh waiting gate; selecting preservation must continue saving with annotation-only decisions.

Device starts and stops can suspend on MainActor, so all transitions are serialized. A mode change seals/releases the previous session before creating the next one. Failed transitions propagate and allow a later pause/retry. Repeated starts in the same mode remain idempotent.

## CHANGES

- Added CaptureSessionCoordinator, used by AudioCaptureService.start/stop.
- Rebuild the writer, gate and session token on manual/intelligent/preservation transitions.
- Reconcile settings changed while device startup awaits before publishing UI success.
- Strategy changes use the same service transition path.
- README conflict was already resolved in 19094ca, preserving Thenvia branding and continuous-preservation guidance.

## TESTS

Added regression coverage using temporary SQLite and real mixed AAC encoding: manual recording seals successfully, intelligent mode begins waiting, quiet PCM creates no additional segment/job, and the intentional waiting gap is recorded. Also cover a mode change and pause queued behind an unfinished start, failed-start recovery, and same-mode idempotency. No personal audio or Memory database is used.

Full Swift, Runtime/MCP, integration and signed-package checks are run before merge. These tests do not claim a physical-device mode-switch acceptance run or model accuracy improvement.

## HANDOFF

No app installation, release publication or deployment is part of this fix. Existing local user data and unrelated brand/GTM work stay outside this change.
