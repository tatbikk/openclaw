import { describe, expect, it, vi } from "vitest";
import type { OpenClawConfig } from "../config/types.openclaw.js";
import { createPluginRecord } from "./loader-records.js";
import { createPluginRegistry } from "./registry.js";
import { getPluginRuntimeGatewayRequestScope } from "./runtime/gateway-request-scope.js";
import { createPluginRuntime } from "./runtime/index.js";
import type { PluginRuntime } from "./runtime/types.js";

function createOrdinarySessionApi(runtime: PluginRuntime) {
  const registry = createPluginRegistry({
    logger: {
      info() {},
      warn() {},
      error() {},
      debug() {},
    },
    runtime,
    activateGlobalSideEffects: false,
  });
  const record = createPluginRecord({
    id: "ordinary-owner",
    source: "/plugins/ordinary-owner/index.js",
    origin: "bundled",
    enabled: true,
    configSchema: false,
  });
  return registry.createApi(record, { config: {} as OpenClawConfig });
}

describe("ordinary plugin session runtime scope", () => {
  it("injects exact plugin ownership into ordinary session creation", async () => {
    const runtime = createPluginRuntime();
    let observedPluginId: string | undefined;
    const createOrValidateOrdinarySession = vi.fn(async (params) => {
      observedPluginId = getPluginRuntimeGatewayRequestScope()?.pluginId;
      return { ...params, created: true };
    });
    runtime.agent.session.createOrValidateOrdinarySession =
      createOrValidateOrdinarySession as PluginRuntime["agent"]["session"]["createOrValidateOrdinarySession"];
    const api = createOrdinarySessionApi(runtime);
    const params = {
      agentId: "main",
      sessionId: "ordinary-session",
      sessionKey: "agent:main:plugin:ordinary-owner:ordinary",
      storePath: "/tmp/openclaw-agent.sqlite",
    };

    await api.runtime.agent.session.createOrValidateOrdinarySession(params);

    expect(observedPluginId).toBe("ordinary-owner");
    expect(createOrValidateOrdinarySession).toHaveBeenCalledOnce();
    expect(createOrValidateOrdinarySession).toHaveBeenCalledWith(params);
  });

  it.each([
    ["foreign ordinary key", "main", "agent:main:ordinary"],
    ["another plugin namespace", "main", "agent:main:plugin:other-owner:ordinary"],
    ["owner prefix confusion", "main", "agent:main:plugin:ordinary-owner-extra:ordinary"],
    ["missing opaque suffix", "main", "agent:main:plugin:ordinary-owner:"],
    ["key prefix canonicalization", "main", "Agent:main:plugin:ordinary-owner:ordinary"],
    ["key agent canonicalization", "main", "agent:MAIN:plugin:ordinary-owner:ordinary"],
    ["request agent canonicalization", "MAIN", "agent:main:plugin:ordinary-owner:ordinary"],
    ["agent and key mismatch", "worker", "agent:main:plugin:ordinary-owner:ordinary"],
    ["leading agent whitespace", " main", "agent:main:plugin:ordinary-owner:ordinary"],
    ["trailing key whitespace", "main", "agent:main:plugin:ordinary-owner:ordinary "],
  ])("rejects %s before calling ordinary session storage", async (_name, agentId, sessionKey) => {
    const runtime = createPluginRuntime();
    const createOrValidateOrdinarySession = vi.fn();
    runtime.agent.session.createOrValidateOrdinarySession =
      createOrValidateOrdinarySession as PluginRuntime["agent"]["session"]["createOrValidateOrdinarySession"];
    const api = createOrdinarySessionApi(runtime);

    await expect(
      api.runtime.agent.session.createOrValidateOrdinarySession({
        agentId,
        sessionId: "ordinary-session",
        sessionKey,
        storePath: "/tmp/openclaw-agent.sqlite",
      }),
    ).rejects.toThrow();
    expect(createOrValidateOrdinarySession).not.toHaveBeenCalled();
  });
});
