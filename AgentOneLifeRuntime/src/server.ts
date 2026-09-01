import { createInterface } from "node:readline";
import {
  runChat,
  runWake,
  RuntimePolicyError,
  runtimeModelConfigurationFromEnvironment,
  type RuntimeModelConfiguration,
} from "./life-agent.js";
import {
  parseRequest,
  protocolVersion,
  safeToolNames,
  type RuntimeResponse,
} from "./protocol.js";

export const piAgentCoreVersion = "0.75.5";

export async function handleLine(
  line: string,
  write: (response: RuntimeResponse) => void,
  modelConfiguration: RuntimeModelConfiguration = runtimeModelConfigurationFromEnvironment(),
): Promise<"continue" | "shutdown"> {
  let requestID = "unknown";
  try {
    const request = parseRequest(line);
    requestID = request.id;
    if (request.type === "health") {
      write({
        version: protocolVersion,
        id: request.id,
        type: "ready",
        payload: {
          runtime: "pi-agent-core",
          runtimeMode: modelConfiguration.route === "offline" ? "offline-faux" : modelConfiguration.route,
          provider: modelConfiguration.provider,
          model: modelConfiguration.model,
          piVersion: piAgentCoreVersion,
          protocolVersion,
          safeTools: safeToolNames,
        },
      });
      return "continue";
    }
    if (request.type === "shutdown") {
      write({
        version: protocolVersion,
        id: request.id,
        type: "result",
        payload: {
          outcome: "shutdown",
          actions: [],
          usage: { turns: 0, inputTokens: 0, outputTokens: 0, totalTokens: 0, toolCalls: 0, durationMs: 0, stoppedByBudget: false },
          model: {
            route: modelConfiguration.route,
            provider: modelConfiguration.provider,
            model: modelConfiguration.model,
          },
        },
      });
      return "shutdown";
    }

    const execute = request.type === "chat" ? runChat : runWake;
    const result = await execute(request.payload as never, modelConfiguration, (event) => write({
      version: protocolVersion,
      id: request.id,
      type: "event",
      payload: event,
    }));
    write({ version: protocolVersion, id: request.id, type: "result", payload: result });
    return "continue";
  } catch (error) {
    write({
      version: protocolVersion,
      id: requestID,
      type: "error",
      payload: {
        code: error instanceof RuntimePolicyError ? error.code : "invalid_request",
        message: error instanceof Error ? error.message : String(error),
        retryable: error instanceof RuntimePolicyError && error.code === "model_request_failed",
      },
    });
    return "continue";
  }
}

export async function runStdioServer(): Promise<void> {
  const modelConfiguration = runtimeModelConfigurationFromEnvironment();
  const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
  const write = (response: RuntimeResponse) => process.stdout.write(`${JSON.stringify(response)}\n`);

  for await (const line of lines) {
    if (!line.trim()) continue;
    const outcome = await handleLine(line, write, modelConfiguration);
    if (outcome === "shutdown") {
      lines.close();
      break;
    }
  }
}
