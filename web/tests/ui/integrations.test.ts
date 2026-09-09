import { describe, test, expect } from "bun:test";
import {
  IntegrationsPage,
  type IntegrationRepoView,
  type IntegrationView,
} from "../../src/ui/integrations.js";
import type { IntegrationsNotice } from "../../src/ui/integrations-notice.js";

const USER = { email: "gita@example.com" };
const CONNECT_URL = "/integrations/connect";

function repo(over: Partial<IntegrationRepoView> = {}): IntegrationRepoView {
  return {
    id: "11111111-1111-4111-8111-111111111111",
    repoKey: "github.com/acme/api",
    visibility: "public",
    syncEnabled: false,
    pushEnabled: false,
    publishNewByDefault: false,
    hasProject: true,
    importFilterKind: "all",
    importFilterValue: null,
    commentImportCap: 100,
    awaitingFirstImport: false,
    removedAt: null,
    ...over,
  };
}

function integration(over: Partial<IntegrationView> = {}): IntegrationView {
  return {
    id: "22222222-2222-4222-8222-222222222222",
    displayName: "acme",
    status: "active",
    revokedAt: null,
    repos: [repo()],
    ...over,
  };
}

function render(over: {
  githubApp?: { configured: false } | { configured: true; connectUrl: string };
  integrations?: IntegrationView[];
  notice?: IntegrationsNotice | null;
}): string {
  return IntegrationsPage({
    user: USER,
    githubApp: over.githubApp ?? { configured: true, connectUrl: CONNECT_URL },
    integrations: over.integrations ?? [],
    notice: over.notice ?? null,
  }).toString();
}

describe("IntegrationsPage", () => {
  test("says the server has no GitHub App rather than offering a dead button", () => {
    const html = render({ githubApp: { configured: false } });
    expect(html).toContain("No GitHub App on this server");
    expect(html).toContain("nothing to connect");
    // The Connect button is the thing that must not appear: it would send the
    // reader to an install url that does not exist.
    expect(html).not.toContain("Connect GitHub</a>");
    expect(html).not.toContain("github.com/apps/");
  });

  test("the empty state explains what connecting does before asking for it", () => {
    const html = render({});
    // Repository selection happening on GitHub's own screen is the fact that
    // makes the GitHub permission dialog legible when it appears.
    expect(html).toContain("You pick the repositories on GitHub");
    expect(html).toContain("Nothing is copied across until you switch a repository on here");
    // Outbound shipped opt-in per repository, so the old "nothing is posted
    // back" promise would now be a lie to someone deciding whether to connect.
    expect(html).toContain("Issues arrive here as tasks");
    expect(html).toContain("separate switch you turn on per repository");
    expect(html).not.toContain("Issues travel one way for now");
    expect(html).toContain(`href="${CONNECT_URL}"`);
    expect(html).toContain("Connect GitHub");
  });

  test("a connected account shows its name and that it is connected", () => {
    const html = render({ integrations: [integration()] });
    expect(html).toContain("acme");
    expect(html).toContain("Connected");
    expect(html).toContain("github.com/acme/api");
    expect(html).toContain("Import issues from this repository");
  });

  test("a private repo is marked and carries the warning; a public one does not", () => {
    const html = render({
      integrations: [
        integration({
          repos: [
            repo({ id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", repoKey: "github.com/acme/site" }),
            repo({
              id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
              repoKey: "github.com/acme/secrets",
              visibility: "private",
            }),
          ],
        }),
      ],
    });
    expect(html).toContain("Private");
    expect(html).toContain("Public");
    // The consent sentence, in full: naming what is copied and who can read it
    // is the whole reason `visibility` is a stored column.
    expect(html).toContain("This repository is private.");
    expect(html).toContain(
      "copies its issue titles, bodies and comments into Antgrid, where everyone on this account can read them."
    );
    // Marked by more than the word: the private badge carries its own weight.
    expect(html).toContain("badge badge-warning badge-lg");
  });

  test("a public-only account shows no private warning", () => {
    const html = render({ integrations: [integration()] });
    expect(html).not.toContain("This repository is private.");
  });

  test("a repo GitHub dropped explains itself rather than looking like a bug", () => {
    const html = render({
      integrations: [
        integration({ repos: [repo({ removedAt: new Date("2026-08-01T10:00:00Z") })] }),
      ],
    });
    expect(html).toContain("GitHub stopped listing this repository");
    expect(html).toContain("2026-08-01");
    // Both halves matter: that the user did not do it, and that undoing it on
    // GitHub is not enough on its own.
    expect(html).toContain("You did not switch this off.");
    expect(html).toContain("Add the repository back on GitHub to get the switch back");
    // And the switch is genuinely gone while it is unreachable: offering it
    // would promise an import the connection cannot perform.
    expect(html).toContain("<fieldset class=\"fieldset\" disabled=\"\">");
  });

  test("a revoked connection says deliveries no longer reach Antgrid, and freezes", () => {
    const html = render({
      integrations: [
        integration({
          status: "revoked",
          revokedAt: new Date("2026-07-04T00:00:00Z"),
        }),
      ],
    });
    expect(html).toContain("Disconnected");
    expect(html).toContain("GitHub no longer reaches Antgrid for this account");
    expect(html).toContain("Tasks already imported stay where they are");
    expect(html).toContain("2026-07-04");
    // Frozen, not merely discouraged — the controls come back disabled.
    expect(html).toContain("<fieldset class=\"fieldset\" disabled=\"\"");
  });

  test("a suspended connection reads differently from an active one", () => {
    const active = render({ integrations: [integration()] });
    const suspended = render({ integrations: [integration({ status: "suspended" })] });
    expect(suspended).toContain("Suspended on GitHub");
    expect(suspended).toContain("Nothing arrives from it while it stays suspended");
    expect(active).not.toContain("Suspended on GitHub");
  });

  test("the toggle posts to the repo sync endpoint and swaps its own row", () => {
    const html = render({
      integrations: [integration({ repos: [repo({ id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc" })] })],
    });
    expect(html).toContain(
      'hx-post="/ui/integrations/repos/cccccccc-cccc-4ccc-8ccc-cccccccccccc/sync"'
    );
    expect(html).toContain('hx-target="#repo-cccccccc-cccc-4ccc-8ccc-cccccccccccc"');
    expect(html).toContain('hx-swap="outerHTML"');
    expect(html).toContain('id="repo-cccccccc-cccc-4ccc-8ccc-cccccccccccc"');
    expect(html).toContain('name="syncEnabled"');
  });

  test("the import filter offers every choice and posts with the toggle", () => {
    const html = render({ integrations: [integration()] });
    expect(html).toContain("Every issue");
    expect(html).toContain("Issues with a label");
    expect(html).toContain("Issues in a milestone");
    expect(html).toContain("Issues assigned to someone on this account");
    expect(html).toContain('name="importFilterKind"');
    // The kind, the value and the toggle sit in ONE form, so the filter cannot
    // be saved to a different endpoint than the toggle beside it.
    const forms = html.match(/<form\b[^>]*>[\s\S]*?<\/form>/g) ?? [];
    const syncForms = forms.filter((f) => f.includes("/ui/integrations/repos/"));
    expect(syncForms.length).toBe(1);
    expect(syncForms[0]).toContain('name="syncEnabled"');
    expect(syncForms[0]).toContain('name="importFilterKind"');
    expect(syncForms[0]).toContain('name="importFilterValue"');
  });

  test("the filter value box is inert for the choices that name nothing", () => {
    const all = render({ integrations: [integration()] });
    expect(all).toContain('name="importFilterValue"');
    expect(all).toContain('hidden=""');
    // Disabled means unserialized, so an `all` save cannot carry a stale value
    // into the pairing the database CHECK enforces.
    expect(all).toMatch(/name="importFilterValue"[^>]*disabled=""/);

    const labelled = render({
      integrations: [
        integration({ repos: [repo({ importFilterKind: "label", importFilterValue: "bug" })] }),
      ],
    });
    expect(labelled).not.toMatch(/name="importFilterValue"[^>]*disabled=""/);
    expect(labelled).toContain('value="bug"');
  });

  test("the comment cap is shown as a partial mirror, and is not editable here", () => {
    const html = render({ integrations: [integration({ repos: [repo({ commentImportCap: 40 })] })] });
    expect(html).toContain("keeps the first 40 comments on each issue");
    expect(html).toContain("in part, not in full");
    expect(html).not.toContain('name="commentImportCap"');
  });

  test("an integration with no repositories says so instead of showing nothing", () => {
    const html = render({ integrations: [integration({ repos: [] })] });
    expect(html).toContain("No repositories here yet");
  });

  test("the outbound consents render as stored, and the publish default follows push", () => {
    const off = render({ integrations: [integration()] });
    expect(off).toContain('name="pushEnabled"');
    expect(off).toContain("Send changes back to this repository");
    expect(off).toContain("Start new tasks with &quot;also file on GitHub&quot; switched on");
    // Disabled means unserialized, so the publish default cannot arrive on a
    // post whose push box the reader has just cleared.
    expect(off).toMatch(/name="publishNewByDefault"[^>]*disabled=""/);
    expect(off).not.toMatch(/name="pushEnabled"[^>]*checked=""/);

    const on = render({
      integrations: [integration({ repos: [repo({ pushEnabled: true, publishNewByDefault: true })] })],
    });
    expect(on).toMatch(/name="pushEnabled"[^>]*checked=""/);
    expect(on).toMatch(/name="publishNewByDefault"[^>]*checked=""/);
    expect(on).not.toMatch(/name="publishNewByDefault"[^>]*disabled=""/);
  });

  test("every toggle saves itself, and the trigger is scoped so all three are bound", () => {
    const html = render({ integrations: [integration({ repos: [repo({ pushEnabled: true })] })] });

    // `find` would bind the first match alone, leaving the two outbound consents
    // silently unsaved until the reader also pressed Save — which sits above
    // them. The parentheses are htmx's escape for a selector holding a space.
    expect(html).toContain(
      "change from:(#repo-11111111-1111-4111-8111-111111111111 [data-autosave]), submit"
    );
    expect(html).not.toContain("from:find [data-autosave]");

    for (const name of ["syncEnabled", "pushEnabled", "publishNewByDefault"]) {
      const tag = html.match(new RegExp(`<input[^>]*name="${name}"[^>]*>`))?.[0];
      expect(tag).toBeDefined();
      expect(tag).toContain("data-autosave");
    }
  });

  test("the consent copy names what sending changes back does, and both conditions", () => {
    const html = render({ integrations: [integration()] });
    expect(html).toContain("Antgrid edits issues in this repository");
    expect(html).toContain("it never files anything on its own");
    // Public is irreversible in a way deleting the task cannot undo, and that is
    // the half a reader cannot work out from the toggle.
    expect(html).toContain("anything filed here is public the moment it is filed");

    const priv = render({
      integrations: [integration({ repos: [repo({ visibility: "private" })] })],
    });
    expect(priv).not.toContain("anything filed here is public the moment it is filed");
  });

  test("a repository no project is matched to says there is nowhere to file from", () => {
    const unmatched = render({ integrations: [integration({ repos: [repo({ hasProject: false })] })] });
    expect(unmatched).toContain("No Antgrid project is matched to this repository yet");
    expect(unmatched).toContain("a machine reports a checkout of it");

    const matched = render({ integrations: [integration()] });
    expect(matched).not.toContain("No Antgrid project is matched to this repository yet");
  });

  test("the member filter carries its identity caveat, and it is present but hidden otherwise", () => {
    const member = render({
      integrations: [integration({ repos: [repo({ importFilterKind: "assigned_to_member" })] })],
    });
    expect(member).toContain("signed in to Antgrid with GitHub");
    expect(member).toMatch(/data-member-caveat(?![^>]*hidden)/);

    // Rendered whatever the saved kind is: the select's handler unhides it, so
    // an absent element would leave the caveat one round trip behind the choice.
    const all = render({ integrations: [integration()] });
    expect(all).toMatch(/data-member-caveat[^>]*hidden=""/);
  });

  test("the whole account is told how an unmatched assignee will read", () => {
    const html = render({ integrations: [integration()] });
    expect(html).toContain("Sign in to Antgrid with GitHub to be recognised as yourself on issues");
    expect(html).toContain("anyone we cannot match shows as their GitHub login");
  });

  test("a switched-on repository that has never been read to the end says so", () => {
    const awaiting = render({
      integrations: [integration({ repos: [repo({ syncEnabled: true, awaitingFirstImport: true })] })],
    });
    expect(awaiting).toContain("still reading this repository for the first time");
    // Never a claim about progress: the reconcile runs outside this process, so
    // the page knows only that the walk has not finished.
    expect(awaiting).not.toMatch(/\d+%/);

    const caughtUp = render({
      integrations: [integration({ repos: [repo({ syncEnabled: true })] })],
    });
    expect(caughtUp).not.toContain("still reading this repository for the first time");
  });

  test("the first-import line waits for the switch, and yields to the removal notice", () => {
    // Import off: nothing is being read, so there is no backlog to explain.
    const off = render({
      integrations: [integration({ repos: [repo({ awaitingFirstImport: true })] })],
    });
    expect(off).not.toContain("still reading this repository for the first time");

    // Removed: the row already says GitHub took the repository away, and a
    // second line promising it is still being read would contradict it.
    const removed = render({
      integrations: [
        integration({
          repos: [repo({ syncEnabled: true, awaitingFirstImport: true, removedAt: new Date() })],
        }),
      ],
    });
    expect(removed).toContain("GitHub stopped listing this repository");
    expect(removed).not.toContain("still reading this repository for the first time");
  });
});
