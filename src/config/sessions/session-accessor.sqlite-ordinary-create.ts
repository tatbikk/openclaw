import { isRecord } from "@openclaw/normalization-core/record-coerce";
import { executeSqliteQueryTakeFirstSync } from "../../infra/kysely-sync.js";
import { normalizeAgentId } from "../../routing/session-key.js";
import { runOpenClawAgentWriteTransaction } from "../../state/openclaw-agent-db.js";
import {
  readExactSessionEntryRow,
  writeSessionEntry,
} from "./session-accessor.sqlite-entry-store.js";
import { loadTranscriptEventsFromDatabase } from "./session-accessor.sqlite-read.js";
import {
  getSessionKysely,
  resolveSqliteTranscriptScope,
  runExclusiveSqliteSessionWrite,
  toDatabaseOptions,
} from "./session-accessor.sqlite-scope.js";
import { appendTranscriptEventInTransaction } from "./session-accessor.sqlite-transcript-store.js";
import { createSessionTranscriptHeader } from "./transcript-header.js";
import type { InternalSessionEntry as SessionEntry } from "./types.js";

export type OrdinarySessionTarget = {
  agentId: string;
  created: boolean;
  sessionId: string;
  sessionKey: string;
  storePath: string;
};

export type CreateOrValidateOrdinarySessionParams = Omit<OrdinarySessionTarget, "created"> & {
  cwd?: string;
  ownerPluginId: string;
};

function assertExactNonEmptyIdentity(params: CreateOrValidateOrdinarySessionParams): void {
  for (const [field, value] of Object.entries({
    agentId: params.agentId,
    ownerPluginId: params.ownerPluginId,
    sessionId: params.sessionId,
    sessionKey: params.sessionKey,
    storePath: params.storePath,
  })) {
    if (value.length === 0 || value.trim() !== value) {
      throw new Error(`ordinary session ${field} must be an exact non-empty value`);
    }
  }
}

export function assertOrdinaryPluginSessionNamespace(params: {
  agentId: string;
  ownerPluginId: string;
  sessionKey: string;
}): void {
  if (
    params.agentId.length === 0 ||
    params.ownerPluginId.length === 0 ||
    params.sessionKey.length === 0 ||
    params.agentId.trim() !== params.agentId ||
    params.ownerPluginId.trim() !== params.ownerPluginId ||
    params.sessionKey.trim() !== params.sessionKey
  ) {
    throw new Error("ordinary session ownership requires exact non-empty raw identities");
  }

  const namespace = `agent:${params.agentId}:plugin:${params.ownerPluginId}:`;
  if (
    normalizeAgentId(params.agentId) !== params.agentId ||
    !params.sessionKey.startsWith(namespace) ||
    params.sessionKey.length === namespace.length
  ) {
    throw new Error(
      `ordinary session key must use exact agent "${params.agentId}" and plugin namespace "plugin:${params.ownerPluginId}:<opaque>"`,
    );
  }
}

function assertOrdinaryEntryOwner(params: {
  entry: SessionEntry;
  ownerPluginId: string;
  sessionId: string;
}): void {
  const { entry } = params;
  if (entry.sessionId !== params.sessionId) {
    throw new Error("ordinary session identity does not match the stored session");
  }
  if (
    entry.agentHarnessId !== undefined ||
    entry.agentRuntimeOverride !== undefined ||
    entry.cliSessionBindings !== undefined ||
    entry.cliSessionIds !== undefined ||
    entry.claudeCliSessionId !== undefined ||
    entry.acpSessionBinding !== undefined ||
    entry.acp !== undefined
  ) {
    throw new Error("ordinary session target is owned by a harness, CLI, or ACP runtime");
  }
  if (entry.pluginOwnerId !== params.ownerPluginId) {
    throw new Error("ordinary session target is not owned by the requesting plugin");
  }
}

/**
 * Creates one ordinary plugin-owned node, window, and first transcript header
 * in one SQLite commit, or validates the already-complete exact identity.
 */
export async function createOrValidateOrdinarySession(
  params: CreateOrValidateOrdinarySessionParams,
): Promise<OrdinarySessionTarget> {
  // Reject raw authority before scope resolution can reach any store.
  assertExactNonEmptyIdentity(params);
  assertOrdinaryPluginSessionNamespace(params);

  const resolved = resolveSqliteTranscriptScope(params);
  if (resolved.agentId !== params.agentId || resolved.sessionKey !== params.sessionKey) {
    throw new Error("ordinary session target does not resolve to the requested raw identity");
  }

  const created = await runExclusiveSqliteSessionWrite(resolved, async () =>
    runOpenClawAgentWriteTransaction(
      (database) => {
        const db = getSessionKysely(database.db);
        const exact = readExactSessionEntryRow(database, resolved.sessionKey);
        const window = executeSqliteQueryTakeFirstSync(
          database.db,
          db
            .selectFrom("session_windows")
            .select(["session_id", "session_key"])
            .where("session_id", "=", resolved.sessionId),
        );
        const events = loadTranscriptEventsFromDatabase(database, resolved.sessionId);
        const headers = events.filter(
          (event): event is { id?: unknown; type: "session" } =>
            isRecord(event) && event.type === "session",
        );
        const firstEvent = events[0];

        if (exact && exact.entry.sessionId !== resolved.sessionId) {
          throw new Error("ordinary session identity does not match the stored session");
        }
        if (window && window.session_key !== resolved.sessionKey) {
          throw new Error("ordinary session id is already bound to another session key");
        }
        if (exact || window || events.length > 0) {
          if (!exact || !window) {
            throw new Error("ordinary session target has incomplete persisted lifecycle state");
          }
          assertOrdinaryEntryOwner({
            entry: exact.entry,
            ownerPluginId: params.ownerPluginId,
            sessionId: resolved.sessionId,
          });
          if (
            headers.length !== 1 ||
            headers[0]?.id !== resolved.sessionId ||
            !isRecord(firstEvent) ||
            firstEvent.type !== "session"
          ) {
            throw new Error("ordinary session transcript does not start with one canonical header");
          }
          return false;
        }

        const now = Date.now();
        const entry: SessionEntry = {
          sessionId: resolved.sessionId,
          createdAt: now,
          updatedAt: now,
          createdVia: "plugin",
          createdActor: { type: "system", id: params.ownerPluginId },
          pluginOwnerId: params.ownerPluginId,
        };

        // Header append establishes the node and window. Replacing its
        // transaction-local placeholder completes the node before COMMIT.
        const appended = appendTranscriptEventInTransaction(
          database,
          resolved,
          createSessionTranscriptHeader({
            cwd: params.cwd,
            sessionId: resolved.sessionId,
          }),
        );
        if (!appended) {
          throw new Error("ordinary session transcript header was not created");
        }
        writeSessionEntry(database, resolved.sessionKey, entry, {
          previousEntry: null,
        });
        return true;
      },
      toDatabaseOptions(resolved),
      { operationLabel: "session.ordinary-create" },
    ),
  );

  return {
    agentId: resolved.agentId,
    created,
    sessionId: resolved.sessionId,
    sessionKey: resolved.sessionKey,
    storePath: params.storePath,
  };
}
