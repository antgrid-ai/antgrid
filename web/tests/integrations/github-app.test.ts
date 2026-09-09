import { describe, expect, test } from "bun:test";
import { createVerify, generateKeyPairSync } from "node:crypto";
import {
  GITHUB_MAX_PAGES,
  GITHUB_PER_PAGE,
  GithubApiError,
  createGithubAppClient,
  githubAppConfig,
  mintAppJwt,
  normalizePrivateKeyPem,
  type FetchLike,
  type GithubAppConfig,
} from "../../src/integrations/github-app.js";

/** A throwaway pair per spelling, so a real PEM is exercised without any key
 *  material entering the repo. */
function keypair(privateKeyType: "pkcs8" | "pkcs1") {
  const { privateKey, publicKey } = generateKeyPairSync("rsa", {
    modulusLength: 2048,
    privateKeyEncoding: { type: privateKeyType, format: "pem" },
    publicKeyEncoding: { type: "spki", format: "pem" },
  });
  return { privateKey, publicKey };
}

const PKCS8 = keypair("pkcs8");
const PKCS1 = keypair("pkcs1");

const CLIENT_SECRET = "client-secret-value-do-not-log";

function config(overrides: Partial<GithubAppConfig> = {}): GithubAppConfig {
  return {
    appId: "424242",
    slug: "antgrid",
    clientId: "Iv1.appclient",
    clientSecret: CLIENT_SECRET,
    privateKeyPem: PKCS8.privateKey,
    ...overrides,
  };
}

type Call = { url: string; init: RequestInit };

/** Every test drives the client through this: a network call from this suite
 *  would be a test that passes on a laptop and fails in CI. */
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
    new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    });
}

function headerOf(call: Call, name: string): string | undefined {
  return (call.init.headers as Record<string, string> | undefined)?.[name];
}

function decodeSegment(segment: string): Record<string, unknown> {
  return JSON.parse(Buffer.from(segment, "base64url").toString("utf8"));
}

describe("githubAppConfig", () => {
  test("null unless every field is present", () => {
    const full = {
      GITHUB_APP_ID: "424242",
      GITHUB_APP_SLUG: "antgrid",
      GITHUB_APP_CLIENT_ID: "Iv1.appclient",
      GITHUB_APP_CLIENT_SECRET: CLIENT_SECRET,
      GITHUB_APP_PRIVATE_KEY: PKCS8.privateKey,
    };
    expect(githubAppConfig(full)).not.toBeNull();
    for (const key of Object.keys(full) as (keyof typeof full)[]) {
      expect(githubAppConfig({ ...full, [key]: undefined })).toBeNull();
    }
    expect(githubAppConfig({})).toBeNull();
  });

  test("a PEM whose newlines arrived as backslash-n signs anyway", () => {
    const escaped = PKCS8.privateKey.replace(/\n/g, "\\n");
    expect(escaped).not.toContain("\n");
    const resolved = githubAppConfig({
      GITHUB_APP_ID: "1",
      GITHUB_APP_SLUG: "antgrid",
      GITHUB_APP_CLIENT_ID: "Iv1.appclient",
      GITHUB_APP_CLIENT_SECRET: CLIENT_SECRET,
      GITHUB_APP_PRIVATE_KEY: escaped,
    });
    expect(resolved?.privateKeyPem).toBe(PKCS8.privateKey.trim());
    expect(verifyJwt(mintAppJwt(resolved!, new Date()), PKCS8.publicKey)).toBe(true);
  });

  test("neither secret survives being serialized or printed", () => {
    const resolved = githubAppConfig({
      GITHUB_APP_ID: "1",
      GITHUB_APP_SLUG: "antgrid",
      GITHUB_APP_CLIENT_ID: "Iv1.appclient",
      GITHUB_APP_CLIENT_SECRET: CLIENT_SECRET,
      GITHUB_APP_PRIVATE_KEY: PKCS8.privateKey,
    })!;
    // The two accidental paths: a structured logger stringifying a context
    // object, and a `console.log` of the config itself.
    const json = JSON.stringify({ config: resolved });
    expect(json).not.toContain(CLIENT_SECRET);
    expect(json).not.toContain("PRIVATE KEY");
    const printed = Bun.inspect(resolved);
    expect(printed).not.toContain(CLIENT_SECRET);
    expect(printed).not.toContain("PRIVATE KEY");
    // Redacted for readers, intact for the one caller that has to sign with it.
    expect(resolved.privateKeyPem).toBe(PKCS8.privateKey.trim());
    expect(verifyJwt(mintAppJwt(resolved, new Date()), PKCS8.publicKey)).toBe(true);
  });

  test("normalization is idempotent", () => {
    expect(normalizePrivateKeyPem(PKCS8.privateKey)).toBe(PKCS8.privateKey.trim());
    expect(normalizePrivateKeyPem(undefined)).toBeUndefined();
    expect(normalizePrivateKeyPem("   ")).toBeUndefined();
  });
});

function verifyJwt(jwt: string, publicKey: string): boolean {
  const [header, payload, signature] = jwt.split(".");
  const verifier = createVerify("RSA-SHA256");
  verifier.update(`${header}.${payload}`);
  return verifier.verify(publicKey, Buffer.from(signature!, "base64url"));
}

describe("mintAppJwt", () => {
  test("verifies against the public key and claims what GitHub requires", () => {
    const now = new Date("2026-08-18T12:00:00Z");
    const jwt = mintAppJwt(config(), now);
    expect(verifyJwt(jwt, PKCS8.publicKey)).toBe(true);

    const [header, payload] = jwt.split(".");
    expect(decodeSegment(header!)).toEqual({ alg: "RS256", typ: "JWT" });

    const claims = decodeSegment(payload!) as { iat: number; exp: number; iss: string };
    expect(claims.iss).toBe("424242");
    // Backdated against clock skew: a future `iat` is rejected outright.
    expect(claims.iat).toBe(Math.floor(now.getTime() / 1000) - 60);
    expect(claims.iat).toBeLessThan(Math.floor(now.getTime() / 1000));
    // 600s is GitHub's hard maximum, not a preference.
    expect(claims.exp - claims.iat).toBe(600);
  });

  test("PKCS#1 — what GitHub's download button produces — signs too", () => {
    const jwt = mintAppJwt(config({ privateKeyPem: PKCS1.privateKey }), new Date());
    expect(PKCS1.privateKey).toContain("BEGIN RSA PRIVATE KEY");
    expect(verifyJwt(jwt, PKCS1.publicKey)).toBe(true);
  });

  test("a signature does not verify against a different key", () => {
    expect(verifyJwt(mintAppJwt(config(), new Date()), PKCS1.publicKey)).toBe(false);
  });
});

describe("exchangeUserCode", () => {
  test("returns the user-to-server token", async () => {
    const { fetch, calls } = recordingFetch([json({ access_token: "ghu_token", scope: "" })]);
    const client = createGithubAppClient({ config: config(), fetch });
    expect(await client.exchangeUserCode("code-123")).toBe("ghu_token");

    expect(calls).toHaveLength(1);
    expect(calls[0]!.url).toBe("https://github.com/login/oauth/access_token");
    expect(calls[0]!.init.method).toBe("POST");
    expect(headerOf(calls[0]!, "accept")).toBe("application/json");
    const body = new URLSearchParams(String(calls[0]!.init.body));
    expect(body.get("code")).toBe("code-123");
    expect(body.get("client_id")).toBe("Iv1.appclient");
    expect(body.get("client_secret")).toBe(CLIENT_SECRET);
  });

  test("a 200 carrying an `error` key is a failure, not a token", async () => {
    const { fetch } = recordingFetch([json({ error: "bad_verification_code" })]);
    const client = createGithubAppClient({ config: config(), fetch });
    const err = await captureError(() => client.exchangeUserCode("stale"));
    expect(err.failure).toBe("refused");
    expect(err.status).toBe(200);
    expect(err.message).toContain("bad_verification_code");
  });

  test("a 200 with neither token nor error is still a failure", async () => {
    const { fetch } = recordingFetch([json({ token_type: "bearer" })]);
    const client = createGithubAppClient({ config: config(), fetch });
    expect((await captureError(() => client.exchangeUserCode("x"))).failure).toBe("refused");
  });
});

async function captureError(run: () => Promise<unknown>): Promise<GithubApiError> {
  try {
    await run();
  } catch (err) {
    expect(err).toBeInstanceOf(GithubApiError);
    return err as GithubApiError;
  }
  throw new Error("expected the call to throw");
}

function installationsPage(count: number, firstId = 1) {
  return {
    total_count: count,
    installations: Array.from({ length: count }, (_, i) => ({
      id: firstId + i,
      account: { id: 900 + i, login: `org-${firstId + i}`, type: "Organization" },
    })),
  };
}

describe("listUserInstallations", () => {
  test("a short first page ends the walk", async () => {
    const { fetch, calls } = recordingFetch([json(installationsPage(2))]);
    const client = createGithubAppClient({ config: config(), fetch });
    const rows = await client.listUserInstallations("ghu_user");

    expect(rows).toEqual([
      { installationId: "1", accountLogin: "org-1", accountId: "900" },
      { installationId: "2", accountLogin: "org-2", accountId: "901" },
    ]);
    expect(calls).toHaveLength(1);
    expect(calls[0]!.url).toBe(
      `https://api.github.com/user/installations?per_page=${GITHUB_PER_PAGE}&page=1`
    );
    expect(headerOf(calls[0]!, "authorization")).toBe("Bearer ghu_user");
    expect(headerOf(calls[0]!, "accept")).toBe("application/vnd.github+json");
    expect(headerOf(calls[0]!, "x-github-api-version")).toBe("2022-11-28");
    expect(headerOf(calls[0]!, "user-agent")).toBeTruthy();
  });

  test("a full page is followed by exactly one more request", async () => {
    const { fetch, calls } = recordingFetch([
      json(installationsPage(GITHUB_PER_PAGE)),
      json(installationsPage(3, GITHUB_PER_PAGE + 1)),
    ]);
    const client = createGithubAppClient({ config: config(), fetch });
    const rows = await client.listUserInstallations("ghu_user");

    expect(rows).toHaveLength(GITHUB_PER_PAGE + 3);
    expect(calls).toHaveLength(2);
    expect(calls[1]!.url).toContain("page=2");
  });

  test("the ceiling throws rather than returning a truncated list", async () => {
    const { fetch, calls } = recordingFetch([json(installationsPage(GITHUB_PER_PAGE))]);
    const client = createGithubAppClient({ config: config(), fetch });
    const err = await captureError(() => client.listUserInstallations("ghu_user"));

    expect(err.failure).toBe("unexpected");
    expect(err.endpoint).toBe("/user/installations");
    expect(calls).toHaveLength(GITHUB_MAX_PAGES);
  });

  test("an installation with no account still resolves an id", async () => {
    const { fetch } = recordingFetch([
      json({ total_count: 1, installations: [{ id: 77, account: null }] }),
    ]);
    const client = createGithubAppClient({ config: config(), fetch });
    expect(await client.listUserInstallations("ghu_user")).toEqual([
      { installationId: "77", accountLogin: null, accountId: null },
    ]);
  });
});

describe("getInstallation", () => {
  test("reads the account behind an installation with the App JWT", async () => {
    const { fetch, calls } = recordingFetch([
      json({ id: 55, account: { id: 900, login: "acme", type: "Organization" } }),
    ]);
    const client = createGithubAppClient({ config: config(), fetch });
    expect(await client.getInstallation("55")).toEqual({
      installationId: "55",
      accountLogin: "acme",
      accountId: "900",
      accountType: "Organization",
    });
    expect(calls[0]!.url).toBe("https://api.github.com/app/installations/55");
    const auth = headerOf(calls[0]!, "authorization")!;
    expect(verifyJwt(auth.replace("Bearer ", ""), PKCS8.publicKey)).toBe(true);
  });

  test("404 and 500 are different answers to the caller", async () => {
    const notFound = await captureError(() =>
      createGithubAppClient({
        config: config(),
        fetch: recordingFetch([json({ message: "Not Found" }, 404)]).fetch,
      }).getInstallation("55")
    );
    expect(notFound.failure).toBe("refused");
    expect(notFound.status).toBe(404);

    const down = await captureError(() =>
      createGithubAppClient({
        config: config(),
        fetch: recordingFetch([json({ message: "boom" }, 500)]).fetch,
      }).getInstallation("55")
    );
    expect(down.failure).toBe("retryable");
    expect(down.status).toBe(500);

    const throttled = await captureError(() =>
      createGithubAppClient({
        config: config(),
        fetch: recordingFetch([json({}, 429)]).fetch,
      }).getInstallation("55")
    );
    expect(throttled.failure).toBe("retryable");
  });

  test("a transport failure is retryable, not refused", async () => {
    const client = createGithubAppClient({
      config: config(),
      fetch: async () => {
        throw new TypeError("fetch failed");
      },
    });
    const err = await captureError(() => client.getInstallation("55"));
    expect(err.failure).toBe("retryable");
    expect(err.status).toBe(0);
  });

  test("an installation id that is not decimal never reaches a URL", async () => {
    const { fetch, calls } = recordingFetch([json({})]);
    const client = createGithubAppClient({ config: config(), fetch });
    const err = await captureError(() => client.getInstallation("../../user"));
    expect(err.failure).toBe("refused");
    expect(calls).toHaveLength(0);
  });

  test("a response missing the account is malformed, not a silent blank", async () => {
    const { fetch } = recordingFetch([json({ id: 55 })]);
    const client = createGithubAppClient({ config: config(), fetch });
    expect((await captureError(() => client.getInstallation("55"))).failure).toBe("malformed");
  });
});

describe("createInstallationToken", () => {
  test("returns the token and its expiry", async () => {
    const { fetch, calls } = recordingFetch([
      json({ token: "ghs_installation", expires_at: "2026-08-18T13:00:00Z" }),
    ]);
    const client = createGithubAppClient({ config: config(), fetch });
    const minted = await client.createInstallationToken("55");

    expect(minted.token).toBe("ghs_installation");
    expect(minted.expiresAt.toISOString()).toBe("2026-08-18T13:00:00.000Z");
    expect(calls[0]!.init.method).toBe("POST");
    expect(calls[0]!.url).toBe("https://api.github.com/app/installations/55/access_tokens");
  });

  test("an unreadable expiry is malformed rather than an Invalid Date", async () => {
    const { fetch } = recordingFetch([json({ token: "ghs_x", expires_at: "soon" })]);
    const client = createGithubAppClient({ config: config(), fetch });
    expect((await captureError(() => client.createInstallationToken("55"))).failure).toBe(
      "malformed"
    );
  });
});

describe("listInstallationRepos", () => {
  test("returns rows shaped for upsertIntegrationRepo", async () => {
    const { fetch, calls } = recordingFetch([
      json({
        total_count: 2,
        repositories: [
          { id: 11, full_name: "Acme/Relay", private: true, default_branch: "main" },
          { id: 12, full_name: "acme/site", private: false },
        ],
      }),
    ]);
    const client = createGithubAppClient({ config: config(), fetch });
    expect(await client.listInstallationRepos("ghs_installation")).toEqual([
      {
        externalRepoId: "11",
        repoKey: "github.com/acme/relay",
        fullName: "Acme/Relay",
        visibility: "private",
        defaultBranch: "main",
      },
      {
        externalRepoId: "12",
        repoKey: "github.com/acme/site",
        fullName: "acme/site",
        visibility: "public",
        defaultBranch: null,
      },
    ]);
    expect(headerOf(calls[0]!, "authorization")).toBe("Bearer ghs_installation");
  });

  test("a name that cannot be folded into a repoKey is reported, not guessed", async () => {
    const { fetch } = recordingFetch([
      json({ total_count: 1, repositories: [{ id: 13, full_name: "acme/../etc", private: false }] }),
    ]);
    const client = createGithubAppClient({ config: config(), fetch });
    const rows = await client.listInstallationRepos("ghs_installation");
    expect(rows[0]!.repoKey).toBeNull();
  });

  test("pagination stops on a short page", async () => {
    const page = (count: number, firstId: number) => ({
      total_count: count,
      repositories: Array.from({ length: count }, (_, i) => ({
        id: firstId + i,
        full_name: `acme/repo-${firstId + i}`,
        private: false,
      })),
    });
    const { fetch, calls } = recordingFetch([
      json(page(GITHUB_PER_PAGE, 1)),
      json(page(1, GITHUB_PER_PAGE + 1)),
    ]);
    const client = createGithubAppClient({ config: config(), fetch });
    expect(await client.listInstallationRepos("ghs_installation")).toHaveLength(
      GITHUB_PER_PAGE + 1
    );
    expect(calls).toHaveLength(2);
  });
});

describe("secrets never reach a thrown value", () => {
  const USER_TOKEN = "ghu_user_token_secret";
  const INSTALLATION_TOKEN = "ghs_installation_token_secret";

  /** The PEM is a cross-tenant master key and the tokens are per-installation
   *  credentials; an error that carries any of them turns a log shipper into an
   *  exfiltration path. Asserted over the whole error, stack included, because
   *  that is what a logger serializes. */
  function assertClean(err: GithubApiError): void {
    const rendered = `${err.message}\n${err.stack ?? ""}\n${JSON.stringify(err, Object.getOwnPropertyNames(err))}`;
    for (const secret of [
      CLIENT_SECRET,
      USER_TOKEN,
      INSTALLATION_TOKEN,
      PKCS8.privateKey,
      PKCS8.privateKey.split("\n")[1] ?? "",
    ]) {
      expect(rendered).not.toContain(secret);
    }
  }

  test("across every failing call", async () => {
    const cfg = config();
    const fail = (status: number) => recordingFetch([json({ message: "nope" }, status)]).fetch;

    assertClean(
      await captureError(() =>
        createGithubAppClient({ config: cfg, fetch: fail(401) }).exchangeUserCode("code-123")
      )
    );
    assertClean(
      await captureError(() =>
        createGithubAppClient({ config: cfg, fetch: fail(403) }).listUserInstallations(USER_TOKEN)
      )
    );
    assertClean(
      await captureError(() =>
        createGithubAppClient({ config: cfg, fetch: fail(500) }).getInstallation("55")
      )
    );
    assertClean(
      await captureError(() =>
        createGithubAppClient({ config: cfg, fetch: fail(404) }).createInstallationToken("55")
      )
    );
    assertClean(
      await captureError(() =>
        createGithubAppClient({ config: cfg, fetch: fail(500) }).listInstallationRepos(
          INSTALLATION_TOKEN
        )
      )
    );
  });

  test("including when the body itself is the secret", async () => {
    // The token endpoints answer with the credential; a validation message
    // derived from that body is the one place a secret leaks by accident.
    const { fetch } = recordingFetch([json({ access_token: 12345 })]);
    const err = await captureError(() =>
      createGithubAppClient({ config: config(), fetch }).exchangeUserCode("code-123")
    );
    expect(err.failure).toBe("malformed");
    expect(err.message).not.toContain("12345");
  });
});
