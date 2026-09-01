import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  createOrValidateOrdinarySession,
  loadSessionEntry,
  loadTranscriptEvents,
  upsertSessionEntryCore,
} from "./session-accessor.js";

const tempDirs: string[] = [];

afterEach(async () => {
  await Promise.all(tempDirs.splice(0).map((dir) => fs.rm(dir, { force: true, recursive: true })));
});

async function target(
  overrides: Partial<{
    agentId: string;
    sessionId: string;
    sessionKey: string;
    storePath: string;
  }> = {},
) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "ordinary-session-"));
  tempDirs.push(dir);
  return {
    agentId: "worker",
    sessionId: "ordinary-session",
    sessionKey: "agent:worker:plugin:sample:thread",
    storePath: path.join(dir, "openclaw-agent.sqlite"),
    ...overrides,
  };
}

describe("createOrValidateOrdinarySession", () => {
  it.each([
    {
      agentId: "worker",
      sessionKey: "agent:worker:plugin:other:thread",
    },
    {
      agentId: "worker",
      sessionKey: "agent:worker:plugin:sample-other:thread",
    },
    {
      agentId: "worker",
      sessionKey: "agent:worker:plugin:sample:",
    },
    {
      agentId: "WORKER",
      sessionKey: "agent:worker:plugin:sample:thread",
    },
    {
      agentId: "worker",
      sessionKey: "agent:WORKER:plugin:sample:thread",
    },
    {
      agentId: " worker",
      sessionKey: "agent:worker:plugin:sample:thread",
    },
  ])("rejects raw namespace mismatch without creating storage: %o", async (identity) => {
    const requested = await target(identity);

    await expect(
      createOrValidateOrdinarySession({
        ...requested,
        ownerPluginId: "sample",
      }),
    ).rejects.toThrow();

    await expect(fs.stat(requested.storePath)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("atomically creates the exact node, window, and first transcript header", async () => {
    const requested = await target();
    const created = await createOrValidateOrdinarySession({
      ...requested,
      cwd: "/workspace",
      ownerPluginId: "sample",
    });

    expect(created).toEqual({ ...requested, created: true });
    expect(loadSessionEntry(requested)).toMatchObject({
      createdVia: "plugin",
      pluginOwnerId: "sample",
      sessionId: requested.sessionId,
    });
    expect(await loadTranscriptEvents(requested)).toEqual([
      expect.objectContaining({
        cwd: "/workspace",
        id: requested.sessionId,
        type: "session",
      }),
    ]);
  });

  it("validates exact completed identity without duplicating the header", async () => {
    const requested = await target();
    const params = { ...requested, ownerPluginId: "sample" };

    expect((await createOrValidateOrdinarySession(params)).created).toBe(true);
    expect(await createOrValidateOrdinarySession(params)).toEqual({
      ...requested,
      created: false,
    });
    expect(await loadTranscriptEvents(requested)).toHaveLength(1);
  });

  it("serializes concurrent same-target creation into one lifecycle", async () => {
    const requested = await target();
    const params = { ...requested, ownerPluginId: "sample" };

    const results = await Promise.all(
      Array.from({ length: 8 }, () => createOrValidateOrdinarySession(params)),
    );

    expect(results.filter((result) => result.created)).toHaveLength(1);
    expect(results.every((result) => result.sessionKey === requested.sessionKey)).toBe(true);
    expect(loadSessionEntry(requested)?.sessionId).toBe(requested.sessionId);
    expect(await loadTranscriptEvents(requested)).toHaveLength(1);
  });

  it("rejects key and id collisions without changing the canonical session", async () => {
    const requested = await target();
    await createOrValidateOrdinarySession({ ...requested, ownerPluginId: "sample" });
    const before = await loadTranscriptEvents(requested);

    await expect(
      createOrValidateOrdinarySession({
        ...requested,
        sessionId: "different-session",
        ownerPluginId: "sample",
      }),
    ).rejects.toThrow("identity does not match");

    await expect(
      createOrValidateOrdinarySession({
        ...requested,
        sessionKey: "agent:worker:plugin:sample:other",
        ownerPluginId: "sample",
      }),
    ).rejects.toThrow("already bound to another session key");

    expect(loadSessionEntry(requested)?.sessionId).toBe(requested.sessionId);
    expect(await loadTranscriptEvents(requested)).toEqual(before);
  });

  it.each([
    { agentHarnessId: "native" },
    { cliSessionIds: { native: "cli-session" } },
    {
      acpSessionBinding: {
        acpBackendId: "backend",
        acpAgentId: "agent",
        agentSessionId: "session",
      },
    },
  ])("keeps runtime-owned sessions closed: %o", async (ownerFields) => {
    const requested = await target();
    await upsertSessionEntryCore(requested, {
      sessionId: requested.sessionId,
      updatedAt: 1,
      ...ownerFields,
    });

    await expect(
      createOrValidateOrdinarySession({
        ...requested,
        ownerPluginId: "sample",
      }),
    ).rejects.toThrow("owned by a harness, CLI, or ACP runtime");

    expect(await loadTranscriptEvents(requested)).toEqual([]);
  });

  it("rejects another plugin owner without mutation", async () => {
    const requested = await target();
    await upsertSessionEntryCore(requested, {
      sessionId: requested.sessionId,
      updatedAt: 1,
      pluginOwnerId: "first",
    });

    await expect(
      createOrValidateOrdinarySession({
        ...requested,
        ownerPluginId: "sample",
      }),
    ).rejects.toThrow("not owned by the requesting plugin");

    expect(loadSessionEntry(requested)?.pluginOwnerId).toBe("first");
    expect(await loadTranscriptEvents(requested)).toEqual([]);
  });

  it("rejects an owner-valid node and window without a transcript header", async () => {
    const requested = await target();
    await upsertSessionEntryCore(requested, {
      sessionId: requested.sessionId,
      updatedAt: 1,
      pluginOwnerId: "sample",
    });

    await expect(
      createOrValidateOrdinarySession({
        ...requested,
        ownerPluginId: "sample",
      }),
    ).rejects.toThrow("does not start with one canonical header");

    expect(await loadTranscriptEvents(requested)).toEqual([]);
  });
});
