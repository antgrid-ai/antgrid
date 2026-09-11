import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestSession, createTestSubscription, createTestUser } from "../helpers/fixtures.js";
import {
  upsertIntegration,
  upsertIntegrationRepo,
  type RepoVisibility,
} from "../../src/models/integration.js";
import type { Env } from "../../src/env.js";

let pg: PgHandle;
beforeAll(async () => {
  pg = await startTestPg();
});
afterAll(async () => {
  await pg.stop();
});
beforeEach(async () => {
  await pg.truncate();
});

const ORIGIN = "http://localhost:8787";

/** Enough for `githubAppConfig` to answer "configured"; nothing here signs. */
const APP_ENV: Partial<Env> = {
  GITHUB_APP_ID: "1234",
  GITHUB_APP_SLUG: "antgrid-dev",
  GITHUB_APP_CLIENT_ID: "Iv1.deadbeef",
  GITHUB_APP_CLIENT_SECRET: "shh",
  GITHUB_APP_PRIVATE_KEY: "-----BEGIN RSA PRIVATE KEY-----\nx\n-----END RSA PRIVATE KEY-----",
};

type App = ReturnType<typeof buildTestApp>["app"];

function build(envOverrides: Partial<Env> = APP_ENV) {
  return buildTestApp(pg.db, pg.url, { envOverrides }).app;
}

async function signIn(email: string) {
  const user = await createTestUser(pg.db, email);
  await createTestSubscription(pg.db, user.id, { tier: "pro" });
  const { cookie } = await createTestSession(pg.db, user.id);
  const account = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: user.id } });
  return { user, accountId: account.id, cookie };
}

async function connect(app: App, cookie: string): Promise<Response> {
  return app.request("/integrations/connect", { headers: { cookie } });
}

/** The state cookie as the browser would send it back, plus the nonce GitHub
 *  was handed — the two halves the callback compares. */
function installState(res: Response): { cookie: string; state: string } {
  const setCookie = res.headers.get("set-cookie") ?? "";
  const value = /antgrid\.gh_install=([^;]+)/.exec(setCookie)?.[1] ?? "";
  const state = new URL(res.headers.get("location") ?? "http://x/").searchParams.get("state") ?? "";
  return { cookie: `antgrid.gh_install=${decodeURIComponent(value)}`, state };
}

async function seedRepo(
  accountId: string,
  userId: string,
  over: {
    syncEnabled?: boolean;
    pushEnabled?: boolean;
    publishNewByDefault?: boolean;
    visibility?: RepoVisibility;
  } = {}
) {
  const integration = await upsertIntegration(pg.db, {
    accountId,
    provider: "github",
    externalAccountId: "9001",
    installationId: "42",
    displayName: "acme",
    installedBy: userId,
  });
  if (integration.kind !== "ok") throw new Error(integration.kind);
  const repo = await upsertIntegrationRepo(pg.db, {
    accountId,
    integrationId: integration.integration.id,
    repoKey: "github.com/acme/api",
    externalRepoId: "5555",
    visibility: over.visibility ?? "public",
    syncEnabled: over.syncEnabled ?? false,
    pushEnabled: over.pushEnabled ?? false,
    publishNewByDefault: over.publishNewByDefault ?? false,
  });
  if (repo.kind !== "ok") throw new Error(repo.kind);
  return { integrationId: integration.integration.id, repoId: repo.repo.id };
}

function postSync(app: App, repoId: string, cookie: string, body: Record<string, string>) {
  return app.request(`/ui/integrations/repos/${repoId}/sync`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", origin: ORIGIN, cookie },
    body: new URLSearchParams(body).toString(),
  });
}

describe("GET /integrations/connect", () => {
  test("says the server has no App rather than sending the browser to a dead install url", async () => {
    const app = build({});
    const { cookie } = await signIn("nia@example.com");
    const res = await connect(app, cookie);
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("/integrations?github=not_configured");
    // No state minted for a flow that cannot start.
    expect(res.headers.get("set-cookie")).toBeNull();
  });

  test("mints the state and the cookie together, and they match", async () => {
    const app = build();
    const { cookie } = await signIn("nia@example.com");
    const res = await connect(app, cookie);
    const location = new URL(res.headers.get("location") ?? "");
    expect(location.origin).toBe("https://github.com");
    expect(location.pathname).toBe("/apps/antgrid-dev/installations/new");

    const setCookie = res.headers.get("set-cookie") ?? "";
    expect(setCookie).toContain("HttpOnly");
    // Lax, never Strict: GitHub returns the user by a cross-site top-level
    // navigation and Strict drops the cookie on exactly that request.
    expect(setCookie).toContain("SameSite=Lax");
    expect(setCookie).toContain("Path=/integrations");

    const state = installState(res);
    // The cookie carries the nonce plus the user it was minted for, and the
    // nonce is the half GitHub echoes.
    expect(state.cookie).toContain(`antgrid.gh_install=${state.state}.`);
  });

  test("two starts never share a nonce", async () => {
    const app = build();
    const { cookie } = await signIn("nia@example.com");
    const first = installState(await connect(app, cookie));
    const second = installState(await connect(app, cookie));
    expect(first.state).not.toBe(second.state);
  });

  describe("asEmail — the app's own signed-in user", () => {
    test("matching the browser's session proceeds exactly as with no asEmail at all", async () => {
      const app = build();
      const { cookie } = await signIn("nia@example.com");
      const res = await app.request("/integrations/connect?asEmail=nia@example.com", {
        headers: { cookie },
      });
      expect(new URL(res.headers.get("location") ?? "").origin).toBe("https://github.com");
      expect(res.headers.get("set-cookie") ?? "").toContain("antgrid.gh_install=");
    });

    test("matches case-insensitively", async () => {
      const app = build();
      const { cookie } = await signIn("nia@example.com");
      const res = await app.request("/integrations/connect?asEmail=NIA@EXAMPLE.COM", {
        headers: { cookie },
      });
      expect(new URL(res.headers.get("location") ?? "").origin).toBe("https://github.com");
    });

    test("a browser signed in as someone else is signed out and sent to sign in as the app's user, with no install state minted", async () => {
      const app = build();
      const { cookie } = await signIn("nia@example.com");
      const res = await app.request(
        "/integrations/connect?asEmail=someone-else@example.com",
        { headers: { cookie } }
      );
      const location = res.headers.get("location") ?? "";
      expect(location).toContain("/login");
      expect(location).toContain(encodeURIComponent("someone-else@example.com"));
      // Nothing bound to the wrong account: the install-state cookie is never
      // set on this path.
      expect(res.headers.get("set-cookie") ?? "").not.toContain("antgrid.gh_install=");

      // The mismatched session is actually gone, not just redirected past.
      const stillSignedIn = await app.request("/integrations", { headers: { cookie } });
      expect(stillSignedIn.headers.get("location")).toContain("/login");
    });
  });
});

describe("GET /integrations/callback", () => {
  test("a callback with no state cookie is refused before anything is bound", async () => {
    const app = build();
    const { cookie, accountId } = await signIn("nia@example.com");
    const res = await app.request("/integrations/callback?installation_id=42&code=c&state=guess", {
      headers: { cookie },
    });
    expect(res.headers.get("location")).toBe("/integrations?github=bad_state");
    expect(await pg.db.integration.count({ where: { accountId } })).toBe(0);
  });

  test("a state the browser did not start with is refused, and the cookie is spent either way", async () => {
    const app = build();
    const { cookie } = await signIn("nia@example.com");
    const started = installState(await connect(app, cookie));
    const res = await app.request(
      "/integrations/callback?installation_id=42&code=c&state=someoneelse",
      { headers: { cookie: `${cookie}; ${started.cookie}` } }
    );
    expect(res.headers.get("location")).toBe("/integrations?github=bad_state");
    // Single use: a state that survives a refused callback is a state an
    // attacker gets a second attempt at.
    expect(res.headers.get("set-cookie") ?? "").toContain("antgrid.gh_install=");
    expect(res.headers.get("set-cookie") ?? "").toMatch(/Max-Age=0|Expires=/);
  });

  test("a member who could only request the install is told so, not shown a failure", async () => {
    const app = build();
    const { cookie, accountId } = await signIn("nia@example.com");
    const started = installState(await connect(app, cookie));
    const res = await app.request(
      `/integrations/callback?setup_action=request&state=${started.state}`,
      { headers: { cookie: `${cookie}; ${started.cookie}` } }
    );
    expect(res.headers.get("location")).toBe("/integrations?github=install_requested");
    expect(await pg.db.integration.count({ where: { accountId } })).toBe(0);
  });

  test("a valid state with no code is refused rather than trusted on the id alone", async () => {
    const app = build();
    const { cookie, accountId } = await signIn("nia@example.com");
    const started = installState(await connect(app, cookie));
    const res = await app.request(
      `/integrations/callback?installation_id=42&state=${started.state}`,
      { headers: { cookie: `${cookie}; ${started.cookie}` } }
    );
    expect(res.headers.get("location")).toBe("/integrations?github=code_rejected");
    expect(await pg.db.integration.count({ where: { accountId } })).toBe(0);
  });
});

describe("GET /integrations", () => {
  test("a signed-out reader is sent to sign in, not shown the page", async () => {
    const res = await build().request("/integrations");
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toContain("/login");
  });

  test("shows the connected account and its repositories", async () => {
    const app = build();
    const { cookie, accountId, user } = await signIn("nia@example.com");
    await seedRepo(accountId, user.id);
    const html = await (await app.request("/integrations", { headers: { cookie } })).text();
    expect(html).toContain("acme");
    expect(html).toContain("github.com/acme/api");
    expect(html).toContain("/integrations/connect");
  });

  test("renders the notice for the code the callback redirected with", async () => {
    const app = build();
    const { cookie } = await signIn("nia@example.com");
    const html = await (
      await app.request("/integrations?github=not_your_installation", { headers: { cookie } })
    ).text();
    expect(html).toContain("not one your GitHub account administers");
  });
});

describe("POST /ui/integrations/repos/:id/sync", () => {
  test("turning import on saves, and answers with the row it saved", async () => {
    const app = build();
    const { cookie, accountId, user } = await signIn("nia@example.com");
    const { repoId } = await seedRepo(accountId, user.id);
    const res = await postSync(app, repoId, cookie, { syncEnabled: "on", importFilterKind: "all" });
    expect(res.status).toBe(200);
    expect(await res.text()).toContain(`id="repo-${repoId}"`);
    const row = await pg.db.integrationRepo.findUniqueOrThrow({ where: { id: repoId } });
    expect(row.syncEnabled).toBe(true);
  });

  test("an absent checkbox is the off state, not a field the caller forgot", async () => {
    const app = build();
    const { cookie, accountId, user } = await signIn("nia@example.com");
    const { repoId } = await seedRepo(accountId, user.id, { syncEnabled: true });
    await postSync(app, repoId, cookie, { importFilterKind: "all" });
    const row = await pg.db.integrationRepo.findUniqueOrThrow({ where: { id: repoId } });
    expect(row.syncEnabled).toBe(false);
  });

  test("a label filter with no label takes the whole write down, toggle included", async () => {
    const app = build();
    const { cookie, accountId, user } = await signIn("nia@example.com");
    const { repoId } = await seedRepo(accountId, user.id);
    await postSync(app, repoId, cookie, {
      syncEnabled: "on",
      importFilterKind: "label",
      importFilterValue: "   ",
    });
    const row = await pg.db.integrationRepo.findUniqueOrThrow({ where: { id: repoId } });
    expect(row.importFilterKind).toBe("all");
    expect(row.importFilterValue).toBeNull();
    // The half-save is the dangerous one: the toggle alone would start an import
    // under the stored `all` filter, handing back the whole repository to
    // someone who asked for a single label.
    expect(row.syncEnabled).toBe(false);
  });

  test("a filter that names something saves as a pair", async () => {
    const app = build();
    const { cookie, accountId, user } = await signIn("nia@example.com");
    const { repoId } = await seedRepo(accountId, user.id);
    await postSync(app, repoId, cookie, {
      syncEnabled: "on",
      importFilterKind: "label",
      importFilterValue: " agent ",
    });
    const row = await pg.db.integrationRepo.findUniqueOrThrow({ where: { id: repoId } });
    expect(row.syncEnabled).toBe(true);
    expect(row.importFilterKind).toBe("label");
    expect(row.importFilterValue).toBe("agent");
  });

  test("a repository GitHub no longer lists cannot be switched back on", async () => {
    const app = build();
    const { cookie, accountId, user } = await signIn("nia@example.com");
    const { repoId } = await seedRepo(accountId, user.id);
    await pg.db.integrationRepo.update({
      where: { id: repoId },
      data: { removedAt: new Date("2026-08-01T00:00:00Z") },
    });
    const res = await postSync(app, repoId, cookie, { syncEnabled: "on", importFilterKind: "all" });
    // 200 with the unchanged row on purpose: htmx does not swap a 4xx, and an
    // unswapped refusal would leave the switch showing a state that was never
    // stored.
    expect(res.status).toBe(200);
    expect(await res.text()).toContain("GitHub stopped listing this repository");
    const row = await pg.db.integrationRepo.findUniqueOrThrow({ where: { id: repoId } });
    expect(row.syncEnabled).toBe(false);
  });

  test("another account's repository is not found, whatever its id", async () => {
    const app = build();
    const owner = await signIn("nia@example.com");
    const { repoId } = await seedRepo(owner.accountId, owner.user.id);
    const stranger = await signIn("mal@example.com");
    const res = await postSync(app, repoId, stranger.cookie, {
      syncEnabled: "on",
      importFilterKind: "all",
    });
    expect(res.status).toBe(404);
    const row = await pg.db.integrationRepo.findUniqueOrThrow({ where: { id: repoId } });
    expect(row.syncEnabled).toBe(false);
  });
});

describe("POST /ui/integrations/repos/:id/sync — the outbound consents", () => {
  test("both boxes checked stores both, and the row comes back saying so", async () => {
    const app = build();
    const { cookie, accountId, user } = await signIn("nia@example.com");
    const { repoId } = await seedRepo(accountId, user.id);

    const res = await postSync(app, repoId, cookie, {
      syncEnabled: "on",
      importFilterKind: "all",
      pushEnabled: "on",
      publishNewByDefault: "on",
    });
    expect(res.status).toBe(200);

    const row = await pg.db.integrationRepo.findUniqueOrThrow({ where: { id: repoId } });
    expect(row.pushEnabled).toBe(true);
    expect(row.publishNewByDefault).toBe(true);

    const html = await res.text();
    expect(html).toMatch(/name="pushEnabled"[^>]*checked=""/);
    expect(html).toMatch(/name="publishNewByDefault"[^>]*checked=""/);
  });

  test("a publish default with push off is stored off, not armed for a switch that is gone", async () => {
    const app = build();
    const { cookie, accountId, user } = await signIn("nia@example.com");
    const { repoId } = await seedRepo(accountId, user.id);

    // The disabled attribute is a courtesy the browser can be talked out of;
    // the pairing that matters is the one the writer applies.
    await postSync(app, repoId, cookie, {
      syncEnabled: "on",
      importFilterKind: "all",
      publishNewByDefault: "on",
    });

    const row = await pg.db.integrationRepo.findUniqueOrThrow({ where: { id: repoId } });
    expect(row.pushEnabled).toBe(false);
    expect(row.publishNewByDefault).toBe(false);
  });

  test("absent boxes turn a repository that was sending changes back off", async () => {
    const app = build();
    const { cookie, accountId, user } = await signIn("nia@example.com");
    const { repoId } = await seedRepo(accountId, user.id, {
      pushEnabled: true,
      publishNewByDefault: true,
    });

    await postSync(app, repoId, cookie, { syncEnabled: "on", importFilterKind: "all" });

    const row = await pg.db.integrationRepo.findUniqueOrThrow({ where: { id: repoId } });
    expect(row.pushEnabled).toBe(false);
    expect(row.publishNewByDefault).toBe(false);
  });

  test("a repository GitHub no longer lists cannot be switched into sending changes back", async () => {
    const app = build();
    const { cookie, accountId, user } = await signIn("nia@example.com");
    const { repoId } = await seedRepo(accountId, user.id);
    await pg.db.integrationRepo.update({
      where: { id: repoId },
      data: { removedAt: new Date("2026-08-01T00:00:00Z") },
    });

    const res = await postSync(app, repoId, cookie, {
      syncEnabled: "on",
      importFilterKind: "all",
      pushEnabled: "on",
      publishNewByDefault: "on",
    });
    expect(res.status).toBe(200);

    const row = await pg.db.integrationRepo.findUniqueOrThrow({ where: { id: repoId } });
    expect(row.pushEnabled).toBe(false);
    expect(row.publishNewByDefault).toBe(false);
  });

  test("a revoked connection freezes the outbound consents too", async () => {
    const app = build();
    const { cookie, accountId, user } = await signIn("nia@example.com");
    const { repoId, integrationId } = await seedRepo(accountId, user.id);
    await pg.db.integration.update({
      where: { id: integrationId },
      data: { status: "revoked", revokedAt: new Date("2026-07-04T00:00:00Z") },
    });

    await postSync(app, repoId, cookie, {
      syncEnabled: "on",
      importFilterKind: "all",
      pushEnabled: "on",
    });

    const row = await pg.db.integrationRepo.findUniqueOrThrow({ where: { id: repoId } });
    expect(row.pushEnabled).toBe(false);
  });

  test("the saved row is rendered with the public warning only where it applies", async () => {
    const app = build();
    const { cookie, accountId, user } = await signIn("nia@example.com");
    const { repoId } = await seedRepo(accountId, user.id, { visibility: "private" });

    const html = await (
      await postSync(app, repoId, cookie, {
        syncEnabled: "on",
        importFilterKind: "all",
        pushEnabled: "on",
      })
    ).text();
    expect(html).toMatch(/name="pushEnabled"[^>]*checked=""/);
    expect(html).not.toContain("anything filed here is public the moment it is filed");
  });

  test("a repository set to the member filter renders the identity caveat", async () => {
    const app = build();
    const { cookie, accountId, user } = await signIn("nia@example.com");
    const { repoId } = await seedRepo(accountId, user.id);

    const html = await (
      await postSync(app, repoId, cookie, {
        syncEnabled: "on",
        importFilterKind: "assigned_to_member",
      })
    ).text();
    expect(html).toContain("signed in to Antgrid with GitHub");
    expect(html).toMatch(/data-member-caveat(?![^>]*hidden)/);
  });

  test("the first-import line follows lastFullSyncAt, not the switch", async () => {
    const app = build();
    const { cookie, accountId, user } = await signIn("omar@example.com");
    const { repoId } = await seedRepo(accountId, user.id);

    const onAndUnread = await (
      await postSync(app, repoId, cookie, { syncEnabled: "on", importFilterKind: "all" })
    ).text();
    expect(onAndUnread).toContain("still reading this repository for the first time");

    // Written only where a walk saw a short page, which is the poll's proof that
    // it read the repository to the end — nothing else in the tree sets it.
    await pg.db.integrationRepo.update({
      where: { id: repoId },
      data: { lastFullSyncAt: new Date() },
    });

    const read = await (
      await postSync(app, repoId, cookie, { syncEnabled: "on", importFilterKind: "all" })
    ).text();
    expect(read).not.toContain("still reading this repository for the first time");
  });
});
