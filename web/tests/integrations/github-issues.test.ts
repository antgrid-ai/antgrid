import { describe, expect, test } from "bun:test";
import {
  GITHUB_MAX_PAGES,
  GITHUB_PER_PAGE,
  GithubApiError,
  type FetchLike,
} from "../../src/integrations/github-app.js";
import {
  createGithubIssueWriter,
  findOpKey,
  opMarker,
  withOpMarker,
  type GithubIssueLister,
  type GithubIssueWriter,
} from "../../src/integrations/github-issues.js";

type Call = { url: string; init: RequestInit };

/** Every test drives the writer through this: a real request from this suite
 *  would be a public write from CI. */
function recordingFetch(responses: (() => Response)[]): { fetch: FetchLike; calls: Call[] } {
  const calls: Call[] = [];
  let next = 0;
  const fetch: FetchLike = async (url, init) => {
    calls.push({ url, init: init ?? {} });
    const make = responses[Math.min(next, responses.length - 1)];
    next += 1;
    if (!make) throw new Error("no response queued");
    return make();
  };
  return { fetch, calls };
}

function json(body: unknown, status = 200): () => Response {
  return () =>
    new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

function issue(overrides: Record<string, unknown> = {}) {
  return { id: 1, number: 7, title: "t", state: "open", ...overrides };
}

function writerOver(responses: (() => Response)[]): {
  writer: GithubIssueWriter & GithubIssueLister;
  calls: Call[];
} {
  const { fetch, calls } = recordingFetch(responses);
  return { writer: createGithubIssueWriter({ token: "ghs_installation", fetch }), calls };
}

function bodyOf(call: Call): Record<string, unknown> {
  return JSON.parse(String(call.init.body));
}

async function failureOf(run: () => Promise<unknown>): Promise<GithubApiError> {
  try {
    await run();
  } catch (err) {
    expect(err).toBeInstanceOf(GithubApiError);
    return err as GithubApiError;
  }
  throw new Error("expected a GithubApiError");
}

describe("patchIssue", () => {
  test("the request body carries only pushable fields, never assignees", async () => {
    const { writer, calls } = writerOver([json(issue())]);
    await writer.patchIssue(
      { owner: "acme", repo: "web", number: 7 },
      {
        title: "new",
        body: "text",
        state: "closed",
        state_reason: "completed",
        labels: ["bug"],
      }
    );
    const sent = bodyOf(calls[0]!);
    expect(Object.keys(sent).sort()).toEqual([
      "body",
      "labels",
      "state",
      "state_reason",
      "title",
    ]);
    expect(sent).not.toHaveProperty("assignees");
    expect(calls[0]!.url).toBe("https://api.github.com/repos/acme/web/issues/7");
    expect(calls[0]!.init.method).toBe("PATCH");
  });

  test("assignees is not in the patch type at all", async () => {
    const { writer } = writerOver([json(issue())]);
    await writer.patchIssue({ owner: "acme", repo: "web", number: 7 }, {
      // @ts-expect-error v1 never pushes assignees; the field's absence is structural.
      assignees: ["octocat"],
    });
  });

  test("the installation token is what signs the write", async () => {
    const { writer, calls } = writerOver([json(issue())]);
    await writer.patchIssue({ owner: "acme", repo: "web", number: 7 }, { title: "x" });
    const headers = calls[0]!.init.headers as Record<string, string>;
    expect(headers.authorization).toBe("Bearer ghs_installation");
    expect(headers["content-type"]).toBe("application/json");
  });

  test("a token function is re-read per call, so a drain can re-mint mid-pass", async () => {
    let minted = 0;
    const { fetch, calls } = recordingFetch([json(issue()), json(issue())]);
    const writer = createGithubIssueWriter({
      token: () => `ghs_${++minted}`,
      fetch,
    });
    await writer.getIssue({ owner: "acme", repo: "web", number: 7 });
    await writer.getIssue({ owner: "acme", repo: "web", number: 7 });
    const auth = calls.map((c) => (c.init.headers as Record<string, string>).authorization);
    expect(auth).toEqual(["Bearer ghs_1", "Bearer ghs_2"]);
  });
});

describe("failure vocabulary", () => {
  test("a well-formed error status maps the way the install client maps it", async () => {
    for (const [status, failure] of [
      [404, "refused"],
      [403, "refused"],
      [429, "retryable"],
      [500, "retryable"],
      [422, "unexpected"],
    ] as const) {
      const { writer } = writerOver([json({ message: "no" }, status)]);
      const err = await failureOf(() => writer.getIssue({ owner: "a", repo: "b", number: 1 }));
      expect(err.failure).toBe(failure);
      expect(err.status).toBe(status);
    }
  });

  test("a 200 whose shape is wrong is malformed, not unexpected", async () => {
    const { writer } = writerOver([json({ number: 7 })]);
    const err = await failureOf(() => writer.getIssue({ owner: "a", repo: "b", number: 1 }));
    expect(err.failure).toBe("malformed");
    expect(err.status).toBe(200);
  });

  test("a 200 that is not JSON is malformed", async () => {
    const { writer } = writerOver([() => new Response("<html>", { status: 200 })]);
    const err = await failureOf(() => writer.createIssue({ owner: "a", repo: "b" }, { title: "t" }));
    expect(err.failure).toBe("malformed");
  });

  test("a transport failure is retryable and carries no request detail", async () => {
    const fetch: FetchLike = async () => {
      throw new Error("ECONNRESET Bearer ghs_installation");
    };
    const writer = createGithubIssueWriter({ token: "ghs_installation", fetch });
    const err = await failureOf(() => writer.getIssue({ owner: "a", repo: "b", number: 1 }));
    expect(err.failure).toBe("retryable");
    expect(err.status).toBe(0);
    expect(err.message).not.toContain("ghs_installation");
  });

  test("a reference that would escape the repo path is refused before a URL exists", async () => {
    const { writer, calls } = writerOver([json(issue())]);
    for (const ref of [
      { owner: "..", repo: "web", number: 1 },
      { owner: "acme", repo: "../../user", number: 1 },
      { owner: "acme", repo: "web", number: 0 },
    ]) {
      const err = await failureOf(() => writer.getIssue(ref));
      expect(err.failure).toBe("refused");
    }
    expect(calls).toHaveLength(0);
  });
});

describe("listAppIssuesSince", () => {
  const since = new Date("2026-01-02T03:04:05.000Z");

  test("reads the primary store, filtered to this App and to closed issues too", async () => {
    const { writer, calls } = writerOver([json([issue()])]);
    await writer.listAppIssuesSince({ owner: "acme", repo: "web" }, { appSlug: "antgrid", since });
    const url = new URL(calls[0]!.url);
    expect(url.pathname).toBe("/repos/acme/web/issues");
    expect(url.searchParams.get("creator")).toBe("app/antgrid");
    expect(url.searchParams.get("state")).toBe("all");
    expect(url.searchParams.get("sort")).toBe("created");
    expect(url.searchParams.get("direction")).toBe("desc");
    expect(url.searchParams.get("since")).toBe(since.toISOString());
    expect(url.pathname).not.toContain("search");
  });

  test("a short page ends the walk", async () => {
    const page = Array.from({ length: GITHUB_PER_PAGE }, (_, i) => issue({ id: i, number: i + 1 }));
    const { writer, calls } = writerOver([json(page), json([issue({ id: 999, number: 999 })])]);
    const found = await writer.listAppIssuesSince(
      { owner: "acme", repo: "web" },
      { appSlug: "antgrid", since }
    );
    expect(found).toHaveLength(GITHUB_PER_PAGE + 1);
    expect(calls).toHaveLength(2);
  });

  test("pagination stops at GITHUB_MAX_PAGES and fails closed", async () => {
    const page = Array.from({ length: GITHUB_PER_PAGE }, (_, i) => issue({ id: i, number: i + 1 }));
    const { writer, calls } = writerOver([json(page)]);
    const err = await failureOf(() =>
      writer.listAppIssuesSince({ owner: "acme", repo: "web" }, { appSlug: "antgrid", since })
    );
    expect(err.failure).toBe("unexpected");
    expect(calls).toHaveLength(GITHUB_MAX_PAGES);
  });

  test("a slug that would escape the path is refused", async () => {
    const { writer, calls } = writerOver([json([])]);
    const err = await failureOf(() =>
      writer.listAppIssuesSince({ owner: "acme", repo: "web" }, { appSlug: "a/b", since })
    );
    expect(err.failure).toBe("refused");
    expect(calls).toHaveLength(0);
  });
});

describe("op markers", () => {
  test("the marker is an HTML comment, so it is invisible once rendered", () => {
    expect(opMarker("op-42")).toBe("<!-- antgrid:op:op-42 -->");
  });

  test("a key that could close the comment early is refused", () => {
    for (const key of ["a-->b", "a>b", "a b", "", "a".repeat(129)]) {
      expect(() => opMarker(key)).toThrow(TypeError);
    }
  });

  test("withOpMarker is stable across retries of one op", () => {
    const once = withOpMarker("Fix the thing", "op-42");
    expect(once).toBe("Fix the thing\n\n<!-- antgrid:op:op-42 -->");
    expect(withOpMarker(once, "op-42")).toBe(once);
    expect(withOpMarker(null, "op-42")).toBe("<!-- antgrid:op:op-42 -->");
  });

  test("findOpKey recovers the key a create embedded", () => {
    expect(findOpKey(withOpMarker("body", "op-42"))).toBe("op-42");
    expect(findOpKey("prefix <!--   antgrid:op:op.7   --> suffix")).toBe("op.7");
  });

  test("findOpKey is null once a human has edited the marker out", () => {
    const published = withOpMarker("Fix the thing", "op-42");
    expect(findOpKey(published.replace(/<!--[\s\S]*?-->/, "").trim())).toBeNull();
    expect(findOpKey("Fix the thing")).toBeNull();
    expect(findOpKey(null)).toBeNull();
    expect(findOpKey("")).toBeNull();
  });

  test("a created body carrying the marker round-trips through the writer", async () => {
    const { writer, calls } = writerOver([json(issue({ number: 12 }))]);
    await writer.createIssue(
      { owner: "acme", repo: "web" },
      { title: "t", body: withOpMarker("hello", "op-9"), labels: ["bug"] }
    );
    expect(calls[0]!.url).toBe("https://api.github.com/repos/acme/web/issues");
    expect(calls[0]!.init.method).toBe("POST");
    expect(findOpKey(String(bodyOf(calls[0]!).body))).toBe("op-9");
  });
});

describe("listRepoIssuesSince", () => {
  const ref = { owner: "acme", repo: "web" };

  test("asks for every issue, oldest edit first — the order the cursor depends on", async () => {
    const since = new Date("2026-01-02T03:04:05.000Z");
    const { writer, calls } = writerOver([json([issue()])]);
    await writer.listRepoIssuesSince(ref, { since, page: 3 });

    const url = new URL(calls[0]!.url);
    expect(url.pathname).toBe("/repos/acme/web/issues");
    expect(url.searchParams.get("state")).toBe("all");
    expect(url.searchParams.get("sort")).toBe("updated");
    // Ascending is what makes a partial walk resumable: everything before the
    // last processed issue is done, so a run cut short still leaves a cursor.
    expect(url.searchParams.get("direction")).toBe("asc");
    expect(url.searchParams.get("per_page")).toBe(String(GITHUB_PER_PAGE));
    expect(url.searchParams.get("page")).toBe("3");
    expect(url.searchParams.get("since")).toBe(since.toISOString());
    // Not the App-scoped lister: a reconcile that filtered on `creator` would
    // import only issues we opened ourselves.
    expect(url.searchParams.get("creator")).toBeNull();
  });

  test("a first import sends no `since` at all", async () => {
    const { writer, calls } = writerOver([json([])]);
    await writer.listRepoIssuesSince(ref, { since: null, page: 1 });
    expect(new URL(calls[0]!.url).searchParams.has("since")).toBe(false);
  });

  test("one page per call, even when the page is full — the caller owns the walk", async () => {
    const page = Array.from({ length: GITHUB_PER_PAGE }, (_, i) => issue({ id: i, number: i + 1 }));
    const { writer, calls } = writerOver([json(page), json([issue({ id: 999, number: 999 })])]);

    const found = await writer.listRepoIssuesSince(ref, { since: null, page: 1 });

    expect(found).toHaveLength(GITHUB_PER_PAGE);
    expect(calls).toHaveLength(1);
  });

  test("a malformed repository reference is refused before a URL exists", async () => {
    const { writer, calls } = writerOver([json([])]);
    const err = await failureOf(() =>
      writer.listRepoIssuesSince({ owner: "..", repo: "web" }, { since: null, page: 1 })
    );
    expect(err.failure).toBe("refused");
    expect(calls).toHaveLength(0);
  });

  test("a page number outside the paging domain is refused", async () => {
    const { writer, calls } = writerOver([json([])]);
    const err = await failureOf(() => writer.listRepoIssuesSince(ref, { since: null, page: 0 }));
    expect(err.failure).toBe("refused");
    expect(calls).toHaveLength(0);
  });
});
