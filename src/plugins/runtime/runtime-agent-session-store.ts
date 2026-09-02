import {
  createOrValidateOrdinarySession as createOrValidateAccessorOrdinarySession,
  deleteSessionEntryLifecycle,
  listSessionEntriesCore as listAccessorSessionEntries,
  listSessionEntriesReadOnly as listAccessorSessionEntriesReadOnly,
  loadSessionEntryReadOnly,
  patchSessionEntryCore as patchAccessorSessionEntry,
  replaceSessionEntry,
  rollbackAgentHarnessSessionEntryLifecycle,
  rollbackPluginOwnedSessionEntryLifecycle,
  type SessionAccessScope,
  updateSessionEntry,
} from "../../config/sessions/session-accessor.js";
import { normalizeResolvedMaintenanceConfigInput } from "../../config/sessions/store-maintenance.js";
import type { ResolvedSessionMaintenanceConfigInput } from "../../config/sessions/store-maintenance.js";
import type { SessionEntry } from "../../config/sessions/types.js";
import { getPluginRuntimeGatewayRequestScope } from "./gateway-request-scope.js";
import type { PluginRuntime } from "./types.js";

type RuntimeSessionStoreReadParams = {
  agentId?: string;
  env?: NodeJS.ProcessEnv;
  hydrateSkillPromptRefs?: boolean;
  sessionKey: string;
  readConsistency?: "latest";
  storePath?: string;
};

type RuntimeSessionStoreListParams = Partial<Omit<RuntimeSessionStoreReadParams, "sessionKey">> & {
  readOnly?: boolean;
};

type RuntimeSessionStoreEntrySummary = {
  sessionKey: string;
  entry: SessionEntry;
};

type RuntimeSessionStoreEntryUpdateParams = {
  storePath: string;
  sessionKey: string;
  update: (
    entry: SessionEntry,
  ) => Promise<Partial<SessionEntry> | null> | Partial<SessionEntry> | null;
  skipMaintenance?: boolean;
  takeCacheOwnership?: boolean;
  requireWriteSuccess?: boolean;
};

type RuntimeSessionStoreEntryPatchParams = RuntimeSessionStoreReadParams & {
  fallbackEntry?: SessionEntry;
  maintenanceConfig?: ResolvedSessionMaintenanceConfigInput;
  preserveActivity?: boolean;
  replaceEntry?: boolean;
  update: (
    entry: SessionEntry,
    context: { existingEntry?: SessionEntry },
  ) => Promise<Partial<SessionEntry> | null> | Partial<SessionEntry> | null;
};

type RuntimeUpsertSessionEntryParams = RuntimeSessionStoreReadParams & {
  entry: SessionEntry;
};

type RuntimeFinalizeSessionEntryParams = {
  sessionKey: string;
  storePath: string;
  expectedEntry: SessionEntry;
  patch: Partial<SessionEntry>;
  assertCommitAllowed: () => void;
};

type RuntimeRollbackCreatedSessionEntryParams = {
  rollbackParams: Parameters<typeof deleteSessionEntryLifecycle>[0];
  expectedEntry: SessionEntry;
  expectedPluginOwnerId: string;
};

function toSessionAccessScope(params: RuntimeSessionStoreReadParams): SessionAccessScope {
  // Keep plugin runtime parameters aligned with the public SDK wrapper while
  // avoiding direct exposure of internal accessor-only options.
  return {
    sessionKey: params.sessionKey,
    ...(params.agentId !== undefined ? { agentId: params.agentId } : {}),
    ...(params.env !== undefined ? { env: params.env } : {}),
    ...(params.hydrateSkillPromptRefs !== undefined
      ? { hydrateSkillPromptRefs: params.hydrateSkillPromptRefs }
      : {}),
    ...(params.readConsistency !== undefined ? { readConsistency: params.readConsistency } : {}),
    ...(params.storePath !== undefined ? { storePath: params.storePath } : {}),
  };
}

export function getSessionEntry(params: RuntimeSessionStoreReadParams): SessionEntry | undefined {
  return loadSessionEntryReadOnly(toSessionAccessScope(params));
}

export function listSessionEntries(
  params: RuntimeSessionStoreListParams = {},
): RuntimeSessionStoreEntrySummary[] {
  const listEntries = params.readOnly
    ? listAccessorSessionEntriesReadOnly
    : listAccessorSessionEntries;
  return listEntries({
    ...(params.agentId !== undefined ? { agentId: params.agentId } : {}),
    ...(params.env !== undefined ? { env: params.env } : {}),
    ...(params.hydrateSkillPromptRefs !== undefined
      ? { hydrateSkillPromptRefs: params.hydrateSkillPromptRefs }
      : {}),
    ...(params.storePath !== undefined ? { storePath: params.storePath } : {}),
  });
}

export async function patchSessionEntry(
  params: RuntimeSessionStoreEntryPatchParams,
): Promise<SessionEntry | null> {
  return await patchAccessorSessionEntry(toSessionAccessScope(params), params.update, {
    fallbackEntry: params.fallbackEntry,
    maintenanceConfig:
      params.maintenanceConfig !== undefined
        ? normalizeResolvedMaintenanceConfigInput(params.maintenanceConfig)
        : undefined,
    preserveActivity: params.preserveActivity,
    replaceEntry: params.replaceEntry,
  });
}

export async function finalizeSessionEntry(
  params: RuntimeFinalizeSessionEntryParams,
): Promise<SessionEntry | null> {
  return await patchAccessorSessionEntry(
    {
      sessionKey: params.sessionKey,
      storePath: params.storePath,
    },
    (currentEntry) => {
      if (JSON.stringify(currentEntry) !== JSON.stringify(params.expectedEntry)) {
        throw new Error(`created session ${params.sessionKey} changed before finalization`);
      }
      return params.patch;
    },
    {
      preserveActivity: true,
      requireWriteSuccess: true,
      assertCommitAllowed: params.assertCommitAllowed,
    },
  );
}

export async function rollbackCreatedSessionEntry(
  params: RuntimeRollbackCreatedSessionEntryParams,
): Promise<Awaited<ReturnType<typeof deleteSessionEntryLifecycle>>> {
  if (params.expectedEntry.modelSelectionLocked !== true) {
    return await deleteSessionEntryLifecycle(params.rollbackParams);
  }
  if (params.expectedEntry.agentHarnessId) {
    return await rollbackAgentHarnessSessionEntryLifecycle(params.rollbackParams);
  }
  return await rollbackPluginOwnedSessionEntryLifecycle({
    ...params.rollbackParams,
    expectedPluginOwnerId: params.expectedPluginOwnerId,
  });
}

export async function updateStoreEntry(
  params: RuntimeSessionStoreEntryUpdateParams,
): Promise<SessionEntry | null> {
  // Maintainer note: keep the legacy object-parameter API here, but route
  // mutations through the session accessor boundary.
  return await updateSessionEntry(
    {
      sessionKey: params.sessionKey,
      storePath: params.storePath,
    },
    params.update,
    {
      skipMaintenance: params.skipMaintenance,
      takeCacheOwnership: params.takeCacheOwnership,
      requireWriteSuccess: params.requireWriteSuccess,
    },
  );
}

export async function upsertSessionEntry(params: RuntimeUpsertSessionEntryParams): Promise<void> {
  // Maintainer note: this compatibility helper has full-entry replacement
  // semantics, so removed fields must not survive as merge leftovers.
  await replaceSessionEntry(toSessionAccessScope(params), params.entry);
}

export async function createOrValidateOrdinarySession(
  params: Parameters<PluginRuntime["agent"]["session"]["createOrValidateOrdinarySession"]>[0],
): Promise<
  Awaited<ReturnType<PluginRuntime["agent"]["session"]["createOrValidateOrdinarySession"]>>
> {
  const ownerPluginId = getPluginRuntimeGatewayRequestScope()?.pluginId;
  if (!ownerPluginId) {
    throw new Error("ordinary session creation requires an owning plugin runtime scope");
  }
  return await createOrValidateAccessorOrdinarySession({ ...params, ownerPluginId });
}
