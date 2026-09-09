import { Layout } from "./layout.js";
import type { IntegrationsNotice } from "./integrations-notice.js";
import type {
  ImportFilterKind,
  IntegrationStatus,
  RepoVisibility,
} from "../models/integration.js";

/** Field names mirror `IntegrationRepoRecord` so a route can hand a row through
 *  unchanged, but the shape is declared structurally rather than derived from
 *  it: this file is view-only and must not depend on the generated client. */
export type IntegrationRepoView = {
  id: string;
  repoKey: string;
  visibility: RepoVisibility;
  syncEnabled: boolean;
  pushEnabled: boolean;
  publishNewByDefault: boolean;
  /** Whether an Antgrid project is linked to this repository. Publish targets
   *  join on that link, so without it there is nothing to file a task from and
   *  the page has to say so rather than offer a switch that reaches nothing. */
  hasProject: boolean;
  importFilterKind: ImportFilterKind;
  importFilterValue: string | null;
  commentImportCap: number;
  /** No walk of this repository has ever reached its end, so the issues that
   *  were already here have not all arrived. A webhook only ever describes the
   *  future, so without this the page would show a switched-on repository beside
   *  an empty task list and offer no reason for it. */
  awaitingFirstImport: boolean;
  /** When GitHub stopped listing the repository under the installation. Set,
   *  it is the only thing separating "GitHub took this away" from "the user
   *  switched it off", and the page is where that difference is explained. */
  removedAt: Date | null;
};

export type IntegrationView = {
  id: string;
  /** The GitHub account the repositories sit under, as GitHub spells it. */
  displayName: string;
  status: IntegrationStatus;
  revokedAt: Date | null;
  repos: IntegrationRepoView[];
};

/**
 * Every GitHub environment variable is optional, so the service boots with no
 * App at all and there is genuinely nothing to connect to. A union rather than a
 * nullable url, so the markup cannot offer a Connect button with nowhere to
 * send the reader.
 */
export type GitHubAppState =
  | { configured: false }
  /** Our own start route, not github.com: it has to mint the CSRF state and set
   *  the cookie that pairs with it before the browser leaves for GitHub. */
  | { configured: true; connectUrl: string };

export type IntegrationsPageProps = {
  user: { email?: string | null };
  githubApp: GitHubAppState;
  integrations: IntegrationView[];
  /** What the last action did, carried through a redirect so the callback's
   *  `code` never lands in history. */
  notice: IntegrationsNotice | null;
};

const NOTICE: Record<IntegrationsNotice, { tone: "ok" | "warn" | "error"; text: string }> = {
  connected: { tone: "ok", text: "GitHub is connected. Switch on the repositories you want imported." },
  bad_state: {
    tone: "error",
    text: "That link did not come from this browser, or it sat too long. Start again from Connect GitHub.",
  },
  not_your_installation: {
    tone: "error",
    text: "That installation is not one your GitHub account administers, so it was not connected.",
  },
  installation_taken: {
    tone: "error",
    text: "Another Antgrid account is already connected to that GitHub installation. Disconnect it there first.",
  },
  code_rejected: {
    tone: "error",
    text: "GitHub would not confirm who you are — the link had already been used, or it expired. Try connecting again.",
  },
  provider_error: {
    tone: "warn",
    text: "GitHub did not answer. Nothing was lost; try connecting again in a moment.",
  },
  install_requested: {
    tone: "warn",
    text: "Your request went to the people who own that GitHub organisation. It connects here once one of them approves it.",
  },
  not_configured: { tone: "error", text: "This server has no GitHub App set up." },
};

const NOTICE_ALERT: Record<"ok" | "warn" | "error", string> = {
  ok: "alert-success",
  warn: "alert-warning",
  error: "alert-error",
};

/** Order is the order of the select; `all` leads because it is the only choice
 *  that needs no second decision. A Record so a new kind fails the compile
 *  here rather than rendering as a blank option. */
const FILTER_KIND_LABEL: Record<ImportFilterKind, string> = {
  all: "Every issue",
  label: "Issues with a label",
  milestone: "Issues in a milestone",
  assigned_to_member: "Issues assigned to someone on this account",
};

const FILTER_KINDS = Object.keys(FILTER_KIND_LABEL) as ImportFilterKind[];

function takesFilterValue(kind: ImportFilterKind): boolean {
  return kind === "label" || kind === "milestone";
}

/** Keeps the name box and the membership caveat in step with the select between
 *  saves. Without it the box stays as the SAVED choice left it, so picking
 *  "Issues with a label" offers nowhere to type the label until the row has been
 *  round-tripped, and the caveat describes a filter the reader already moved off. */
const FILTER_KIND_ONCHANGE =
  "(function(s){var b=s.form.querySelector('[data-filter-value]');" +
  "var n=s.value==='label'||s.value==='milestone';" +
  "b.hidden=!n;b.querySelector('input').disabled=!n;" +
  "s.form.querySelector('[data-member-caveat]').hidden=s.value!=='assigned_to_member';})(this)";

/** The publish default is meaningless without push, and a disabled input is not
 *  serialized — so unchecking push here has to disarm it in the same gesture,
 *  not only on the round trip the route pairs them on. */
const PUSH_ONCHANGE =
  "(function(s){var b=s.form.querySelector('[data-publish-default]');" +
  "b.querySelector('input').disabled=!s.checked;" +
  "b.classList.toggle('opacity-50',!s.checked);})(this)";

const STATUS_LABEL: Record<IntegrationStatus, string> = {
  active: "Connected",
  suspended: "Suspended on GitHub",
  revoked: "Disconnected",
};

const STATUS_BADGE: Record<IntegrationStatus, string> = {
  active: "badge badge-success badge-outline",
  suspended: "badge badge-warning",
  revoked: "badge badge-error",
};

const STATUS_NOTE: Record<IntegrationStatus, string | null> = {
  active: null,
  suspended:
    "Someone suspended this connection on GitHub. Nothing arrives from it while it stays suspended. Lift the suspension on GitHub and the settings below carry on where they left off.",
  revoked:
    "This connection was removed, so GitHub no longer reaches Antgrid for this account and no issue or comment lands here any more. Tasks already imported stay where they are, and these settings are frozen until you connect again.",
};

function formatDate(d: Date): string {
  return d.toISOString().slice(0, 10);
}

function repoRowId(repoId: string): string {
  return `repo-${repoId}`;
}

export function IntegrationsPage(props: IntegrationsPageProps) {
  return (
    <Layout title="Integrations" user={props.user}>
      {props.notice && (
        <div
          class={`alert ${NOTICE_ALERT[NOTICE[props.notice].tone]} font-mono text-sm mb-6`}
          role={NOTICE[props.notice].tone === "error" ? "alert" : "status"}
        >
          <span>{NOTICE[props.notice].text}</span>
        </div>
      )}

      <div class="mb-6">
        <h1 class="font-mono text-2xl font-semibold">Integrations</h1>
        <p class="text-sm text-muted mt-1">
          Bring issues in from GitHub as tasks. Whatever arrives is readable by
          everyone on this account.
        </p>
      </div>

      {!props.githubApp.configured ? (
        <NotConfiguredCard />
      ) : props.integrations.length === 0 ? (
        <EmptyCard connectUrl={props.githubApp.connectUrl} />
      ) : (
        <>
          {props.integrations.map((integration) => (
            <IntegrationCard integration={integration} />
          ))}
          <div class="card bg-panel border border-edge mt-6">
            <div class="card-body">
              <h2 class="card-title font-mono">Add or remove repositories</h2>
              <p class="text-sm text-muted">
                Which repositories Antgrid can see is decided on GitHub, not
                here. Add or drop them there, then switch on the ones you want.
              </p>
              <div>
                <a
                  href={props.githubApp.connectUrl}
                  class="btn btn-quiet btn-sm font-mono mt-2"
                >
                  Manage on GitHub
                </a>
              </div>
            </div>
          </div>
        </>
      )}
    </Layout>
  );
}

function NotConfiguredCard() {
  return (
    <div class="card bg-panel border border-edge">
      <div class="card-body">
        <h2 class="card-title font-mono">No GitHub App on this server</h2>
        <p class="text-sm text-muted">
          This server has no GitHub App set up, so there is nothing to connect
          to. Whoever runs the server adds the App credentials to it; until then
          this page has nothing to show you.
        </p>
      </div>
    </div>
  );
}

function EmptyCard({ connectUrl }: { connectUrl: string }) {
  return (
    <div class="card bg-panel border border-edge">
      <div class="card-body">
        <h2 class="card-title font-mono">Connect GitHub</h2>
        <p class="text-sm text-muted">
          Antgrid can read issues from the repositories you choose and keep them
          beside your tasks.
        </p>
        <ul class="text-sm text-muted list-disc pl-5 mt-2 space-y-1">
          <li>
            You pick the repositories on GitHub, on GitHub's own screen. Antgrid
            never sees the ones you leave out.
          </li>
          <li>
            Nothing is copied across until you switch a repository on here, one
            repository at a time.
          </li>
          <li>
            Issues arrive here as tasks. Sending changes back to GitHub is a
            separate switch you turn on per repository, and it is off until you
            do.
          </li>
        </ul>
        <div>
          <a href={connectUrl} class="btn btn-primary font-mono mt-4">
            Connect GitHub
          </a>
        </div>
      </div>
    </div>
  );
}

function IntegrationCard({ integration }: { integration: IntegrationView }) {
  const note = STATUS_NOTE[integration.status];
  // Frozen rather than merely pointless: a revoked connection routes nothing,
  // so a live toggle on it would promise an import that cannot happen.
  const readOnly = integration.status === "revoked";

  return (
    <div class="card bg-panel border border-edge mt-6 overflow-hidden">
      <div class="p-4 border-b border-edge flex flex-wrap items-center gap-3">
        <h2 class="font-mono text-base font-semibold">{integration.displayName}</h2>
        <span class={`${STATUS_BADGE[integration.status]} font-mono`}>
          {STATUS_LABEL[integration.status]}
        </span>
        {integration.revokedAt && (
          <span class="font-mono text-xs text-muted2">
            {formatDate(integration.revokedAt)}
          </span>
        )}
      </div>

      {note && (
        <div class="p-4 border-b border-edge">
          <div class={`alert ${readOnly ? "alert-error" : "alert-warning"} text-sm`} role="status">
            <span>{note}</span>
          </div>
        </div>
      )}

      {/* Per connection, not per repository: it is one fact about who Antgrid
          can recognise, and it reads as noise repeated down a list of rows. */}
      <p class="px-4 pt-4 text-xs text-muted">
        Sign in to Antgrid with GitHub to be recognised as yourself on issues;
        anyone we cannot match shows as their GitHub login.
      </p>

      {integration.repos.length === 0 ? (
        <p class="p-4 text-sm text-muted">
          No repositories here yet. Choose some on GitHub and they show up on
          this page.
        </p>
      ) : (
        integration.repos.map((repo) => <IntegrationRepoRow repo={repo} readOnly={readOnly} />)
      )}
    </div>
  );
}

/**
 * One repository, and the whole consent moment for it.
 *
 * Exported because the sync post swaps this element for its own re-render — the
 * response body and the first paint have to be the same markup, or a saved row
 * comes back saying something the page never said.
 */
export function IntegrationRepoRow({
  repo,
  readOnly = false,
}: {
  repo: IntegrationRepoView;
  readOnly?: boolean;
}) {
  const rowId = repoRowId(repo.id);
  const needsValue = takesFilterValue(repo.importFilterKind);
  // A repository GitHub no longer lists cannot be imported from, so offering
  // the switch would promise something that cannot happen. Adding it back on
  // GitHub clears `removedAt` on the next delivery and the row unlocks itself.
  const frozen = readOnly || repo.removedAt !== null;

  return (
    <div id={rowId} class="p-4 border-b border-edge last:border-b-0">
      <div class="flex flex-wrap items-center gap-3">
        <span class="font-mono text-sm">{repo.repoKey}</span>
        <VisibilityBadge visibility={repo.visibility} />
      </div>

      {repo.removedAt && (
        <div class="alert alert-warning text-sm mt-3" role="status">
          <span>
            GitHub stopped listing this repository under the connection on{" "}
            {formatDate(repo.removedAt)}, so Antgrid stopped importing it. You did
            not switch this off. Add the repository back on GitHub to get the
            switch back — and it comes back off, because a repository leaving and
            returning is not an answer to whether you still want it imported.
          </span>
        </div>
      )}

      {repo.visibility === "private" && (
        <p class="text-sm text-warning mt-3">
          This repository is private. Switching it on copies its issue titles,
          bodies and comments into Antgrid, where everyone on this account can
          read them.
        </p>
      )}

      {/* No token field: /ui/* refuses any post that did not come from this
          origin (routes/ui.tsx), and htmx sends the headers that check reads —
          same as the plain forms on the team page.

          Every toggle carries `data-autosave` and so saves itself; only the typed
          and picked filter fields wait for Save. A switch that looks thrown but
          is not recorded is worst on this form in particular — the reader who
          switches "send changes back" OFF and leaves has revoked nothing.

          `from:` is scoped by the row id rather than written `from:find`, which
          resolves to the FIRST match alone: under `find` the toggles below the
          import one bind no listener at all, and the page still looks right. The
          parentheses are htmx's own escape for a selector containing a space —
          without them the spec ends at the space and binds the row itself, which
          catches the filter fields' changes too. */}
      <form
        hx-post={`/ui/integrations/repos/${repo.id}/sync`}
        hx-target={`#${rowId}`}
        hx-swap="outerHTML"
        hx-trigger={`change from:(#${rowId} [data-autosave]), submit`}
        class="mt-3"
      >
        <fieldset class="fieldset" disabled={frozen}>
          <label class="label cursor-pointer justify-start gap-3 p-0">
            <input
              type="checkbox"
              name="syncEnabled"
              value="on"
              checked={repo.syncEnabled}
              data-autosave
              class="toggle toggle-primary"
            />
            <span class="font-mono text-sm">Import issues from this repository</span>
          </label>

          <div class="flex flex-wrap items-end gap-2 mt-3">
            <label class="font-mono text-xs text-muted pb-2" for={`${rowId}-kind`}>
              Import
            </label>
            <select
              id={`${rowId}-kind`}
              name="importFilterKind"
              class="select select-bordered select-sm font-mono"
              onchange={FILTER_KIND_ONCHANGE}
            >
              {FILTER_KINDS.map((kind) => (
                <option value={kind} selected={kind === repo.importFilterKind}>
                  {FILTER_KIND_LABEL[kind]}
                </option>
              ))}
            </select>
            {/* Hidden AND disabled for the choices that name nothing: a disabled
                field is not serialized, so the post carries no value for the
                pairing `integration_repos_import_filter_check` would reject. */}
            <span data-filter-value hidden={!needsValue}>
              <input
                type="text"
                name="importFilterValue"
                value={repo.importFilterValue ?? ""}
                disabled={!needsValue}
                placeholder="label or milestone name"
                autocomplete="off"
                aria-label="Label or milestone name"
                class="input input-bordered input-sm font-mono"
              />
            </span>
            <button type="submit" class="btn btn-sm font-mono">
              Save
            </button>
          </div>

          {/* Rendered whatever the saved kind is, and hidden rather than absent,
              so the select's handler can surface it the moment the reader picks
              the filter rather than one round trip later. */}
          <p
            data-member-caveat
            hidden={repo.importFilterKind !== "assigned_to_member"}
            class="text-xs text-muted mt-2"
          >
            Someone counts as being on this account only once they have signed in
            to Antgrid with GitHub. An issue assigned only to people who have not
            is left where it is.
          </p>

          {/* Only while import is on and no walk has finished. Nothing here is a
              progress bar: the reconcile runs outside this process, so the page
              knows that the repository is not fully read and cannot honestly
              claim how far along it is. */}
          {repo.syncEnabled && repo.awaitingFirstImport && repo.removedAt === null && (
            <p class="text-xs text-muted mt-2">
              Antgrid is still reading this repository for the first time. Issues
              opened or edited from now on arrive as they happen; the ones that
              were already here appear as that first read works through them.
            </p>
          )}

          <label class="label cursor-pointer justify-start gap-3 p-0 mt-4">
            <input
              type="checkbox"
              name="pushEnabled"
              value="on"
              checked={repo.pushEnabled}
              data-autosave
              onchange={PUSH_ONCHANGE}
              class="toggle toggle-primary"
            />
            <span class="font-mono text-sm">Send changes back to this repository</span>
          </label>

          <div data-publish-default class={repo.pushEnabled ? undefined : "opacity-50"}>
            <label class="label cursor-pointer justify-start gap-3 p-0 mt-3">
              <input
                type="checkbox"
                name="publishNewByDefault"
                value="on"
                checked={repo.publishNewByDefault}
                disabled={!repo.pushEnabled}
                data-autosave
                class="toggle toggle-primary"
              />
              <span class="font-mono text-sm">
                Start new tasks with "also file on GitHub" switched on
              </span>
            </label>
          </div>

          <p class="text-xs text-muted mt-3">
            Sending changes back means Antgrid edits issues in this repository: a
            task's title, body, state and labels are written to the issue it came
            from.
            {repo.visibility === "public" && (
              <>
                {" "}
                This repository is public, so anything filed here is public the
                moment it is filed, and deleting the task afterwards does not take
                it back.
              </>
            )}
            {!repo.hasProject && (
              <>
                {" "}
                No Antgrid project is matched to this repository yet, so there is
                nowhere to file a task from — the match is made when a machine
                reports a checkout of it.
              </>
            )}{" "}
            The default only decides where the "also file on GitHub" switch starts
            on a new task, which you still see before you create it; it never
            files anything on its own.
          </p>
        </fieldset>
      </form>

      <p class="text-xs text-muted mt-3">
        Antgrid keeps the first {repo.commentImportCap} comments on each issue, so
        a long conversation arrives here in part, not in full.
      </p>
    </div>
  );
}

function VisibilityBadge({ visibility }: { visibility: RepoVisibility }) {
  if (visibility === "private") {
    return (
      <span class="badge badge-warning badge-lg font-mono font-semibold uppercase tracking-wide">
        Private
      </span>
    );
  }
  return <span class="badge badge-ghost badge-sm font-mono">Public</span>;
}
