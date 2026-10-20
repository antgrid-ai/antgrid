type SessionEvent = {
  type: string;
  properties?: { info?: { id?: string; parentID?: string; title?: string } };
};

// Kilo loads local plugins in its own runtime; keep this asset dependency-free.
export const AntgridSessionIdentity = async () => {
  let chain: Promise<void> = Promise.resolve();
  return {
    event: ({ event }: { event: SessionEvent }): Promise<void> => {
      const port = process.env.ANTGRID_API_PORT;
      const terminalId = process.env.ANTGRID_TERMINAL_ID;
      const runId = process.env.ANTGRID_RUN_ID;
      const info = event.properties?.info;
      if (!port || !terminalId || !info?.id || info.parentID
        || (event.type !== "session.created" && event.type !== "session.updated")) return chain;
      // Preserve publication order so a slow post cannot restore an older id
      // after the user switches conversations or forks inside the terminal.
      const body = JSON.stringify({ terminalId, runId, sessionId: info.id, title: info.title || undefined, agent: "kilo" });
      chain = chain.then(async () => {
        try {
          await fetch(`http://127.0.0.1:${port}/session-title`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body,
            signal: AbortSignal.timeout(2000),
          });
        } catch { /* bridge gone */ }
      });
      return chain;
    },
  };
};
