# PR #3 Pi 1.4 API migration

## STATUS

The dependency upgrade is retained at 1.4.0. Callers are migrated together with the lockfile update, rather than bypassing compilation failures. Remote check/merge results are recorded in the PR after validation.

Review: https://github.com/agentone666-ship-it/Thenvia/pull/3#pullrequestreview-5646998372

## DECISIONS / CHANGES

- Removed global getModel/registerApiProvider/registerFauxProvider usage. Bind explicit concrete API streams via the exported api/* paths and give every Agent its required streamFn.
- Offline runs own a createFauxCore instance, so simultaneous/repeated requests do not share global scripted responses.
- Preserve the existing tested Kimi OAuth Anthropic Messages endpoint/auth/device-header contract using an explicit model definition. The 1.4 catalog's switch to Kimi Chat Completions is a separate integration migration, not silently inherited here.
- Pi 1.x carries prompts and tools in system transcript messages. Preserve those messages during trimming/conversion, replay tool additions/removals, and render system sections for non-streaming gateways.
- Emit start before done on successful non-streaming requests, as required by the new event protocol.
- The upgraded Anthropic SDK adds beta=true to the request URL. The local HTTP mock routes by pathname and asserts the full new request URL.

Official API reference: https://github.com/earendil-works/pi/blob/v1.4.0/packages/agent/README.md. Exact exported types were also checked against the installed 1.4.0 package.

## TESTS

Local npm ci and shared Runtime/MCP checks passed: 58 Runtime tests and the cross-month Memory MCP protocol check. Production dependency audit found 0 vulnerabilities. Required remote Node 22.19.0/24 + macOS tests/integration/package gates remain required before merge. Added regressions verify system prompt/tool preservation after history trimming and actual non-streaming HTTP replay of sections and tool removals/additions. Existing subprocess HTTP tests retain assertions for Kimi OAuth precedence, device identity, tool result round trips, JSON output and error/credential sanitization.

HTTP tests use local mocks and synthetic inputs. They do not claim live provider/account validation. The default capture app still excludes the independent legacy Agent runtime.

## PACKAGING BOUNDARY

The first remote run on the pre-#2 base passed Node and macOS Swift/integration gates but failed the old compiled Deno sidecar Kimi smoke test with a runtime-compatibility error before HTTP dispatch (run 40267384562). After #2 merged, this branch was synchronized to main. The current product deliberately packages CaptureKit and the generic MCP plugin only; its package test explicitly excludes the legacy runtime. This PR changes no workflow or packaging gate relative to current main. The old compiled Deno sidecar is not validated or shipped by the current product. Legacy Node-based protocol/integration regression checks remain required.

## HANDOFF

No personal recordings, location, credentials, app installation, release publication or deployment are part of this change. No CI gate is weakened.
