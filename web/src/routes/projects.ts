import { Hono } from "hono";
import { z } from "zod";
import type { DB } from "../db/index.js";
import type { Auth } from "../auth/better-auth.js";
import type { Env } from "../env.js";
import type { AuthVars } from "../auth/middleware.js";
import { requireBearerJwt } from "../auth/jwt-bearer.js";
import { requireUserOrBearer } from "../auth/middleware.js";
import { findActiveMembership } from "../models/account-member.js";
import { bindLocalProject } from "../models/project.js";
import { isValidRepoKey } from "../util/repo-key.js";

// `displayName` is optional because the bridge has nothing better to send than a
// folder name, and a folder name is per-machine — see the fallback in the handler.
const BindProjectBody = z.object({
  deviceUuid: z.string().uuid(),
  localProjectId: z.string().min(1).max(200),
  localPath: z.string().min(1).max(1024),
  repoKey: z.string().min(1).max(512),
  displayName: z.string().min(1).max(200).optional(),
});

export function projectRoutes(deps: { db: DB; auth: Auth; env: Env }) {
  const r = new Hono<{ Variables: AuthVars }>();

  // Bridge-only: the machine that HAS the checkout is the only thing that can
  // report where it sits, and it holds an OAuth `client_credentials` JWT rather
  // than a session cookie.
  r.use(
    "/account/projects/bindings",
    requireBearerJwt({ auth: deps.auth, db: deps.db, env: deps.env })
  );

  // The list is read by the app as well as the bridge, so it takes either
  // carrier. Registered on the exact path, which does not overlap the
  // bindings gate above it.
  r.use(
    "/account/projects",
    requireUserOrBearer({ auth: deps.auth, db: deps.db, env: deps.env })
  );

  /**
   * The projects a task may be filed against.
   *
   * Read-only and deliberately thin: `id` addresses the project, `displayName`
   * names it, and `repoKey` is what the picker falls back to when two projects
   * share a label. Bindings stay off the wire — they are per-machine and say
   * where a checkout sits, which is not a thing a task cares about.
   *
   * Scoped by `findActiveMembership`, never by owner fallback: a user acting on
   * a team must not be shown their personal account's projects, because filing a
   * task against one would put it where the team cannot see it.
   */
  r.get("/account/projects", async (c) => {
    const membership = await findActiveMembership(deps.db, c.get("userId"));
    if (!membership) return c.json({ error: "NO_ACCOUNT" }, 403);

    const projects = await deps.db.project.findMany({
      where: { accountId: membership.accountId },
      orderBy: { displayName: "asc" },
      select: { id: true, repoKey: true, displayName: true },
    });
    return c.json({ projects });
  });

  r.post("/account/projects/bindings", async (c) => {
    const userId = c.get("userId");
    const parsed = BindProjectBody.safeParse(await c.req.json().catch(() => null));
    if (!parsed.success) return c.json({ error: "BAD_REQUEST", issues: parsed.error.issues }, 400);
    const body = parsed.data;

    if (!isValidRepoKey(body.repoKey)) return c.json({ error: "BAD_REPO_KEY" }, 400);

    // `findActiveMembership`, never `resolveBillingAccountId`: the owner fallback
    // would land a project on the user's personal account while they are acting
    // on a team, and every task that later hangs off it would be invisible to the
    // team it was created for. No membership is a 403, not a silent redirect.
    const membership = await findActiveMembership(deps.db, userId);
    if (!membership) return c.json({ error: "NO_ACCOUNT" }, 403);

    // The body's deviceUuid is untrusted input and is proven the way the
    // heartbeat route proves it — by scoping the write to the caller's userId and
    // treating a miss as a 404. The gate's own `deviceId` is not substituted for
    // it: that would quietly narrow the route to binding the calling machine.
    const result = await deps.db.$transaction(async (tx) => {
      const owned = await tx.device.updateMany({
        where: { userId, deviceId: body.deviceUuid, revokedAt: null },
        data: { lastSeenAt: new Date() },
      });
      if (owned.count === 0) return null;
      return bindLocalProject(tx, {
        accountId: membership.accountId,
        repoKey: body.repoKey,
        // Falls back to the repository's own name rather than the folder's: the
        // label belongs to a repository shared across machines, and the last
        // segment of a repoKey is the same string on all of them.
        displayName: body.displayName ?? body.repoKey.split("/").pop()!,
        deviceId: body.deviceUuid,
        localProjectId: body.localProjectId,
        localPath: body.localPath,
      });
    });

    if (result === null) return c.json({ error: "NOT_FOUND" }, 404);
    if (result.kind === "device_conflict") return c.json({ error: "BINDING_CONFLICT" }, 409);

    return c.json({ ok: true, projectId: result.projectId });
  });

  return r;
}
